#!/usr/bin/env python3
"""Price your last year of half-hourly electricity against Octopus's other tariffs.

Answers "would another tariff have been cheaper?" from what you actually used, not from an
average profile. Your usage comes from your meter; the other tariffs' prices come from Octopus's
public tariff API, for your region. Electricity only, for one import meter.

How each tariff is priced:
  - The house is priced where it actually happened, half hour by half hour.
  - The car is moved. Its energy is found in your usage (half hours billed to the EV smart-charge
    bucket, or drawing car-sized amounts), and on each other tariff it is recharged in the
    cheapest half hours of the next plug-in window, up to the charger's rate. On a flat tariff
    that changes nothing; on Octopus Go it lands in the cheap overnight window; on Agile it lands
    in that night's cheapest half hours.
  - Your current tariff is shown twice: what you were actually billed, and the same usage at
    today's rates, which is the fair comparison with the others.

Fixed and variable tariffs are priced at today's rates, since that is what you would sign up to.
Agile has no "today's rate" for a year, so it is priced at its real half-hourly prices over the
same period — the best available guess, not a forecast.

Usage:
  OCTOPUS_API_KEY=sk_live_... python3 octopus_compare.py [options]

Options:
  --days N               days of usage to price (default 365)
  --mpan MPAN            which import meter, if the account has several
  --charger-kw KW        the car charger's rating (default 7)
  --plugged-in HH:MM-HH:MM
                         when the car is plugged in and can be charged (default 18:00-07:00);
                         use 00:00-00:00 for "always"
  --iog-fixed CHEAP,PEAK,STANDING
                         also price Intelligent Octopus Go 12M Fixed at these rates, in pence
                         including VAT (Octopus does not publish them through the API)
  --cache FILE           where fetched days are kept (default ~/.cache/octopus_compare/MPAN.json)
  --refresh              ignore the cache and fetch every day again

Fetching a year costs one request per day the first time; after that only the last week is
fetched again, since Octopus sometimes corrects a day's costs after publishing them.

Python 3.9 or later, standard library only.
"""
import argparse
import json
import os
import statistics
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

GRAPHQL = "https://api.octopus.energy/v1/graphql/"
REST = "https://api.octopus.energy/v1"
CONSUMPTION_STATS = {"CONSUMPTION_COST", "TOU_BUCKET_COST"}

# A half hour this big, or billed to an EV bucket, is treated as the car charging. 1.5 kWh is
# 3 kW sustained: well above a household baseline, well below a 7 kW charger.
CAR_SIZED_KWH = 1.5

# How far back Octopus has been seen correcting published costs, with room to spare: a charge
# billed at the standard rate was reclassified as a smart charge about two days later. Days this
# recent are fetched again on every run rather than trusted from the cache.
REVISION_DAYS = 7

# The tariffs worth comparing for a home with an EV and no heat pump, storage heaters or battery.
# Cosy, Snug, Flux and Zero need equipment or a home most accounts don't have, so they are left out.
CANDIDATES = [
    "Agile Octopus",
    "Octopus Go",
    "Octopus Go 12M Fixed",
    "Flexible Octopus",
    "Octopus 12M Fixed",
    "Octopus 18M Fixed",
]

# The distributor id at the start of an MPAN names the region Octopus prices by.
REGIONS = {
    "10": "A", "11": "B", "12": "C", "13": "D", "14": "E", "15": "F", "16": "G",
    "17": "P", "18": "N", "19": "J", "20": "H", "21": "K", "22": "L", "23": "M",
}


# ---------------------------------------------------------------------------------------------
# Network


def fetch(request, attempts=4):
    """urlopen with a few retries: a year of requests will meet the odd dropped connection."""
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return json.load(response)
        except (OSError, ValueError):
            if attempt == attempts - 1:
                raise
            time.sleep(2 * (attempt + 1))


def gql(query, variables=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = token
    body = fetch(urllib.request.Request(
        GRAPHQL, json.dumps({"query": query, "variables": variables or {}}).encode(), headers))
    if body.get("errors"):
        raise RuntimeError(body["errors"][0].get("message"))
    return body["data"]


def rest(path, **params):
    url = path if path.startswith("http") else f"{REST}{path}"
    if params:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
    return fetch(url)


def parse(ts):
    return datetime.fromisoformat(ts.replace("Z", "+00:00")) if ts else None


def to_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


# ---------------------------------------------------------------------------------------------
# Your usage

MEASUREMENTS_QUERY = """query($p:ID!,$s:DateTime!,$e:DateTime!,$mpan:String!,$tz:String!,$n:Int!){
  property(id:$p){
    measurements(startAt:$s,endAt:$e,timezone:$tz,first:$n,
      utilityFilters:[{electricityFilters:{readingFrequencyType:THIRTY_MIN_INTERVAL,marketSupplyPointId:$mpan,readingDirection:CONSUMPTION}}]){
      edges{node{
        value
        ... on IntervalMeasurementType{startAt}
        metaData{statistics{type label value costInclTax{estimatedAmount}}}
      }}
    }
  }
}"""

ACCOUNT_QUERY = """query($a:String!){account(accountNumber:$a){
  properties{id address electricityMeterPoints{mpan direction}}
  electricityAgreements(active:true){
    meterPoint{mpan}
    timeOfUseScheme{timezone timeslots{timeslot activeFrom activeTo}}
    tariff{
      __typename
      ... on TariffType{displayName}
      ... on StandardTariff{unitRate standingCharge}
      ... on DayNightTariff{dayRate nightRate standingCharge}
      ... on ThreeRateTariff{dayRate nightRate offPeakRate standingCharge}
      ... on FourRateEvTariff{dayRate nightRate evDevicePeakRate evDeviceOffPeakRate standingCharge}
      ... on HalfHourlyTariff{standingCharge}
    }
  }
}}"""


def local_midnight(day, tz):
    return datetime(day.year, day.month, day.day, tzinfo=tz)


def fetch_day(token, prop_id, mpan, day, tz):
    """One local day of half hours: start (UTC ISO), kWh, pence billed, standing pence, buckets."""
    start, end = local_midnight(day, tz), local_midnight(day + timedelta(days=1), tz)
    # The day the clocks go back has 50 half hours; subtract in UTC, since two datetimes sharing a
    # tzinfo subtract by wall clock.
    count = round((end.astimezone(timezone.utc) - start.astimezone(timezone.utc)).total_seconds() / 1800)
    data = gql(MEASUREMENTS_QUERY, {
        "p": prop_id, "mpan": mpan, "tz": tz.key, "n": count,
        "s": start.isoformat(), "e": end.isoformat(),
    }, token)
    rows = []
    for edge in (((data.get("property") or {}).get("measurements") or {}).get("edges")) or []:
        node = edge.get("node") or {}
        began = parse(node.get("startAt"))
        if began is None:
            continue
        pence = standing = 0.0
        buckets = []
        for stat in ((node.get("metaData") or {}).get("statistics")) or []:
            amount = to_float((stat.get("costInclTax") or {}).get("estimatedAmount")) or 0.0
            if stat.get("type") == "STANDING_CHARGE_COST":
                standing += amount
            elif stat.get("type") in CONSUMPTION_STATS and (to_float(stat.get("value")) or 0) > 0:
                pence += amount
                buckets.append(stat.get("label") or "")
        rows.append({
            "start": began.astimezone(timezone.utc).isoformat(),
            "kwh": to_float(node.get("value")) or 0.0,
            "pence": pence, "standing": standing, "buckets": buckets,
        })
    return rows, count


def load_usage(token, prop_id, mpan, tz, days, cache_path, refresh):
    """The last `days` published local days, from the cache where possible."""
    cache = {}
    if cache_path and not refresh and os.path.exists(cache_path):
        with open(cache_path) as handle:
            cache = json.load(handle)
    today = datetime.now(tz).date()
    wanted = [today - timedelta(days=offset) for offset in range(days, 0, -1)]
    fetched = 0
    for index, day in enumerate(wanted):
        key = day.isoformat()
        # Octopus revises costs after it publishes them: a smart charge first billed at the standard
        # rate came back repriced two days later. So the last week is always fetched again.
        if key in cache and day < today - timedelta(days=REVISION_DAYS):
            continue
        print(f"\rFetching {day:%d %b %Y} ({index + 1}/{len(wanted)})…", end="", file=sys.stderr)
        try:
            rows, expected = fetch_day(token, prop_id, mpan, day, tz)
        except RuntimeError as exc:
            print(f"\n{day}: {exc}", file=sys.stderr)
            continue
        fetched += 1
        # Only whole days are kept: a part-published day would otherwise be cached short for good.
        # Readings lag about two days, so the last couple are usually incomplete and not kept.
        if len(rows) == expected:
            cache[key] = rows
    if fetched:
        print(file=sys.stderr)
    if cache_path:
        os.makedirs(os.path.dirname(cache_path), exist_ok=True)
        with open(cache_path, "w") as handle:
            json.dump(cache, handle)
    usage = []
    for day in wanted:
        for row in cache.get(day.isoformat(), []):
            usage.append(dict(row, start=parse(row["start"])))
    return sorted(usage, key=lambda r: r["start"])


# ---------------------------------------------------------------------------------------------
# Splitting the car out


def split_car(usage, tz):
    """Adds `car` and `house` kWh to each half hour.

    A half hour is a car half hour when it was billed to an EV smart-charge bucket or drew a
    car-sized amount. The car's share is what it used above the house's usual draw for that time
    of day in that month — the median of the non-car half hours — so an oven on during a charge
    stays with the house.
    """
    def is_car(row):
        return any("EV_DEVICE" in b for b in row["buckets"]) or row["kwh"] >= CAR_SIZED_KWH

    def slot_key(row):
        local = row["start"].astimezone(tz)
        return (local.year, local.month, local.hour * 2 + local.minute // 30)

    baseline = {}
    for row in usage:
        if not is_car(row):
            baseline.setdefault(slot_key(row), []).append(row["kwh"])
    baseline = {key: statistics.median(values) for key, values in baseline.items()}
    for row in usage:
        car = max(0.0, row["kwh"] - baseline.get(slot_key(row), 0.0)) if is_car(row) else 0.0
        row["car"], row["house"] = car, row["kwh"] - car
    return usage


# ---------------------------------------------------------------------------------------------
# Tariffs


class Tariff:
    """A price for any half hour, a daily standing charge, and how to describe it."""

    def __init__(self, name, standing, price, summary):
        self.name, self.standing, self.price, self.summary = name, standing, price, summary
        # True for a tariff priced on your own cheap half hours, where the car already is.
        self.keeps_car = False


def flat(rate):
    return lambda start: rate


def by_local_time(profile, tz):
    """A time-of-use tariff, from one day's rates keyed by local time of day.

    A clock-change day has a local half hour the sample day lacks, or the other way round; such a
    half hour takes the rate of the one before it.
    """
    def price(start):
        local = start.astimezone(tz)
        minutes = local.hour * 60 + (30 if local.minute >= 30 else 0)
        for back in range(0, 48 * 30, 30):
            key = "{:02d}:{:02d}".format(*divmod((minutes - back) % 1440, 60))
            if key in profile:
                return profile[key]
        raise KeyError("empty profile")
    return price


def payment_variant(tariffs):
    """Direct debit where there is a choice; a variable product lists its price as 'varying'."""
    for key in ("direct_debit_monthly", "varying"):
        if key in tariffs:
            return tariffs[key]
    return next(iter(tariffs.values()), None)


def all_pages(url):
    results = []
    while url:
        page = rest(url)
        results += page.get("results") or []
        url = page.get("next")
    return results


def published_tariffs(region, tz, period_start, period_end):
    """Octopus's current tariffs from CANDIDATES, for this region. Returns Tariffs and notes."""
    products = all_pages(f"{REST}/products/?brand=OCTOPUS_ENERGY&is_business=false&page_size=100")
    by_name = {p["display_name"]: p for p in products if p.get("direction") == "IMPORT"}
    tariffs, notes = [], []
    tomorrow = local_midnight(datetime.now(tz).date() + timedelta(days=1), tz)
    for name in CANDIDATES:
        product = by_name.get(name)
        if not product:
            notes.append(f"{name}: not currently offered")
            continue
        detail = rest(f"/products/{product['code']}/")
        regional = (detail.get("single_register_electricity_tariffs") or {}).get(f"_{region}")
        variant = payment_variant(regional or {})
        if not variant:
            notes.append(f"{name}: no published price for region {region}")
            continue
        code = variant["code"]
        rates_url = f"{REST}/products/{product['code']}/electricity-tariffs/{code}/standard-unit-rates/"
        if name == "Agile Octopus":
            # Its real prices over the same period, plus a day for a car moved past the end.
            rows = all_pages(rates_url + "?" + urllib.parse.urlencode({
                "period_from": period_start.astimezone(timezone.utc).isoformat(),
                "period_to": (period_end + timedelta(days=1)).astimezone(timezone.utc).isoformat(),
                "page_size": 1500,
            }))
            prices = {parse(r["valid_from"]): r["value_inc_vat"] for r in rows}
            fallback = statistics.median(prices.values()) if prices else 30.0

            def agile(start, prices=prices, fallback=fallback):
                return prices.get(start, fallback)

            tariffs.append(Tariff(
                name, variant["standing_charge_inc_vat"], agile,
                f"half-hourly, {min(prices.values()):.1f}p to {max(prices.values()):.1f}p over the period"
                if prices else "no prices found"))
            continue
        # Today's rates for everything else: one day's worth shows the time-of-use shape too.
        rows = rest(rates_url, period_from=tomorrow.astimezone(timezone.utc).isoformat(),
                    period_to=(tomorrow + timedelta(days=1)).astimezone(timezone.utc).isoformat())["results"]
        profile = {}
        slot, day_ends = tomorrow, local_midnight(tomorrow.date() + timedelta(days=1), tz)
        while slot < day_ends:
            for r in rows:
                begins, ends = parse(r["valid_from"]), parse(r["valid_to"])
                if begins <= slot and (ends is None or slot < ends):
                    local = slot.astimezone(tz)
                    profile[f"{local:%H}:{local:%M}"] = r["value_inc_vat"]
                    break
            slot += timedelta(minutes=30)
        rates = sorted(set(profile.values()))
        if not rates:
            notes.append(f"{name}: no current unit rate published")
            continue
        if len(rates) == 1:
            tariffs.append(Tariff(name, variant["standing_charge_inc_vat"], flat(rates[0]), f"{rates[0]:.2f}p"))
        else:
            cheap = sorted(k for k, v in profile.items() if v == rates[0])
            tariffs.append(Tariff(
                name, variant["standing_charge_inc_vat"], by_local_time(profile, tz),
                f"{rates[0]:.2f}p from {cheap[0]} for {len(cheap) / 2:g}h, otherwise {rates[-1]:.2f}p"))
    return tariffs, notes


def minutes(hhmm):
    parts = (hhmm or "").split(":")
    return int(parts[0]) * 60 + int(parts[1]) if len(parts) >= 2 else None


def cheap_windows(agreement):
    """The schedule's cheap windows as (from, to) minutes after local midnight."""
    windows = []
    for slot in ((agreement.get("timeOfUseScheme") or {}).get("timeslots")) or []:
        name = (slot.get("timeslot") or "").lower()
        begins, ends = minutes(slot.get("activeFrom")), minutes(slot.get("activeTo"))
        if any(word in name for word in ("off", "cheap", "night")) and begins is not None and ends is not None:
            windows.append((begins, ends))
    # Intelligent Octopus Go's fixed window, if the schedule says nothing.
    return windows or [(23 * 60 + 30, 5 * 60 + 30)]


def in_windows(start, tz, windows):
    local = start.astimezone(tz)
    now = local.hour * 60 + local.minute
    return any(b <= now < e if b < e else (now >= b or now < e) for b, e in windows)


def current_tariff(agreement, usage, tz):
    """Your tariff at today's rates, the half hours it makes cheap, and where the figures came from.

    Intelligent Octopus Go makes any smart-charge half hour cheap for the whole house, so its
    pattern can't be rebuilt from a clock. Where Octopus priced a half hour, the pattern is taken
    from what you were billed. Where it didn't — the usage data only carries costs for recent
    months — it is rebuilt from the rule: the schedule's cheap window, plus any half hour the car
    was charging.
    """
    tariff = agreement.get("tariff") or {}
    name = tariff.get("displayName") or "Current tariff"
    smart = "intelligent" in name.lower()
    windows = cheap_windows(agreement)

    priced = [r for r in usage if r["pence"] > 0 and r["kwh"] >= 0.05]
    per_kwh = [r["pence"] / r["kwh"] for r in priced]
    threshold = None
    if per_kwh and max(per_kwh) - min(per_kwh) >= 1:
        threshold = (min(per_kwh) + max(per_kwh)) / 2

    stated = [to_float(tariff.get(k)) for k in
              ("unitRate", "dayRate", "nightRate", "offPeakRate", "evDevicePeakRate", "evDeviceOffPeakRate")]
    stated = [r for r in stated if r]
    if stated:
        low, high, source = min(stated), max(stated), "rates from your agreement"
    elif per_kwh:
        # The agreement didn't state its rates, so take them from the last month you were billed.
        recent_from = priced[-1]["start"] - timedelta(days=30)
        recent = [r["pence"] / r["kwh"] for r in priced if r["start"] >= recent_from]
        below = [x for x in recent if threshold is None or x < threshold]
        above = [x for x in recent if threshold is not None and x >= threshold]
        low = statistics.median(below or recent)
        high = statistics.median(above) if above else low
        source = f"rates from your last month of billing ({tariff.get('__typename') or 'tariff'} states none)"
    else:
        return None, set(), "your tariff states no rates and your usage carries no costs to take them from"

    standing = to_float(tariff.get("standingCharge"))
    if standing is None:
        by_day = {}
        for r in usage:
            by_day[r["start"].astimezone(tz).date()] = by_day.get(r["start"].astimezone(tz).date(), 0) + r["standing"]
        billed_days = [v for v in by_day.values() if v > 0]
        standing = billed_days[-1] if billed_days else 0.0

    cheap = set()
    rebuilt = 0
    for r in usage:
        if r["pence"] > 0 and r["kwh"] >= 0.01 and threshold is not None:
            if r["pence"] / r["kwh"] < threshold:
                cheap.add(r["start"])
        else:
            rebuilt += 1
            if in_windows(r["start"], tz, windows) or (smart and r["car"] > 0):
                cheap.add(r["start"])
    if rebuilt:
        source += f"; cheap half hours rebuilt from the tariff's rules for {rebuilt:,} unpriced half hours"
    summary = f"{low:.2f}p / {high:.2f}p" if high > low else f"{low:.2f}p"
    return Tariff(f"{name} (today's rates)", standing,
                  lambda start: low if start in cheap else high, summary), cheap, source


# ---------------------------------------------------------------------------------------------
# Pricing


def plug_in_windows(first, last, tz, window):
    """Every plug-in window from before `first` to after `last`, as (start, end) in UTC."""
    (sh, sm), (eh, em) = window
    day = first.astimezone(tz).date() - timedelta(days=1)
    windows = []
    while True:
        begins = local_midnight(day, tz) + timedelta(hours=sh, minutes=sm)
        ends_day = day + timedelta(days=1) if (eh, em) <= (sh, sm) else day
        ends = local_midnight(ends_day, tz) + timedelta(hours=eh, minutes=em)
        windows.append((begins.astimezone(timezone.utc), ends.astimezone(timezone.utc)))
        if begins > last:
            return windows
        day += timedelta(days=1)


def price_usage(usage, tariff, tz, charger_kw, window):
    """Total pence for units and standing, and the car kWh that didn't fit its window.

    The house stays where it was. The car's energy is gathered per plug-in window — anything used
    before a window ends belongs to it — and recharged in that window's cheapest half hours, at most
    `charger_kw` × ½ h each. Whatever doesn't fit is priced where it originally happened.
    """
    units = sum(row["house"] * tariff.price(row["start"]) for row in usage)
    windows = plug_in_windows(usage[0]["start"], usage[-1]["start"], tz, window)
    need = [0.0] * len(windows)
    stranded = []
    index = 0
    for row in usage:
        if not row["car"]:
            continue
        while index < len(windows) and windows[index][1] <= row["start"]:
            index += 1
        if index < len(windows):
            need[index] += row["car"]
        else:
            stranded.append(row)
    per_slot = charger_kw / 2
    overflow = 0.0
    for (begins, ends), energy in zip(windows, need):
        if energy <= 0:
            continue
        slots = []
        slot = begins
        while slot < ends:
            slots.append(slot)
            slot += timedelta(minutes=30)
        for slot in sorted(slots, key=tariff.price):
            if energy <= 0:
                break
            taken = min(per_slot, energy)
            units += taken * tariff.price(slot)
            energy -= taken
        if energy > 0:
            # More than the window can deliver: charged at the window's dearest price, which is
            # roughly what topping up at another time would cost.
            units += energy * max(tariff.price(s) for s in slots)
            overflow += energy
    for row in stranded:
        units += row["car"] * tariff.price(row["start"])
    days = len({row["start"].astimezone(tz).date() for row in usage})
    return units, tariff.standing * days, overflow


# ---------------------------------------------------------------------------------------------


def parse_window(text):
    try:
        begins, ends = text.split("-")
        return tuple(tuple(int(part) for part in end.split(":")) for end in (begins, ends))
    except ValueError:
        sys.exit(f"--plugged-in wants HH:MM-HH:MM, not {text!r}")


def main():
    parser = argparse.ArgumentParser(description="Price a year of your electricity on other Octopus tariffs.")
    parser.add_argument("--days", type=int, default=365)
    parser.add_argument("--mpan")
    parser.add_argument("--charger-kw", type=float, default=7.0)
    parser.add_argument("--plugged-in", default="18:00-07:00")
    parser.add_argument("--iog-fixed")
    parser.add_argument("--cache")
    parser.add_argument("--refresh", action="store_true")
    args = parser.parse_args()
    window = parse_window(args.plugged_in)

    key = os.environ.get("OCTOPUS_API_KEY")
    if not key:
        sys.exit("Set OCTOPUS_API_KEY in your environment.")
    try:
        token = gql("mutation($k:String!){obtainKrakenToken(input:{APIKey:$k}){token}}", {"k": key})
        token = token["obtainKrakenToken"]["token"]
        account = gql("{viewer{accounts{number}}}", token=token)["viewer"]["accounts"][0]["number"]
        details = gql(ACCOUNT_QUERY, {"a": account}, token)["account"]
    except RuntimeError as exc:
        sys.exit(f"GraphQL error: {exc}")

    # Each property paired with its own meters, so a meter is never priced at another address.
    active = {(a.get("meterPoint") or {}).get("mpan"): a for a in details.get("electricityAgreements") or []}
    meters = [
        {"property": prop["id"], "address": (prop.get("address") or "").split("\n")[0].split(",")[0],
         "mpan": point["mpan"], "agreement": active[point["mpan"]]}
        for prop in details.get("properties") or []
        for point in prop.get("electricityMeterPoints") or []
        if str(point.get("direction")).upper() != "EXPORT" and point.get("mpan") in active
    ]
    if args.mpan:
        meters = [m for m in meters if m["mpan"] == args.mpan]
    if not meters:
        sys.exit("No matching electricity import meter with an active agreement.")
    if len(meters) > 1:
        print("Several import meters; pricing the first. Use --mpan to choose another:", file=sys.stderr)
        for m in meters:
            print(f"  {m['mpan']}  {m['address']}", file=sys.stderr)
    meter = meters[0]
    region = REGIONS.get(meter["mpan"][:2])
    if not region:
        sys.exit(f"Can't tell the region from MPAN {meter['mpan']}.")
    tz = ZoneInfo((meter["agreement"].get("timeOfUseScheme") or {}).get("timezone") or "Europe/London")

    cache = args.cache or os.path.expanduser(f"~/.cache/octopus_compare/{meter['mpan']}.json")
    usage = load_usage(token, meter["property"], meter["mpan"], tz, args.days, cache, args.refresh)
    if not usage:
        sys.exit("No half-hourly usage came back.")
    usage = split_car(usage, tz)
    days = len({row["start"].astimezone(tz).date() for row in usage})
    first, last = usage[0]["start"], usage[-1]["start"]

    tariffs, notes = published_tariffs(region, tz, first, last + timedelta(minutes=30))
    current, cheap_slots, current_source = current_tariff(meter["agreement"], usage, tz)
    if current:
        tariffs.insert(0, current)
    else:
        notes.append(f"Current tariff left out: {current_source}")
    if args.iog_fixed:
        try:
            cheap, peak, standing = (float(x) for x in args.iog_fixed.split(","))
        except ValueError:
            sys.exit("--iog-fixed wants CHEAP,PEAK,STANDING in pence, e.g. 7.5,29.9,48.0")
        # The same cheap half hours you actually got on Intelligent Octopus Go, at the fixed rates.
        fixed = Tariff(
            "Intelligent Octopus Go 12M Fixed", standing,
            lambda start: cheap if start in cheap_slots else peak,
            f"{cheap:.2f}p / {peak:.2f}p (your figures)")
        fixed.keeps_car = True
        tariffs.append(fixed)

    total_kwh = sum(r["kwh"] for r in usage)
    car_kwh = sum(r["car"] for r in usage)
    # Octopus's usage data only carries costs for recent months, so the billed total covers just
    # the days it priced — not comparable with a year, and labelled with the days it does cover.
    billed_days = sorted({r["start"].astimezone(tz).date() for r in usage if r["pence"] > 0})
    billed = sum(r["pence"] + r["standing"] for r in usage
                 if r["start"].astimezone(tz).date() in set(billed_days))
    scale = 365 / days

    print(f"MPAN {meter['mpan']} · {meter['address']} · region {region}")
    print(f"{days} days, {first.astimezone(tz):%d %b %Y} to {last.astimezone(tz):%d %b %Y} · "
          f"{total_kwh:,.0f} kWh, of which about {car_kwh:,.0f} kWh was the car")
    print(f"Car recharged in the cheapest half hours of {args.plugged_in} at up to {args.charger_kw:g} kW.\n")

    results = []
    for tariff in tariffs:
        # Your own tariff keeps the car where it was: that is what the cheap half hours describe.
        if tariff is current or tariff.keeps_car:
            units = sum(r["kwh"] * tariff.price(r["start"]) for r in usage)
            standing, overflow = tariff.standing * days, 0.0
        else:
            units, standing, overflow = price_usage(usage, tariff, tz, args.charger_kw, window)
        results.append((units + standing, units, standing, overflow, tariff))
    baseline = results[0][0] if current else None

    print(f"  {'Tariff':<46} {'Period':>9} {'Per year':>10} {'vs yours':>10}")
    if billed_days and len(billed_days) >= days:
        print(f"  {'What you were billed':<46} {'£' + format(billed / 100, ',.2f'):>9} "
              f"{'£' + format(billed / 100 * scale, ',.0f'):>10}")
    for total, units, standing, overflow, tariff in sorted(results, key=lambda r: r[0]):
        delta = "" if baseline is None or tariff is current else f"{(total - baseline) / 100 * scale:+,.0f}"
        print(f"  {tariff.name[:46]:<46} {'£' + format(total / 100, ',.2f'):>9} "
              f"{'£' + format(total / 100 * scale, ',.0f'):>10} {('£' + delta) if delta else '':>10}")
        detail = f"      {tariff.summary} · standing {tariff.standing:.2f}p/day"
        if overflow >= 0.5:
            detail += f" · {overflow:,.0f} kWh of car didn't fit the window"
        print(detail)
        if tariff is current:
            print(f"      {current_source}")
    if billed_days and len(billed_days) < days:
        print(f"\n  Octopus priced only {len(billed_days)} of these days ({billed_days[0]:%d %b} to "
              f"{billed_days[-1]:%d %b %Y}): you were billed £{billed / 100:,.2f} for those.")
    for note in notes:
        print(f"  {note}")
    print("\nPer year is the period scaled to 365 days; a short period says little about winter.")
    print("Agile is priced at its real prices over the period; the rest at today's rates.")


if __name__ == "__main__":
    main()
