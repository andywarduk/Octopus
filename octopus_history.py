#!/usr/bin/env python3
"""Show which half hours you were actually billed at the off-peak rate.

Octopus has no "past off-peak periods" endpoint, so this reconstructs them from the half-hourly
measurements on your property: each one carries the unit rate you were charged. That catches
smart-charge dispatches outside the fixed window as well as the window itself.

Periods are grouped by price, which is real. The tariff's per-device buckets are not: Octopus
allocates a fixed amount to the EV bucket and the rest of the car's draw lands in the household
bucket at the same price, so a dispatch is marked rather than split out.

Usage:
  OCTOPUS_API_KEY=sk_live_... python3 octopus_history.py [options]

Options:
  --days N        days back to pull (default 7)
  --sessions      also list the car's charging sessions
  --dispatches    also list the smart charges Octopus ran, the rate each half hour was billed at,
                  and any car-sized standard-rate draw that no charge accounts for
  --csv FILE      write every half hour to a CSV
  --debug         print the raw response for the first day
"""
import argparse
import csv
import json
import os
import sys
import urllib.request
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

URL = "https://api.octopus.energy/v1/graphql/"
# Statistics that price the energy itself. Standing charge is excluded: it isn't a unit rate.
CONSUMPTION_STATS = {"CONSUMPTION_COST", "TOU_BUCKET_COST"}


def gql(query, variables=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = token
    req = urllib.request.Request(
        URL, json.dumps({"query": query, "variables": variables or {}}).encode(), headers
    )
    with urllib.request.urlopen(req, timeout=60) as response:
        body = json.load(response)
    if body.get("errors"):
        raise RuntimeError(body["errors"][0].get("message"))
    return body["data"]


def run(*args, **kwargs):
    try:
        return gql(*args, **kwargs)
    except RuntimeError as exc:
        sys.exit(f"GraphQL error: {exc}")


def parse(ts):
    return datetime.fromisoformat(ts.replace("Z", "+00:00")) if ts else None


def to_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


MEASUREMENTS_QUERY = """query($p:ID!,$s:DateTime!,$e:DateTime!,$mpan:String!,$tz:String!,$n:Int!){
  property(id:$p){
    measurements(startAt:$s,endAt:$e,timezone:$tz,first:$n,
      utilityFilters:[{electricityFilters:{readingFrequencyType:THIRTY_MIN_INTERVAL,marketSupplyPointId:$mpan,readingDirection:CONSUMPTION}}]){
      edges{node{
        value
        unit
        ... on IntervalMeasurementType{startAt endAt}
        metaData{statistics{type label value costInclTax{estimatedAmount costCurrency pricePerUnit{amount unit}}}}
      }}
    }
  }
}"""

DISPATCHES_QUERY = """query($a:String!){completedDispatches(accountNumber:$a){
  start end delta meta{source location}
}}"""

# A half hour drawing this much or more at the standard rate looks like the car, not the house:
# 1.5 kWh is 3 kW sustained, well above a household baseline and well below a 7 kW charger.
CAR_SIZED_KWH = 1.5

SESSIONS_QUERY = """query($a:String!,$after:DateTime!){devices(accountNumber:$a){
  __typename
  name
  ... on SmartFlexVehicle{
    make
    model
    chargingSessions(after:$after,first:100){
      edges{node{
        start
        end
        energyAdded{value unit}
        cost{amount currency}
        ... on SmartFlexChargingSession{type dispatches{start end type energyAddedKwh}}
      }}
    }
  }
}}"""


def bucket_name(label):
    """CONSUMPTION_CHARGE_ECO7_NIGHT_H -> ECO7_NIGHT"""
    name = (label or "").removeprefix("CONSUMPTION_CHARGE_")
    return name.removesuffix("_H") or "?"


def fetch_day(prop_id, mpan, start, tz_name, token, debug=False):
    """Half-hourly measurements for the local day beginning at `start`."""
    end = start + timedelta(days=1)
    # Not always 48: the day the clocks go back has 50 half hours, and asking for 48 cut off
    # its last hour. Converted to UTC first: two datetimes sharing a tzinfo subtract by wall
    # clock, which would say 24 hours on that day too.
    elapsed = end.astimezone(timezone.utc) - start.astimezone(timezone.utc)
    half_hours = max(1, round(elapsed.total_seconds() / 1800))
    data = gql(
        MEASUREMENTS_QUERY,
        {
            "p": prop_id, "mpan": mpan, "tz": tz_name, "n": half_hours,
            "s": start.isoformat(), "e": end.isoformat(),
        },
        token,
    )
    edges = (((data.get("property") or {}).get("measurements") or {}).get("edges")) or []
    if debug:
        # Sample both ends of the day: the overnight window and the middle of the afternoon.
        for i in (0, 1, 24, 25, 28):
            if i < len(edges):
                print(f"--- interval {i}")
                print(json.dumps(edges[i], indent=2))
    rows = []
    for edge in edges:
        node = edge.get("node") or {}
        began = parse(node.get("startAt"))
        if began is None:
            continue
        # Every tariff bucket is listed for every interval; only the one with kWh against it was
        # actually charged. Amounts are in pence, despite costCurrency saying GBP.
        charged_kwh = cost = standing = 0.0
        buckets = []
        detail = []
        for stat in ((node.get("metaData") or {}).get("statistics")) or []:
            money = stat.get("costInclTax") or {}
            amount = to_float(money.get("estimatedAmount")) or 0.0
            if stat.get("type") == "STANDING_CHARGE_COST":
                standing += amount
                continue
            if stat.get("type") not in CONSUMPTION_STATS:
                continue
            bucket_kwh = to_float(stat.get("value")) or 0.0
            if bucket_kwh <= 0:
                continue
            charged_kwh += bucket_kwh
            cost += amount
            name = bucket_name(stat.get("label"))
            buckets.append(name)
            detail.append({
                "bucket": name, "kwh": bucket_kwh, "pence": amount,
                "price": to_float((money.get("pricePerUnit") or {}).get("amount")),
            })
        # A sliver of usage makes the derived rate meaningless, so leave those unclassified.
        rate = cost / charged_kwh if charged_kwh >= 0.01 else None
        rows.append({
            "start": began, "end": parse(node.get("endAt")),
            "kwh": to_float(node.get("value")), "charged_kwh": charged_kwh,
            "pence": cost, "standing": standing, "rate": rate,
            "buckets": buckets, "detail": detail,
        })
    return rows


def classify(rows):
    """Split the observed rates into cheap and standard. Returns (threshold, cheap, standard)."""
    rates = sorted(r["rate"] for r in rows if r["rate"] is not None)
    if not rates:
        return None, None, None
    low, high = rates[0], rates[-1]
    # A tariff with one rate has no off-peak window; 20% apart is well beyond rounding noise.
    if high - low < max(1.0, low * 0.2):
        return None, low, high
    return (low + high) / 2, low, high


def runs_of_cheap(day_rows, threshold):
    """Contiguous stretches billed below the threshold."""
    out = []
    for row in day_rows:
        if row["rate"] is None or row["rate"] >= threshold:
            continue
        if out and out[-1]["end"] == row["start"]:
            out[-1]["end"] = row["end"]
            out[-1]["kwh"] += row["kwh"] or 0
            out[-1]["pence"] += row["pence"] or 0
            out[-1]["buckets"].update(row["buckets"])
        else:
            out.append({
                "start": row["start"], "end": row["end"],
                "kwh": row["kwh"] or 0, "pence": row["pence"] or 0,
                "buckets": set(row["buckets"]),
            })
    return out


def strip(day_rows, threshold, tz):
    """One character per half hour, midnight to midnight. '·' means nothing was published."""
    slots = ["·"] * 48
    for row in day_rows:
        local = row["start"].astimezone(tz)
        index = local.hour * 2 + (1 if local.minute >= 30 else 0)
        if not 0 <= index < 48:
            continue
        if row["rate"] is None:
            slots[index] = "░"  # published, but no usage to price
        elif threshold and row["rate"] < threshold:
            # A dispatch is marked, not split out: the per-device buckets are a billing
            # allocation, not a measurement of what the car drew.
            slots[index] = "▓" if any("EV_DEVICE" in b for b in row["buckets"]) else "█"
        else:
            slots[index] = "▒"
    return "".join(slots)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--sessions", action="store_true")
    parser.add_argument("--dispatches", action="store_true")
    parser.add_argument("--csv")
    parser.add_argument("--debug", action="store_true")
    parser.add_argument("--mpan", help="which import meter to use, if the account has several")
    parser.add_argument(
        "--meters", action="store_true",
        help="list the electricity and gas meters on the account, then stop")
    parser.add_argument(
        "--peaks", type=int, metavar="N",
        help="list the N highest-usage half hours, with the implied kW and the bucket split")
    args = parser.parse_args()

    key = os.environ.get("OCTOPUS_API_KEY")
    if not key:
        sys.exit("Set OCTOPUS_API_KEY in your environment.")

    token = run("mutation($k:String!){obtainKrakenToken(input:{APIKey:$k}){token}}", {"k": key})
    token = token["obtainKrakenToken"]["token"]

    account = run("{viewer{accounts{number}}}", token=token)["viewer"]["accounts"][0]["number"]

    if args.meters:
        listing = run(
            """query($a:String!){account(accountNumber:$a){
                 properties{
                   id
                   address
                   electricityMeterPoints{mpan direction status}
                   gasMeterPoints{mprn status}
                 }
                 electricityAgreements(active:true){meterPoint{mpan}}
                 gasAgreements(active:true){meterPoint{mprn}}
               }}""",
            {"a": account},
            token,
        )["account"]
        live_e = {(a.get("meterPoint") or {}).get("mpan") for a in listing.get("electricityAgreements") or []}
        live_g = {(a.get("meterPoint") or {}).get("mprn") for a in listing.get("gasAgreements") or []}
        for prop in listing.get("properties") or []:
            print(f"Property {prop['id']}: {(prop.get('address') or '').splitlines()[0] if prop.get('address') else '?'}")
            for point in prop.get("electricityMeterPoints") or []:
                live = "active agreement" if point.get("mpan") in live_e else "no active agreement"
                print(f"    electricity  MPAN {point.get('mpan')}  {point.get('direction') or ''}  {live}")
            for point in prop.get("gasMeterPoints") or []:
                live = "active agreement" if point.get("mprn") in live_g else "no active agreement"
                print(f"    gas          MPRN {point.get('mprn')}  {point.get('status') or ''}  {live}")
            if not (prop.get("electricityMeterPoints") or prop.get("gasMeterPoints")):
                print("    (no meters)")
        return

    details = run(
        """query($a:String!){account(accountNumber:$a){
             properties{id address electricityMeterPoints{mpan direction}}
             electricityAgreements(active:true){meterPoint{mpan} timeOfUseScheme{timezone}}
           }}""",
        {"a": account},
        token,
    )["account"]
    # Pair each property with its own meters. Taking properties[0] and the first agreement
    # separately can name a property and an MPAN at different addresses.
    active = {
        (a.get("meterPoint") or {}).get("mpan"): a
        for a in details.get("electricityAgreements") or []
    }
    meters = [
        {"property": prop["id"], "address": (prop.get("address") or "").split("\n")[0],
         "mpan": point["mpan"], "agreement": active[point["mpan"]]}
        for prop in details.get("properties") or []
        for point in prop.get("electricityMeterPoints") or []
        if str(point.get("direction")).upper() != "EXPORT" and point.get("mpan") in active
    ]
    if not meters:
        sys.exit("No electricity import meter with an active agreement was found.")
    if args.mpan:
        meters = [m for m in meters if m["mpan"] == args.mpan]
        if not meters:
            sys.exit(f"No import meter matching MPAN {args.mpan}.")
    if len(meters) > 1:
        print("Several import meters on this account; showing the first. Use --mpan to choose:")
        for m in meters:
            print(f"  {m['mpan']}  {m['address']}")
        print()
    meter = meters[0]
    mpan, prop_id, agreement = meter["mpan"], meter["property"], meter["agreement"]

    tz_name = (agreement.get("timeOfUseScheme") or {}).get("timezone") or "Europe/London"
    tz = ZoneInfo(tz_name)

    today = datetime.now(tz).replace(hour=0, minute=0, second=0, microsecond=0)
    days = [today - timedelta(days=offset) for offset in range(args.days - 1, -1, -1)]

    rows = []
    for index, day in enumerate(days):
        try:
            rows.extend(fetch_day(prop_id, mpan, day, tz_name, token, debug=args.debug and index == 0))
        except RuntimeError as exc:
            print(f"{day:%a %d %b}: {exc}", file=sys.stderr)

    if not rows:
        sys.exit("No half-hourly measurements came back. Try --debug, or a smaller --days.")

    threshold, low, high = classify(rows)
    priced = sum(1 for r in rows if r["rate"] is not None)
    where = f" · {meter['address']}" if meter["address"] else ""
    print(f"MPAN {mpan}{where} · {tz_name} · {len(rows)} half hours, {priced} priced")
    if threshold is None and low is None:
        print("No unit rates came back, so cheap periods can't be identified. Try --debug.")
    elif threshold is None:
        print(f"Only one rate seen ({low:.2f}p–{high:.2f}p), so there is no off-peak window to show.")
    else:
        print(f"Off-peak {low:.2f}p · standard {high:.2f}p · counting anything under {threshold:.2f}p as off-peak")
    print("Costs include VAT and exclude the standing charge, which is shown per day.\n")

    by_day = {}
    for row in rows:
        by_day.setdefault(row["start"].astimezone(tz).date(), []).append(row)

    # Every requested day gets a line, so a day Octopus hasn't published yet is visible as such
    # rather than silently missing. It runs roughly two days behind.
    wanted = [day.date() for day in days]

    if threshold is not None:
        print("        " + "".join(f"{hour:<4}" for hour in range(0, 24, 2)))
        for date in wanted:
            print(f"{date:%a %d}  " + strip(by_day.get(date, []), threshold, tz))
        print("        █ off-peak   ▓ off-peak, smart charge   ▒ standard   ░ no usage   · not published\n")

    for date in wanted:
        day_rows = by_day.get(date, [])
        if not day_rows:
            print(f"{date:%a %d %b}   not published yet")
            continue
        kwh = sum(r["kwh"] or 0 for r in day_rows)
        pence = sum(r["pence"] or 0 for r in day_rows)
        standing = sum(r["standing"] or 0 for r in day_rows)
        print(f"{date:%a %d %b}   {kwh:.2f} kWh   £{pence / 100:.2f} + £{standing / 100:.2f} standing")
        if threshold is None:
            continue
        cheap_runs = runs_of_cheap(day_rows, threshold)
        cheap_kwh = sum(period["kwh"] for period in cheap_runs)
        for period in cheap_runs:
            start_local = period["start"].astimezone(tz)
            end_local = period["end"].astimezone(tz) if period["end"] else start_local
            rate = period["pence"] / period["kwh"] if period["kwh"] else 0
            smart = " (smart charge)" if any("EV_DEVICE" in b for b in period["buckets"]) else ""
            print(
                f"    off-peak {start_local:%H:%M}–{end_local:%H:%M}   "
                f"{period['kwh']:.2f} kWh @ {rate:.2f}p{smart}"
            )
        if kwh:
            print(f"    {cheap_kwh / kwh * 100:.0f}% of the day's usage at the off-peak rate")

    if args.peaks:
        print(f"\nTop {args.peaks} half hours by usage")
        print("  A half hour at 7 kW is 3.5 kWh. 'meter' is the interval total the meter reported;")
        print("  'buckets' is what the tariff charged, which should add up to the same.")
        print("  The EV_DEVICE bucket is a fixed billing allocation, not a measurement of the car:")
        print("  the rest of its draw lands in the household bucket at the same price.\n")
        for row in sorted(rows, key=lambda r: r["kwh"] or 0, reverse=True)[: args.peaks]:
            meter = row["kwh"] or 0
            charged = row["charged_kwh"] or 0
            flag = "" if abs(meter - charged) < 0.005 else "   <-- meter and buckets disagree"
            print(
                f"  {row['start'].astimezone(tz):%a %d %b %H:%M}  meter {meter:.3f} kWh"
                f" = {meter * 2:.2f} kW  ·  buckets {charged:.3f} kWh{flag}")
            for part in row["detail"]:
                price = f"{part['price']:.2f}p" if part["price"] else "?"
                print(f"        {part['bucket']:<24} {part['kwh']:.3f} kWh @ {price}")

    if args.csv:
        with open(args.csv, "w", newline="") as handle:
            writer = csv.writer(handle)
            writer.writerow(
                ["start_local", "end_local", "kwh", "pence", "standing_pence", "rate_p_per_kwh", "bucket", "cheap"]
            )
            for row in sorted(rows, key=lambda r: r["start"]):
                writer.writerow([
                    row["start"].astimezone(tz).isoformat(),
                    row["end"].astimezone(tz).isoformat() if row["end"] else "",
                    row["kwh"], row["pence"], row["standing"],
                    f"{row['rate']:.4f}" if row["rate"] else "",
                    "|".join(row["buckets"]),
                    "" if row["rate"] is None or threshold is None else int(row["rate"] < threshold),
                ])
        print(f"\nWrote {len(rows)} rows to {args.csv}")

    if args.dispatches:
        print_dispatches(account, token, rows, threshold, days[0], tz)

    if args.sessions:
        print("\nCharging sessions")
        after = (today - timedelta(days=args.days - 1)).astimezone(timezone.utc)
        try:
            devices = gql(SESSIONS_QUERY, {"a": account, "after": after.isoformat()}, token)["devices"]
        except RuntimeError as exc:
            print(f"  unavailable ({exc})")
            return
        found = False
        for device in devices or []:
            label = " ".join(filter(None, [device.get("make"), device.get("model")])) or device.get("name")
            for edge in ((device.get("chargingSessions") or {}).get("edges")) or []:
                node = edge.get("node") or {}
                found = True
                began, ended = parse(node.get("start")), parse(node.get("end"))
                added = (node.get("energyAdded") or {}).get("value")
                money = node.get("cost") or {}
                amount = to_float(money.get("amount"))
                parts = [f"  {label}  {began.astimezone(tz):%a %d %b %H:%M}"]
                if ended:
                    # Overnight sessions end the next day; a bare time read as ending before it began.
                    same_day = ended.astimezone(tz).date() == began.astimezone(tz).date()
                    parts.append(f"–{ended.astimezone(tz):{'%H:%M' if same_day else '%a %d %b %H:%M'}}")
                if added is not None:
                    parts.append(f"  {to_float(added):.2f} kWh")
                if amount is not None:
                    parts.append(f"  {money.get('currency', '')}{amount:.2f}")
                if node.get("type"):
                    parts.append(f"  {node['type'].lower()}")
                print("".join(parts))
                for dispatch in node.get("dispatches") or []:
                    start_d, end_d = parse(dispatch.get("start")), parse(dispatch.get("end"))
                    print(
                        f"      dispatch {start_d.astimezone(tz):%H:%M}–{end_d.astimezone(tz):%H:%M}"
                        f"  {to_float(dispatch.get('energyAddedKwh')) or 0:.2f} kWh"
                    )
        if not found:
            print("  none in this period")


def print_dispatches(account, token, rows, threshold, since, tz):
    """Smart charges Octopus says it ran, against the rate each half hour was actually billed at.

    A dispatch outside the off-peak window should be billed cheap. One billed at the standard rate
    is a billing question for Octopus; a car-sized draw at the standard rate with no dispatch at
    all was started by something else — the car's own timer, the charger, or a boost.
    """
    print("\nCompleted smart charges")
    try:
        dispatches = gql(DISPATCHES_QUERY, {"a": account}, token).get("completedDispatches") or []
    except RuntimeError as exc:
        print(f"  unavailable ({exc})")
        return
    by_start = {row["start"]: row for row in rows}
    covered = set()
    shown = 0
    # The list is patchy, not a rolling window: on the account this was written against it returned
    # something older than the period while missing smart charges the bill proves ran within it.
    # Say what was left out, so its shape is visible rather than guessed at.
    older = sorted(
        parse(d["start"]) for d in dispatches
        if d.get("start") and d.get("end") and parse(d["end"]) <= since)
    if older:
        print(f"  ({len(older)} older, not shown: {older[0].astimezone(tz):%a %d %b} "
              f"to {older[-1].astimezone(tz):%a %d %b})")
    for dispatch in sorted(dispatches, key=lambda d: d.get("start") or ""):
        start, end = parse(dispatch.get("start")), parse(dispatch.get("end"))
        if not start or not end or end <= since:
            continue
        shown += 1
        same_day = start.astimezone(tz).date() == end.astimezone(tz).date()
        span = (f"{start.astimezone(tz):%a %d %b %H:%M}–"
                f"{end.astimezone(tz):{'%H:%M' if same_day else '%a %d %b %H:%M'}}")
        # Import is stated negative; the sign says nothing the heading doesn't.
        delta = to_float(dispatch.get("delta"))
        meta = dispatch.get("meta") or {}
        extras = [f"{abs(delta):.2f} kWh" if delta is not None else None,
                  meta.get("source"), meta.get("location")]
        print(f"  {span}  " + "  ".join(e for e in extras if e))
        # The half hours the dispatch touches, and what each was billed at.
        slot = start.replace(minute=0 if start.minute < 30 else 30, second=0, microsecond=0)
        while slot < end:
            covered.add(slot)
            row = by_start.get(slot)
            if row is None:
                print(f"      {slot.astimezone(tz):%H:%M}  not published")
            elif row["rate"] is None:
                print(f"      {slot.astimezone(tz):%H:%M}  {row['kwh'] or 0:.2f} kWh, too little to price")
            else:
                cheap = threshold is not None and row["rate"] < threshold
                flag = "" if cheap or threshold is None else "   <-- billed at the standard rate"
                print(f"      {slot.astimezone(tz):%H:%M}  {row['kwh'] or 0:.2f} kWh @ {row['rate']:.2f}p{flag}")
            slot += timedelta(minutes=30)
    if not shown:
        print("  none in this period")

    if threshold is None:
        return
    car_sized = [
        row for row in sorted(rows, key=lambda r: r["start"])
        if row["rate"] is not None and row["rate"] >= threshold
        and (row["kwh"] or 0) >= CAR_SIZED_KWH and row["start"] not in covered
    ]
    # The bill is the check on the list: a half hour billed as a smart charge that no listed
    # dispatch covers proves the list is missing dispatches, and then "no dispatch" proves nothing.
    missed = [
        row for row in rows
        if any("EV_DEVICE" in bucket for bucket in row["buckets"]) and row["start"] not in covered
    ]
    print(f"\nStandard-rate half hours of {CAR_SIZED_KWH} kWh or more with no smart charge")
    if missed:
        first, last = min(r["start"] for r in missed), max(r["start"] for r in missed)
        print(f"  Can't tell: {len(missed)} half hours billed as smart charges "
              f"({first.astimezone(tz):%a %d %b %H:%M} to {last.astimezone(tz):%a %d %b %H:%M})")
        print("  are missing from Octopus's completed list, so a missing one proves nothing. Candidates:")
        for row in car_sized:
            print(f"    {row['start'].astimezone(tz):%a %d %b %H:%M}  {row['kwh']:.2f} kWh @ {row['rate']:.2f}p")
        if not car_sized:
            print("    none")
        return
    for row in car_sized:
        print(f"  {row['start'].astimezone(tz):%a %d %b %H:%M}  {row['kwh']:.2f} kWh @ {row['rate']:.2f}p")
    if not car_sized:
        print("  none")


if __name__ == "__main__":
    main()
