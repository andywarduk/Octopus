#!/usr/bin/env python3
"""Show which half hours you were actually billed at the cheap rate.

Octopus has no "past cheap periods" endpoint, so this reconstructs them from the half-hourly
measurements on your property: each one carries the unit rate you were charged. That catches
smart-charge dispatches outside the fixed window as well as the window itself.

Usage:
  OCTOPUS_API_KEY=sk_live_... python3 octopus_history.py [options]

Options:
  --days N        days back to pull (default 7)
  --sessions      also list the car's charging sessions
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
    data = gql(
        MEASUREMENTS_QUERY,
        {
            "p": prop_id, "mpan": mpan, "tz": tz_name, "n": 48,
            "s": start.isoformat(), "e": (start + timedelta(days=1)).isoformat(),
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
    # A tariff with one rate has no cheap window; 20% apart is well beyond rounding noise.
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
    """One character per half hour, midnight to midnight."""
    slots = ["·"] * 48
    for row in day_rows:
        local = row["start"].astimezone(tz)
        index = local.hour * 2 + (1 if local.minute >= 30 else 0)
        if not 0 <= index < 48:
            continue
        if row["rate"] is None:
            slots[index] = "·"
        elif threshold and row["rate"] < threshold:
            # Distinguish a smart-charge dispatch from the tariff's own overnight window.
            slots[index] = "▓" if any("EV_DEVICE" in b for b in row["buckets"]) else "█"
        else:
            slots[index] = "▒"
    return "".join(slots)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=7)
    parser.add_argument("--sessions", action="store_true")
    parser.add_argument("--csv")
    parser.add_argument("--debug", action="store_true")
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

    details = run(
        """query($a:String!){account(accountNumber:$a){
             properties{id}
             electricityAgreements(active:true){
               meterPoint{mpan direction}
               timeOfUseScheme{timezone}
             }
           }}""",
        {"a": account},
        token,
    )["account"]
    imports = [
        a for a in details["electricityAgreements"] or []
        if str((a["meterPoint"] or {}).get("direction")).upper() != "EXPORT"
    ]
    if not imports:
        sys.exit("No electricity import meter found.")
    agreement = imports[0]
    mpan = agreement["meterPoint"]["mpan"]
    properties = details.get("properties") or []
    if not properties:
        sys.exit("No property found on this account.")
    prop_id = properties[0]["id"]
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
    print(f"MPAN {mpan} · {tz_name} · {len(rows)} half hours, {priced} priced")
    if threshold is None and low is None:
        print("No unit rates came back, so cheap periods can't be identified. Try --debug.")
    elif threshold is None:
        print(f"Only one rate seen ({low:.2f}p–{high:.2f}p), so there is no cheap window to show.")
    else:
        print(f"Cheap {low:.2f}p · standard {high:.2f}p · counting anything under {threshold:.2f}p as cheap")
    print("Costs include VAT and exclude the standing charge, which is shown per day.\n")

    by_day = {}
    for row in rows:
        by_day.setdefault(row["start"].astimezone(tz).date(), []).append(row)

    if threshold is not None:
        print("        " + "".join(f"{hour:<4}" for hour in range(0, 24, 2)))
        for date in sorted(by_day):
            print(f"{date:%a %d}  " + strip(by_day[date], threshold, tz))
        print("        █ cheap   ▓ smart charge   ▒ standard   · no usage\n")

    for date in sorted(by_day):
        day_rows = by_day[date]
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
                f"    cheap {start_local:%H:%M}–{end_local:%H:%M}   "
                f"{period['kwh']:.2f} kWh @ {rate:.2f}p{smart}"
            )
        if kwh:
            print(f"    {cheap_kwh / kwh * 100:.0f}% of the day's usage at the cheap rate")

    if args.peaks:
        print(f"\nTop {args.peaks} half hours by usage")
        print("  A half hour at 7 kW is 3.5 kWh. 'meter' is the interval total the meter reported;")
        print("  'buckets' is what the tariff charged, which should add up to the same.\n")
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
                    parts.append(f"–{ended.astimezone(tz):%H:%M}")
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


if __name__ == "__main__":
    main()
