#!/usr/bin/env python3
"""Find out how (and whether) gas readings come back for this account.

The app's gas chart is empty, and there are several possible reasons: the wrong reading
frequency, a filter that wants something other than the MPRN, or simply no published readings.
This tries each combination and reports what came back, so the fix follows the evidence.

Usage: OCTOPUS_API_KEY=sk_live_... python3 gas_probe.py [--days 30]
"""
import argparse
import json
import os
import sys
import urllib.request
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

URL = "https://api.octopus.energy/v1/graphql/"
TZ = ZoneInfo("Europe/London")

# Every frequency the schema allows, finest first.
FREQUENCIES = [
    "THIRTY_MIN_INTERVAL", "HOUR_INTERVAL", "DAY_INTERVAL", "DAILY",
    "POINT_IN_TIME", "INTERVALIZED", "RAW_INTERVAL", "WEEK_INTERVAL", "MONTH_INTERVAL",
]


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


def measurements(prop_id, start, end, filters, first, token):
    query = """query($p:ID!,$s:DateTime!,$e:DateTime!,$tz:String!,$n:Int!,$f:[UtilityFiltersInput]){
      property(id:$p){
        measurements(startAt:$s,endAt:$e,timezone:$tz,first:$n,utilityFilters:$f){
          totalCount
          edges{node{
            value
            unit
            ... on IntervalMeasurementType{startAt endAt durationInSeconds}
            metaData{statistics{type label value costInclTax{estimatedAmount pricePerUnit{amount}}}}
          }}
        }
      }
    }"""
    data = gql(
        query,
        {
            "p": prop_id, "tz": "Europe/London", "n": first,
            "s": start.isoformat(), "e": end.isoformat(), "f": filters,
        },
        token,
    )
    return ((data.get("property") or {}).get("measurements")) or {}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--days", type=int, default=30)
    args = parser.parse_args()

    key = os.environ.get("OCTOPUS_API_KEY")
    if not key:
        sys.exit("Set OCTOPUS_API_KEY in your environment.")
    token = gql(
        "mutation($k:String!){obtainKrakenToken(input:{APIKey:$k}){token}}", {"k": key}
    )["obtainKrakenToken"]["token"]
    account = gql("{viewer{accounts{number}}}", token=token)["viewer"]["accounts"][0]["number"]

    detail = gql(
        """query($a:String!){account(accountNumber:$a){
             properties{
               id
               address
               gasMeterPoints{mprn status meters{id serialNumber}}
             }
             gasAgreements(active:true){meterPoint{mprn} validFrom validTo}
           }}""",
        {"a": account},
        token,
    )["account"]

    print("Gas agreements:", json.dumps(detail.get("gasAgreements"), indent=2))

    end = datetime.now(TZ).replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(days=1)
    start = end - timedelta(days=args.days)
    print(f"\nWindow: {start:%d %b} to {end:%d %b}\n")

    for prop in detail.get("properties") or []:
        points = prop.get("gasMeterPoints") or []
        if not points:
            continue
        address = (prop.get("address") or "").split(",")[0]
        for point in points:
            mprn = point.get("mprn")
            meters = point.get("meters") or []
            print(f"== {address} · MPRN {mprn} · status {point.get('status')}")
            print(f"   meters: {[m.get('serialNumber') for m in meters]}")

            attempts = [("mprn", {"gasFilters": {"marketSupplyPointId": mprn}})]
            for meter in meters:
                attempts.append(
                    ("deviceId " + str(meter.get("serialNumber")),
                     {"gasFilters": {"deviceId": meter.get("id")}}))
            attempts.append(("no supply point", {"gasFilters": {}}))

            for how, base in attempts:
                for freq in FREQUENCIES:
                    filters = json.loads(json.dumps(base))
                    filters["gasFilters"]["readingFrequencyType"] = freq
                    try:
                        result = measurements(prop["id"], start, end, [filters], 5, token)
                    except RuntimeError as exc:
                        print(f"   {how:<24} {freq:<20} error: {exc}")
                        continue
                    edges = result.get("edges") or []
                    if not edges:
                        print(f"   {how:<24} {freq:<20} empty (totalCount {result.get('totalCount')})")
                        continue
                    node = edges[0]["node"]
                    print(f"   {how:<24} {freq:<20} {len(edges)} rows, totalCount {result.get('totalCount')}")
                    print("      first: " + json.dumps(node)[:400])
            print()


if __name__ == "__main__":
    main()
