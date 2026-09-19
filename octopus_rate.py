#!/usr/bin/env python3
"""Report whether you're on the cheap or peak rate right now (Intelligent Octopus).

Usage: OCTOPUS_API_KEY=sk_live_... python3 octopus_rate.py
Set DEBUG=1 to print the raw rates, schedule and dispatches.
"""
import json
import os
import sys
import urllib.request
from datetime import datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

URL = "https://api.octopus.energy/v1/graphql/"
# Intelligent Octopus Go default cheap window, used if the tariff schedule can't be read.
FALLBACK_WINDOW = (time(23, 30), time(5, 30))
DEBUG = bool(os.environ.get("DEBUG"))


def gql(query, variables=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = token
    req = urllib.request.Request(
        URL, json.dumps({"query": query, "variables": variables or {}}).encode(), headers
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        body = json.load(r)
    if body.get("errors"):
        raise RuntimeError(body["errors"][0].get("message"))
    return body["data"]


def run(*a, **k):
    try:
        return gql(*a, **k)
    except RuntimeError as exc:
        sys.exit(f"GraphQL error: {exc}")


def parse(ts):
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def in_window(t, start, end):
    return start <= t < end if start <= end else t >= start or t < end


def next_boundary(now_local, windows):
    """Next local datetime at which any window edge is crossed."""
    edges = []
    for start, end in windows:
        for edge in (start, end):
            candidate = now_local.replace(hour=edge.hour, minute=edge.minute, second=0, microsecond=0)
            if candidate <= now_local:
                candidate += timedelta(days=1)
            edges.append(candidate)
    return min(edges)


key = os.environ.get("OCTOPUS_API_KEY")
if not key:
    sys.exit("Set OCTOPUS_API_KEY in your environment.")

token = run(
    "mutation($k:String!){obtainKrakenToken(input:{APIKey:$k}){token}}", {"k": key}
)["obtainKrakenToken"]["token"]

account = run("{viewer{accounts{number}}}", token=token)["viewer"]["accounts"][0]["number"]

agreements = run(
    """query($a:String!){account(accountNumber:$a){electricityAgreements(active:true){
      meterPoint{mpan direction}
      timeOfUseScheme{timezone timeslots{timeslot activeFrom activeTo}}
    }}}""",
    {"a": account},
    token,
)["account"]["electricityAgreements"]
imports = [x for x in agreements if str(x["meterPoint"].get("direction")).upper() != "EXPORT"]
agreement = imports[0]
mpan = agreement["meterPoint"]["mpan"]

now = datetime.now(timezone.utc)
end = now + timedelta(hours=24)
RATES_QUERY = """query($a:String!,$m:String!,$s:DateTime!,$e:DateTime!,$n:Int!){
      applicableRates(accountNumber:$a,mpxn:$m,startAt:$s,endAt:$e,first:$n){edges{node{value validFrom validTo}}}
      plannedDispatches(accountNumber:$a){start end}
      completedDispatches(accountNumber:$a){start end}
    }"""

data = None
for page_size in (100, 50, 25, 10):
    try:
        data = gql(
            RATES_QUERY,
            {"a": account, "m": mpan, "s": now.isoformat(), "e": end.isoformat(), "n": page_size},
            token,
        )
        break
    except RuntimeError as exc:
        if "pagination" not in str(exc).lower():
            sys.exit(f"GraphQL error: {exc}")
        last_error = exc
if data is None:
    sys.exit(f"GraphQL error: {last_error}")

# applicableRates returns the tariff's rate bands clipped to the query window, so the
# validFrom/validTo values don't say when each band applies. Use the lowest and highest.
values = sorted({round(float(e["node"]["value"]), 4) for e in data["applicableRates"]["edges"]})
if not values:
    sys.exit("No applicable rates returned.")
cheap_rate, peak_rate = values[0], values[-1]

scheme = agreement.get("timeOfUseScheme")
tz = ZoneInfo((scheme or {}).get("timezone") or "Europe/London")
now_local = now.astimezone(tz)

windows = []
if scheme:
    windows = [
        (time.fromisoformat(s["activeFrom"]), time.fromisoformat(s["activeTo"]))
        for s in scheme["timeslots"]
        if any(w in s["timeslot"].lower() for w in ("off", "cheap", "night"))
    ]
source = "tariff schedule"
if not windows:
    windows, source = [FALLBACK_WINDOW], "default 23:30-05:30 window"

dispatches = (data["plannedDispatches"] or []) + (data["completedDispatches"] or [])
if DEBUG:
    print("rates:", values)
    print("schedule:", json.dumps(scheme))
    print("windows:", [(a.isoformat(), b.isoformat()) for a, b in windows], f"({source})")
    for d in dispatches:
        print(f"dispatch {d['start']} -> {d['end']}")
    print("now:", now_local.isoformat())

active_dispatches = [d for d in dispatches if parse(d["start"]) <= now < parse(d["end"])]
in_cheap_window = any(in_window(now_local.time(), a, b) for a, b in windows)
cheap = bool(active_dispatches) or in_cheap_window

print(f"Now: {'CHEAP' if cheap else 'PEAK'}  ({(cheap_rate if cheap else peak_rate):.2f}p/kWh)")
if active_dispatches:
    print("In a smart-charging dispatch window.")

change = next_boundary(now_local, windows)
if cheap:
    if active_dispatches and not in_cheap_window:
        change = max(parse(d["end"]) for d in active_dispatches).astimezone(tz)
    print(f"Next change {change:%a %H:%M} -> {peak_rate:.2f}p/kWh")
else:
    starts = [parse(d["start"]).astimezone(tz) for d in dispatches if parse(d["start"]) > now]
    change = min([change, *starts])
    print(f"Next change {change:%a %H:%M} -> {cheap_rate:.2f}p/kWh")

# Car charge level. Kept separate so a failure here never hides the rate result above.
DEVICES_QUERY = """query($a:String!){devices(accountNumber:$a){
  __typename id name
  ... on SmartFlexVehicle{
    make model
    status{... on SmartFlexVehicleStatus{currentState stateOfCharge{value timestamp}}}
    chargingPreferences{weekdayTargetSoc weekendTargetSoc}
  }
  ... on SmartFlexChargePoint{
    status{... on SmartFlexChargePointStatus{currentState stateOfCharge{value timestamp}}}
  }
}}"""
try:
    devices = gql(DEVICES_QUERY, {"a": account}, token)["devices"] or []
except RuntimeError as exc:
    devices = []
    print(f"Car: unavailable ({exc})")

if DEBUG:
    print("devices:", json.dumps(devices))

weekend = now_local.weekday() >= 5
for dev in devices:
    status = dev.get("status") or {}
    soc = status.get("stateOfCharge")
    if not soc:
        continue
    label = " ".join(filter(None, [dev.get("make"), dev.get("model")])) or dev.get("name") or dev["__typename"]
    line = f"{label}: {float(soc['value']):.0f}%"
    prefs = dev.get("chargingPreferences")
    if prefs:
        target = prefs["weekendTargetSoc" if weekend else "weekdayTargetSoc"]
        line += f" (target {target}%)"
    if status.get("currentState"):
        line += f", {str(status['currentState']).replace('_', ' ').lower()}"
    line += f"  as of {parse(soc['timestamp']).astimezone(tz):%H:%M}"
    print(line)
if devices and not any((d.get("status") or {}).get("stateOfCharge") for d in devices):
    print("Car: connected, but no charge level is being reported.")
