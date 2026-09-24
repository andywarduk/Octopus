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


def to_float(value):
    """Decimal fields arrive as strings, and can be null."""
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def day_label(when, now_local):
    delta = (when.date() - now_local.date()).days
    return {0: "Today", 1: "Tomorrow", -1: "Yesterday"}.get(delta, f"{when:%a}")


def stamp(when, now_local):
    return f"{day_label(when, now_local)} {when:%H:%M}"


# datetime.weekday() is 0 for Monday, which is the order Octopus names its schedule days in.
WEEKDAY_NAMES = ["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"]


def todays_charge_goal(preferences, now_local):
    """Today's target state of charge and the time it should be reached by.

    `chargingPreferences` is deprecated in favour of `preferences`, which is also the only one
    carrying the ready-by time. The schedule is per day of week and its times are local.
    """
    if not preferences:
        return None, None
    schedules = preferences.get("schedules") or []
    today = WEEKDAY_NAMES[now_local.weekday()]
    match = next(
        (s for s in schedules if str(s.get("dayOfWeek", "")).upper() == today),
        schedules[0] if schedules else None,
    )
    if not match:
        return None, None
    # Only a percentage is a state of charge. The same field can hold a kWh or mileage goal, and
    # printing one of those with a % after it would be a plain lie.
    is_percentage = str(preferences.get("unit", "")).upper() == "PERCENTAGE"
    value = to_float(match.get("max"))
    if value is None:
        value = to_float(match.get("upperLimit"))
    ready = match.get("time")
    return (
        round(value) if is_percentage and value is not None else None,
        ready[:5] if isinstance(ready, str) else None,
    )


def tariff_ends(account_node, now):
    """Every active agreement, one per meter point, never merged.

    Includes variable tariffs, which have no `validTo` — Intelligent Octopus Go is one, and it is
    the tariff the prices above come from. An agreement that hasn't started yet is the replacement
    waiting to take over, not something in force.
    """
    rows = []
    for prop in account_node.get("properties") or []:
        address = prop.get("address") or ""
        place = address.split(",")[0].strip()
        for field, fuel in (("electricityMeterPoints", "electricity"), ("gasMeterPoints", "gas")):
            for point in prop.get(field) or []:
                for agreement in point.get("agreements") or []:
                    if agreement.get("isRevoked"):
                        continue
                    ends = parse(agreement["validTo"]) if agreement.get("validTo") else None
                    if ends is not None and ends <= now:
                        continue
                    if agreement.get("validFrom") and parse(agreement["validFrom"]) > now:
                        continue
                    name = (agreement.get("tariff") or {}).get("displayName") or f"{fuel} tariff"
                    rows.append((fuel, name, ends, place))
    # Soonest expiry first, the never-ending ones last, then grouped by address.
    return sorted(rows, key=lambda r: (r[2] is None, r[2] or now, r[3], r[0]))


def balance_text(pence):
    """Octopus states a balance as positive when you're in credit, so the sign carries meaning."""
    return f"£{abs(pence) / 100:.2f} {'owed' if pence < 0 else 'in credit'}"


def charging_status(status, now):
    """Octopus doesn't report "plugged in", so infer charging from live power and smart-control state."""
    state = status.get("currentState") or ""
    # A lost connection explains anything else we might say, so it wins.
    if state == "LOST_CONNECTION":
        return "Lost connection to car"

    power = status.get("activePower") or {}
    power_at = parse(power["timestamp"]) if power.get("timestamp") else None
    kw = to_float(power.get("value"))
    fresh = power_at is not None and (now - power_at).total_seconds() < 20 * 60

    # isSuspended means smart control is paused, not that charging stopped: a suspended car
    # left plugged in still draws power. It says nothing when control isn't available.
    paused = status.get("isSuspended") is True and state != "SMART_CONTROL_NOT_AVAILABLE"
    annotated = lambda text: text + " · smart control paused" if paused else text

    if fresh and kw is not None and kw > 0.05:
        charging = f"Charging {kw:.1f} kW"
        if state == "BOOSTING":
            return charging + " · boost"
        if state == "SMART_CONTROL_IN_PROGRESS":
            return charging + " · smart charging"
        return annotated(charging)
    if state == "BOOSTING":
        return "Boost charge requested"
    if state == "SMART_CONTROL_IN_PROGRESS":
        return "Smart charging scheduled"
    if state == "SMART_CONTROL_NOT_AVAILABLE":
        return "Not charging · smart control not available"
    if state in ("SMART_CONTROL_CAPABLE", "SMART_CONTROL_OFF", "SETUP_COMPLETE", ""):
        if fresh:
            return annotated("Not charging")
        return "Smart control paused" if paused else None
    return annotated(state.replace("_", " ").capitalize())


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

# The tariff states VAT-inclusive rates by name; applicableRates quotes them before tax.
# Balance and agreement end dates hang off the same account node, so they ride along here rather
# than costing another request.
account_node = run(
    """query($a:String!){account(accountNumber:$a){
      balance
      projectedBalance
      electricityAgreements(active:true){
        validTo
        meterPoint{mpan direction}
        timeOfUseScheme{timezone timeslots{timeslot activeFrom activeTo}}
        tariff{
          __typename
          ... on TariffType{displayName}
          ... on StandardTariff{unitRate standingCharge}
          ... on PrepayTariff{unitRate standingCharge}
          ... on DayNightTariff{dayRate nightRate standingCharge}
          ... on ThreeRateTariff{dayRate nightRate offPeakRate standingCharge}
          ... on FourRateEvTariff{dayRate nightRate evDevicePeakRate evDeviceOffPeakRate standingCharge}
          ... on HalfHourlyTariff{standingCharge}
        }
      }
      properties{
        address
        electricityMeterPoints{agreements{validFrom validTo isRevoked tariff{... on TariffType{displayName}}}}
        gasMeterPoints{agreements{validFrom validTo isRevoked tariff{... on TariffType{displayName}}}}
      }
    }}""",
    {"a": account},
    token,
)["account"]
agreements = account_node["electricityAgreements"]
imports = [x for x in agreements if str(x["meterPoint"].get("direction")).upper() != "EXPORT"]
if not imports:
    sys.exit("No electricity import meter found.")
if len(imports) > 1:
    others = ", ".join(x["meterPoint"]["mpan"] for x in imports[1:])
    print(f"Note: account has several import meters; using {imports[0]['meterPoint']['mpan']} (also: {others})")
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
VAT_MULTIPLIER = 1.05  # domestic energy; only needed for the applicableRates fallback
RATE_FIELDS = ("unitRate", "dayRate", "nightRate", "offPeakRate", "evDevicePeakRate", "evDeviceOffPeakRate")

tariff = agreement.get("tariff") or {}
tariff_rates = sorted({round(v, 4) for f in RATE_FIELDS if (v := to_float(tariff.get(f))) and v > 0})
if tariff_rates:
    cheap_rate, peak_rate = tariff_rates[0], tariff_rates[-1]
else:
    values = sorted({round(float(e["node"]["value"]) * VAT_MULTIPLIER, 4) for e in data["applicableRates"]["edges"]})
    if not values:
        sys.exit("No applicable rates returned.")
    cheap_rate, peak_rate = values[0], values[-1]
standing_charge = to_float(tariff.get("standingCharge"))

if standing_charge:
    print(f"Standing charge {standing_charge:.2f}p/day incl VAT")

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
    # Whichever source the rates came from; `values` only exists on the fallback path.
    print("rates:", tariff_rates or values)
    print("schedule:", json.dumps(scheme))
    print("windows:", [(a.isoformat(), b.isoformat()) for a, b in windows], f"({source})")
    for d in dispatches:
        print(f"dispatch {d['start']} -> {d['end']}")
    print("now:", now_local.isoformat())

# A single-rate tariff has no cheap window, whatever the schedule says.
if peak_rate - cheap_rate < 0.01:
    print(f"Now: SINGLE RATE  ({peak_rate:.2f}p/kWh incl VAT)")
    print("This tariff has no cheap window.")
else:
    active_dispatches = [d for d in dispatches if parse(d["start"]) <= now < parse(d["end"])]
    in_cheap_window = any(in_window(now_local.time(), a, b) for a, b in windows)
    cheap = bool(active_dispatches) or in_cheap_window

    print(f"Now: {'CHEAP' if cheap else 'PEAK'}  ({(cheap_rate if cheap else peak_rate):.2f}p/kWh incl VAT)")
    if active_dispatches:
        print("In a smart-charging dispatch window.")

    change = next_boundary(now_local, windows)
    if cheap:
        if active_dispatches and not in_cheap_window:
            change = max(parse(d["end"]) for d in active_dispatches).astimezone(tz)
        print(f"Next change {stamp(change, now_local)} -> {peak_rate:.2f}p/kWh")
    else:
        starts = [parse(d["start"]).astimezone(tz) for d in dispatches if parse(d["start"]) > now]
        change = min([change, *starts])
        print(f"Next change {stamp(change, now_local)} -> {cheap_rate:.2f}p/kWh")

# Car charge level. Kept separate so a failure here never hides the rate result above.
DEVICES_QUERY = """query($a:String!){devices(accountNumber:$a){
  __typename id name
  ... on SmartFlexVehicle{
    make model vehicleBatterySize
    status{... on SmartFlexVehicleStatus{currentState isSuspended stateOfCharge{value timestamp} activePower{value timestamp}}}
    preferences{unit schedules{dayOfWeek time max upperLimit}}
  }
  ... on SmartFlexChargePoint{
    status{... on SmartFlexChargePointStatus{currentState isSuspended stateOfCharge{value timestamp} activePower{value timestamp}}}
  }
}}"""
try:
    devices = gql(DEVICES_QUERY, {"a": account}, token)["devices"] or []
except RuntimeError as exc:
    devices = []
    print(f"Car: unavailable ({exc})")

if DEBUG:
    print("devices:", json.dumps(devices))

for dev in devices:
    status = dev.get("status") or {}
    soc = status.get("stateOfCharge") or {}
    label = (
        " ".join(filter(None, [dev.get("make"), dev.get("model")]))
        or dev.get("name")
        or dev["__typename"]
    )
    value = to_float(soc.get("value"))
    if value is None:
        print(f"{label}: no charge level reported")
        continue
    line = f"{label}: {value:.0f}%"
    target, ready_by = todays_charge_goal(dev.get("preferences"), now_local)
    if target is not None:
        line += f" (target {target}%" + (f" by {ready_by})" if ready_by else ")")
    print(line)
    # Derived from two figures the API gives, so "about": the state of charge arrives rounded.
    capacity = to_float(dev.get("vehicleBatterySize"))
    if capacity:
        print(f"    About {capacity * value / 100:.1f} of {capacity:.1f} kWh in the battery")
    state = charging_status(status, now)
    if state:
        print(f"    {state}")
    if soc.get("timestamp"):
        print(f"    Charge level as of {stamp(parse(soc['timestamp']).astimezone(tz), now_local)}")

# Balance and anything about to expire, last — same order as the app's menu.
balance = account_node.get("balance")
if balance is not None:
    line = f"Balance {balance_text(balance)}"
    projected = account_node.get("projectedBalance")
    if projected is not None:
        line += f" · {balance_text(projected)} expected in a year"
    print(line)

# How far ahead an ending tariff is worth mentioning.
places = len(account_node.get("properties") or [])
for fuel, name, ends, place in tariff_ends(account_node, now):
    # The address only earns its place when the account holds more than one.
    at = f" at {place}" if places > 1 and place else ""
    if ends is None:
        print(f"{name} ({fuel}){at} — no end date")
        continue
    # validTo is the instant cover stops, and these end at midnight — so the raw date is the first
    # day of the next tariff. Step back a second for the last day actually covered.
    last = (ends - timedelta(seconds=1)).astimezone(tz)
    days = (last.date() - now_local.date()).days
    when = "today" if days <= 0 else "tomorrow" if days == 1 else f"in {days} days"
    print(f"{name} ({fuel}){at} ends {last:%a} {last.day} {last:%b} — {when}")
