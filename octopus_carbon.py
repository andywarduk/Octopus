#!/usr/bin/env python3
"""Grid carbon intensity, the generation mix and GB demand, in the terminal.

    python3 octopus_carbon.py --postcode SN13
    python3 octopus_carbon.py --mix
    python3 octopus_carbon.py --week 1
    OCTOPUS_API_KEY=sk_live_... python3 octopus_carbon.py --source octopus

National Grid needs no API key, covers 48 hours ahead and past weeks, and reports the generation
mix. Octopus relays the same regional forecast but only 24 hours of it, with no history and no
mix; a key is needed for it, and for looking the postcode up from the account.

Python 3.9 or later, standard library only.
"""

import argparse
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.request

GRAPHQL = "https://api.octopus.energy/v1/graphql/"
CARBON = "https://api.carbonintensity.org.uk"
ELEXON = "https://data.elexon.co.uk/bmrs/api/v1"

# Octopus's own published line between green and not-so-green.
GREEN_THRESHOLD = 100
# Above GB's physical solar ceiling: the record is about 14 GW from roughly 18 GW installed.
# The intensity forecast misfires around sunrise and reports far more than the country can make.
SOLAR_CEILING_MW = 16_000
# Stack order, dirtiest first, matching the app.
FUELS = ["other", "gas", "coal", "imports", "biomass", "nuclear", "hydro", "wind", "solar"]


def get(url, headers=None):
    request = urllib.request.Request(
        url, headers={"Accept": "application/json", "User-Agent": "octopus-carbon", **(headers or {})}
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        try:
            return json.load(error)
        except ValueError:
            return {}
    except urllib.error.URLError as error:
        sys.exit(f"Could not reach {url.split('/')[2]}: {error.reason}")


def gql(query, variables=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = token
    request = urllib.request.Request(
        GRAPHQL, json.dumps({"query": query, "variables": variables or {}}).encode(), headers
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        body = json.load(response)
    if body.get("errors"):
        raise RuntimeError(body["errors"][0].get("message"))
    return body["data"]


def parse(ts):
    """National Grid stamps periods without seconds, which fromisoformat rejects before 3.11."""
    ts = ts.replace("Z", "+00:00")
    try:
        return dt.datetime.fromisoformat(ts)
    except ValueError:
        return dt.datetime.strptime(ts, "%Y-%m-%dT%H:%M%z")


def stamp(when):
    return when.strftime("%Y-%m-%dT%H:%MZ")


def slot_key(when):
    return int(when.timestamp() // 1800)


def outward_code(postcode):
    """Both APIs take the outward part, and it is all they need.

    The inward part is always three characters, but only strip it when there is a full postcode
    to strip it from: an outward code given on its own ("SN13") is already the answer, and
    dropping three characters off it leaves "S".
    """
    text = postcode.strip().upper()
    if " " in text:
        return text.split()[0]
    return text[:-3] if len(text) >= 5 else text


def account_postcode(key):
    token = gql("mutation($k:String!){obtainKrakenToken(input:{APIKey:$k}){token}}", {"k": key})[
        "obtainKrakenToken"
    ]["token"]
    number = gql("{viewer{accounts{number}}}", token=token)["viewer"]["accounts"][0]["number"]
    properties = gql(
        "query($a:String!){account(accountNumber:$a){properties{postcode}}}", {"a": number}, token
    )["account"]["properties"]
    for prop in properties:
        if prop.get("postcode"):
            return prop["postcode"], token
    sys.exit("No postcode on any property — pass --postcode")


def merge_mix(entries):
    """Fold the mix into stack order, with anything unrecognised added into `other`."""
    shares = {}
    for entry in entries or []:
        percent = entry.get("perc") or 0
        if percent <= 0:
            continue
        fuel = entry.get("fuel", "").lower()
        shares[fuel if fuel in FUELS else "other"] = shares.get(fuel if fuel in FUELS else "other", 0) + percent
    return [(fuel, shares[fuel]) for fuel in FUELS if fuel in shares]


def fetch_regional(outward, start, end, forecast):
    tail = f"{stamp(start)}/fw48h" if forecast else f"{stamp(start)}/{stamp(end)}"
    body = get(f"{CARBON}/regional/intensity/{tail}/postcode/{outward}")
    data = body.get("data")
    if not data:
        sys.exit(f"No carbon intensity for {outward}: {json.dumps(body)[:200]}")
    region = data if isinstance(data, dict) else data[0]
    rows = []
    for row in region.get("data") or []:
        intensity = row.get("intensity") or {}
        value = intensity.get("actual")
        if value is None:
            value = intensity.get("forecast")
        if value is None:
            continue
        rows.append(
            {
                "start": parse(row["from"]),
                "grams": float(value),
                "index": (intensity.get("index") or "").lower(),
                "mix": merge_mix(row.get("generationmix")),
                "national_mix": False,
            }
        )
    return region.get("shortname"), sorted(rows, key=lambda r: r["start"])


def fetch_octopus(token, postcode):
    rows = gql(
        """query($p:String!){getProjectedRegionalCarbonIntensity(postcode:$p){
             projectedRegionalCarbonIntensity{periodStart value index}
           }}""",
        {"p": postcode},
        token,
    )["getProjectedRegionalCarbonIntensity"]["projectedRegionalCarbonIntensity"]
    parsed = sorted(
        (
            {
                "start": parse(r["periodStart"]),
                "grams": float(r["value"]),
                "index": (r.get("index") or "").lower().replace("_", " "),
                "mix": [],
                "national_mix": False,
            }
            for r in rows
            if r.get("value") is not None
        ),
        key=lambda r: r["start"],
    )
    return None, parsed


def fetch_national_mix(start, end):
    """GB generation mix. A range spanning now returns the forecast too; one starting in the
    future silently clamps to the last published half hour, which is easy to mistake for a bug."""
    body = get(f"{CARBON}/generation/{stamp(start)}/{stamp(end)}")
    return {
        slot_key(parse(row["from"])): merge_mix(row.get("generationmix"))
        for row in body.get("data") or []
    }


def fetch_demand(start, end):
    """GB demand in MW. Settled outturn and the day-ahead forecast are both asked for, because a
    window can straddle now and neither covers the other's half. The half hour in progress is
    covered by neither — its outturn publishes when it ends — so it comes back missing."""
    demand = {}
    for url, field in [
        (
            f"{ELEXON}/demand/outturn?settlementDateFrom={start:%Y-%m-%d}"
            f"&settlementDateTo={end:%Y-%m-%d}&format=json",
            "initialDemandOutturn",
        ),
        (
            f"{ELEXON}/forecast/demand/day-ahead?from={stamp(start)}&to={stamp(end)}&format=json",
            "nationalDemand",
        ),
    ]:
        for row in (get(url) or {}).get("data") or []:
            value = row.get(field)
            if value is None:
                continue
            demand.setdefault(slot_key(parse(row["startTime"])), float(value))
    return demand


def implied_solar(row):
    if row.get("demand") is None or not row["mix"]:
        return None
    total = sum(percent for _, percent in row["mix"])
    solar = dict(row["mix"]).get("solar", 0)
    return row["demand"] * solar / total if total else None


def bar(value, top, width=34):
    filled = 0 if top <= 0 else max(0, min(width, round(width * value / top)))
    return "█" * filled + "·" * (width - filled)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--postcode", help="defaults to the account's, which needs an API key")
    parser.add_argument("--source", choices=["national", "octopus"], default="national")
    parser.add_argument("--week", type=int, metavar="N",
                        help="a past week, N weeks back (National Grid only)")
    parser.add_argument("--mix", action="store_true", help="show the generation mix per half hour")
    args = parser.parse_args()

    key = os.environ.get("OCTOPUS_API_KEY")
    token = None
    postcode = args.postcode
    if not postcode:
        if not key:
            sys.exit("Set OCTOPUS_API_KEY to look the postcode up, or pass --postcode")
        postcode, token = account_postcode(key)
    outward = outward_code(postcode)

    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    if args.week is not None:
        if args.source == "octopus":
            sys.exit("Octopus only forecasts — drop --week or use --source national")
        today = now.replace(hour=0, minute=0, second=0)
        end = today - dt.timedelta(days=7 * args.week) + dt.timedelta(days=1)
        start, forecast = end - dt.timedelta(days=7), False
    else:
        start = dt.datetime.fromtimestamp((now.timestamp() // 1800) * 1800, dt.timezone.utc)
        end, forecast = start + dt.timedelta(hours=48), True

    if args.source == "octopus":
        if not token:
            if not key:
                sys.exit("The Octopus source needs OCTOPUS_API_KEY")
            token = gql(
                "mutation($k:String!){obtainKrakenToken(input:{APIKey:$k}){token}}", {"k": key}
            )["obtainKrakenToken"]["token"]
        region, rows = fetch_octopus(token, postcode)
    else:
        region, rows = fetch_regional(outward, start, end, forecast)
    if not rows:
        sys.exit("No readings returned")

    # Demand and the national mix are national and keyless, so they are fetched whichever relay
    # supplied the intensity — a half hour that is implausible is implausible either way.
    span = (rows[0]["start"], rows[-1]["start"] + dt.timedelta(minutes=30))
    demand = fetch_demand(*span)
    national = fetch_national_mix(*span)
    for row in rows:
        slot = slot_key(row["start"])
        row["demand"] = demand.get(slot)
        if national.get(slot):
            # Only the national split can be multiplied by GB demand to mean megawatts.
            row["mix"] = national[slot] if args.source == "national" else row["mix"]
            row["screen_mix"] = national[slot]
            row["national_mix"] = args.source == "national"
        else:
            row["screen_mix"] = row["mix"]
        screen = {"demand": row["demand"], "mix": row["screen_mix"]}
        solar = implied_solar(screen)
        row["suspect"] = solar is not None and solar > SOLAR_CEILING_MW

    local = dt.timezone(dt.timedelta(hours=0))  # printed in UTC; the APIs report in UTC
    top = max(r["grams"] for r in rows)
    label = "Octopus" if args.source == "octopus" else "National Grid"
    header = " · ".join(filter(None, [region, outward, label,
                                      "past week" if args.week is not None else "forecast"]))
    print(header)
    print()

    day = None
    for row in rows:
        when = row["start"].astimezone(local)
        if when.date() != day:
            day = when.date()
            print(f"  {when:%a %d %b}")
        flag = " !" if row["suspect"] else "  "
        line = (f"   {when:%H:%M} {bar(row['grams'], top)} {row['grams']:5.0f}"
                f" {row['index']:<9}{flag}")
        # Always the same width, or the mix column shifts left on the rows without demand.
        line += f" {row['demand'] / 1000:5.1f} GW" if row["demand"] is not None else " " * 9
        if args.mix and row["mix"]:
            total = sum(p for _, p in row["mix"])
            ranked = sorted(row["mix"], key=lambda s: -s[1])[:3]
            line += "  " + ", ".join(
                f"{fuel} {percent:.0f}%"
                + (f" ({row['demand'] * percent / total / 1000:.1f} GW)"
                   if row["national_mix"] and row["demand"] and total else "")
                for fuel, percent in ranked
            )
        print(line)

    print()
    usable = [r for r in rows if not r["suspect"]]
    cleanest = min(usable, key=lambda r: r["grams"], default=None)
    green = sum(1 for r in usable if r["grams"] < GREEN_THRESHOLD)
    print(f"  {len(rows)} half hours · {green} below {GREEN_THRESHOLD} gCO2/kWh")
    if cleanest:
        print(f"  cleanest {cleanest['start'].astimezone(local):%a %H:%M}"
              f" at {cleanest['grams']:.0f} gCO2/kWh")
    suspect = len(rows) - len(usable)
    if suspect:
        # Not corrected: the number belongs to the grid operator. The forecast misfires around
        # sunrise, reporting more solar than the country can physically generate.
        print(f"  {suspect} half hour{'s' if suspect > 1 else ''} marked ! — the published mix is"
              f" impossible, and excluded from the figures above")
    missing = [r for r in rows if r["demand"] is None]
    if missing:
        running = sum(1 for r in missing if r["start"] <= now)
        ahead = len(missing) - running
        notes = []
        if running:
            notes.append("the half hour in progress, published when it ends")
        if ahead:
            notes.append(f"{ahead} half hours past the day-ahead forecast")
        print("  no GB demand for: " + "; ".join(notes))


if __name__ == "__main__":
    main()
