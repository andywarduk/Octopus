# Working on this project

Notes for anyone — human or agent — changing the code. `README.md` covers what the app does; this
covers how it is built and what the API actually returns, including the things that are not
obvious and cost time to rediscover.

## Build and check

```bash
./build.sh                                          # compiles every .swift in the root
open build/OctopusMenuBar.app
./install.sh [destination]                          # build, then install (default /Applications)
```

`install.sh` resolves its destination before doing anything destructive — `./install.sh /` is
refused — quits a running copy so the bundle is not swapped underneath it, and replaces rather
than copies over, since a file left by an older build would still be inside the bundle and still
be loaded. A failure to launch at the end is reported but does not fail the install.

`build.sh` compiles the whole root directory into one binary, renders the app icon into
`AppIcon.icns`, and ad-hoc signs the bundle. If `iconutil` fails the build still succeeds and
notifications fall back to a generic icon.

Three flags check the app without launching it or touching the network:

```bash
build/OctopusMenuBar.app/Contents/MacOS/OctopusMenuBar --selftest        # logic, from fixed data
build/OctopusMenuBar.app/Contents/MacOS/OctopusMenuBar --chartdemo DIR   # chart PNGs, both themes
build/OctopusMenuBar.app/Contents/MacOS/OctopusMenuBar --iconset DIR     # icon PNGs
```

**Run `--selftest` after any change to the logic, and `--chartdemo` after any change to the
chart, then look at the PNGs.** The chart has repeatedly been broken in ways only visible in the
rendered output. The sample week is seeded, so the images are identical run to run and a diff is
meaningful.

`--chartdemo` renders the carbon chart as `carbon-*.png` alongside the usage ones. Its `now` rule
is fixed rather than read from the clock, or the images differ run to run and a diff means nothing.

`--chartdemo` also counts antialiased seams between half-hourly bars — pixels that are neither the
surface nor a band colour. A handful is expected, at the edges of the deliberate no-readings gap
in the sample; it reports 9 at the time of writing. Tens or hundreds means adjacent bars no longer
meet on the pixel grid. Compare against the previous build rather than against a fixed number,
since changing the sample week moves it.

That check is tied to the plot's bottom inset via `plotBottomInset`, and it has silently measured
the wrong rows before when the inset changed. It also only counts blends, not plain background —
an earlier version looked for background pixels and reported zero while the seams were plainly
visible.

There is no unit-test target. `--selftest` is the test suite; extend it rather than adding one. It
currently covers charging-status wording, band assignment and thresholds (including a single-rate
tariff), both reading shapes, unpublished days, zero-usage days, week windows, cache freshness,
axis steps, agreement-end parsing and its alert thresholds, the SmartFlex charge goal, balance
wording, carbon parsing and its plausibility screening, login-item wording, and the menu text at
three moments.

### Verifying UI changes without a display

The chart is drawn by hand, so most of its bugs are invisible to the compiler and to logic tests.
`renderUsageChart` draws a `UsageChartView` into a bitmap offscreen, which is how the PNGs are
produced; `previewHover` forces the hover state so tooltips can be rendered too. Use the same
approach for any new drawing. Several real bugs — a tooltip covering its own column's label, a cap
label colliding with the legend, hairlines between bars — were only found by looking at the output.

Where an eye is unreliable, measure instead. The seam counter reads pixels back out of the bitmap
rather than trusting a judgement about a one-pixel line; an alpha value that looked too heavy was
settled by rendering it at a much lower value and confirming the difference.

## Source layout

| File | Contents |
| --- | --- |
| `Model.swift` | `Interval`, `Car`, `Snapshot`, `Line` |
| `RateLogic.swift` | Pure functions over a `Snapshot`: cheap windows, fetch interval, menu text |
| `Keychain.swift` | Reading, saving and removing the API key |
| `MeterSelection.swift` | Fuels, discovering meters per property, saved choice per fuel |
| `OctopusAPI.swift` | GraphQL transport and the calls that build a `Snapshot` |
| `Usage.swift` | Usage model, banding, aggregation, the measurements query and fetch |
| `UsageChart.swift` | The stacked column chart, its palette, and the offscreen renderer |
| `UsageWindowController.swift` | One usage window; one instance per fuel |
| `CarbonIntensity.swift` | Carbon intensity model and both sources' fetch and parsing |
| `CarbonChart.swift` | The carbon intensity chart, its sequential ramp, and its renderer |
| `CarbonWindowController.swift` | The carbon intensity window |
| `AppIcon.swift` | The app icon, drawn in code |
| `LoginItem.swift` | Start-at-login, via SMAppService |
| `AppDelegate.swift` | Status item, the 30-second tick, the refresh cycle |
| `AppDelegate+Menu.swift` | Icon state and menu building |
| `AppDelegate+Notifications.swift` | "Cheap rate soon" alerts |
| `AppDelegate+Settings.swift` | The Settings window and meter pickers |
| `SelfTest.swift` | `--selftest` output |
| `main.swift` | Entry point and command-line flags |

`octopus_rate.py`, `octopus_history.py` and `octopus_carbon.py` are standalone; standard library
only, Python 3.9+. `octopus_carbon.py` needs no API key unless asked for the Octopus source or
for the account's postcode, since both of the sources behind it are keyless.
They duplicate the auth and meter-selection logic rather than sharing it.

## The API

Endpoint `https://api.octopus.energy/v1/graphql/`. Exchange the API key for a token with
`obtainKrakenToken`, then send the token in the `Authorization` header — no `Bearer` prefix.

**Introspection works without logging in.** That is the fastest way to check a field exists:

```bash
curl -s -X POST https://api.octopus.energy/v1/graphql/ -H 'Content-Type: application/json' \
  -d '{"query":"{__schema{types{name}}}"}'
```

Dump the whole schema to explore it offline:

```bash
curl -s -X POST https://api.octopus.energy/v1/graphql/ -H 'Content-Type: application/json' \
  -d '{"query":"query{__schema{types{name kind fields{name args{name} type{name kind ofType{name}}}}}}"}' \
  > schema.json
```

It is large — around 1,600 object types, most of them Kraken's own back-office tooling rather than
anything a customer key can reach.

Sending a query unauthenticated also validates it — if the only error is the missing
`Authorization` header, the field names and argument types are correct. Use that before wiring a
query into the app.

### Things the API does that will mislead you

These were all found the hard way; each one produced a plausible-looking wrong answer first.

- **`applicableRates` returns rate bands, not a schedule.** The `validFrom`/`validTo` on each band
  are clipped to your query window, so they say nothing about when a band applies. Use the lowest
  and highest values as the two prices, and take the timing from the agreement's `timeOfUseScheme`.
- **It needs a page size.** Without `first:` it errors with "Pagination parameters not provided".
- **Every interval lists every tariff bucket.** Only the ones with energy against them were
  charged. Reading the first bucket and stopping gives you a constant, wrong price. Sum the ones
  with energy.
- **Amounts are in pence** despite `costCurrency` saying GBP. Confirmed arithmetically:
  0.767 kWh × 6.89997p = 5.29228, which matches `estimatedAmount` exactly.
- **`applicableRates` excludes VAT; `costInclTax` includes it.** Nothing in either name says so.
  28.9251 × 1.05 = 30.37136 and 6.5714 × 1.05 = 6.89997, both matching the measurements exactly.
  Mixing the two put an ex-VAT price in the menu bar and an inc-VAT one in the chart for the same
  electricity. **Everything shown to the user now includes VAT.** Prefer the agreement's
  `tariff` rates, which include VAT and come named (`dayRate`, `evDeviceOffPeakRate`, …) alongside
  `preVat…` siblings and a `standingCharge`; `applicableRates` is the fallback for tariffs with no
  fixed rates, such as Agile, and is grossed up by `vatMultiplier`.
- **The per-device buckets are a billing allocation, not a measurement.** On Intelligent Octopus,
  `EV_DEVICE_OFF_PEAK` is a fixed slice (2.611 kWh per half hour on the account this was built
  against) and the rest of the car's draw lands in the household bucket at the same price. Do not
  present this split as car versus house — it makes a 7 kW charge look like 5.2 kW and implies
  household use that is not real. Compare a charging interval against a non-charging night's
  baseline to see it.
- **Gas and electricity put the energy in different places.** Electricity puts kWh on each tariff
  bucket's `value`. Gas leaves that null and puts the total on the reading's own `value`. Only
  fall back to the reading when exactly one consumption bucket exists, or each bucket will claim
  the whole interval.
- **`costOfUsage` may be disabled** (`costEnabled: false`) on an account. `property.measurements`
  is the reliable route.
- **Gas `deviceId` filtering returns "Unauthorized"**; filter by MPRN via `marketSupplyPointId`.
- **Octoplus is not reachable with a customer API key.** `octoplusAccountInfo` answers — it
  reported `ENROLLED` and `isLoyaltyPointsUser: true` — but `loyaltyPointsBalance` and
  `loyaltyPointLedgers` both return "Unauthorized", and `octoplusFeatureFlags` answers `true` to
  everything without any auth at all, so neither is evidence the data is available. There is also
  **no Saving Sessions, Free Electricity or Wheel of Fortune anywhere in the schema** — those are
  app-only and live behind different auth. Do not plan features around them.
- **`smartMeterTelemetry` needs a Home Mini, not just a smart meter.** It offers `demand` in
  watts, `consumptionDelta` in Wh and `costDeltaWithTax` in pence, grouped from `TEN_SECONDS` to
  `HOURLY` — but keyed on a CAD being paired to the home area network. On an account without one
  it returns **no rows and no error** at every grouping, over at least eight days, which reads
  exactly like a wrong query. Check `smartDeviceNetwork(deviceId:)` first: it lists the HAN, and
  if that shows only ESME/GSME/PPMID/CHF/GPF there is no Home Mini and telemetry will never
  return anything. The development account has none, so this whole area is unexercised.
- **`smartDevices` is a list**, though introspection's `ofType` chain reports it as a single
  `SmartMeterDeviceType` unless you keep the `LIST` kind while unwrapping.
- **`SmartFlexVehicle.chargePointPowerOutput` gives the charger's rating directly** (7.000 on the
  development account), alongside `vehicleBatterySize`. Use it rather than inferring a charge rate
  from consumption — inferring it is what produced the wrong 5.2 kW figure.
- **`SmartFlexVehicleChargingPreferences` is declared but implemented by nothing.** The live type
  behind `SmartFlexVehicle.preferences` is `SmartFlexDevicePreferences`: `targetType`, `unit`,
  `mode` and a `schedules` array of `{dayOfWeek, time, min, max, upperLimit}`. Times are local, so
  a 07:00 ready-by shows as an 06:00Z session end in summer. Check `unit` before printing a
  percentage — the same field can hold a kWh or mileage goal.
- **Introspection hides deprecated fields.** `SmartFlexVehicle.chargingPreferences` is absent from
  a plain `__type(...){fields{name}}` yet still answers queries; it is deprecated in favour of
  `preferences`. Pass `fields(includeDeprecated:true)` before concluding a field the code already
  uses has been removed.
- **An outward code is not a postcode with three characters lopped off.** `outwardCode`/
  `outward_code` only strip the inward part from something long enough to have one: `"SN13"` given
  on its own is already the answer, and dropping three characters leaves `"S"`, which both APIs
  reject with a 400. This bit the Python script the first time it ran.
- **An agreement's `validTo` is the instant cover stops, not its last day.** These end at
  midnight, so the raw date is the first day of the *next* tariff and quoting it puts the end a
  day late. `lastCoveredDay` steps back a second.
- **Carbon intensity has two sources and they are not interchangeable.**
  `getProjectedRegionalCarbonIntensity(postcode:)` works with a customer key and returns 48
  half-hourly rows — but only `periodStart`, so each period's end is the next row's start, and the
  rows must be sorted before that can be worked out. It is *projected* only, so it cannot be laid
  over past usage. National Grid's free API (`api.carbonintensity.org.uk`, no key) serves 48 hours
  forward, arbitrary history and the generation mix, and matched Octopus within 2 gCO₂.
- **National Grid's regional history is not capped at 48 hours.** A seven-day range returns all
  the half hours in one request, so a week costs one call. It returns **337**, not 336: the reply
  includes the period *ending* at the requested start, so a week asked for from local midnight
  arrives with the previous day's 23:30–00:00 half hour attached. The reply is trimmed back to
  the window it asked for, or that bar sits outside the range the window's own label claims. Regional rows carry only `forecast`,
  never `actual`, even for the past — do not treat a past week as measured.
- **National Grid stamps times without seconds** (`2026-09-22T17:30Z`), which
  `ISO8601DateFormatter` rejects under `.withInternetDateTime` — every row parses to nil and the
  series looks empty rather than broken. `parseCarbonDate` handles both. Its forward endpoint
  returns `data` as an object while the current-period one returns an array of them, and past
  periods carry `actual` alongside `forecast`.
- **`getSolarGenerationEstimate` returns an internal error** (KT-CT-7899) on the development
  account, most likely because there is no solar on it. Untested, treat as unavailable.
- **`chargingSessions.energyAdded` is sometimes impossible.** Four of five sessions matched
  `stateOfChargeChange` × `vehicleBatterySize` to within charging losses; the fifth reported
  76.35 kWh for a 20% change on a 49.2 kWh battery, which also exceeds what 7 kW could deliver in
  the session's 8.6 hours. `cost` was null on every row. If this is ever used, validate each row
  against ΔSoC × battery size and discard the ones that fail.
- **`DAILY` and `INTERVALIZED` are rejected** as aggregation intervals. `THIRTY_MIN_INTERVAL`,
  `HOUR_INTERVAL`, `DAY_INTERVAL`, `WEEK_INTERVAL`, `MONTH_INTERVAL` and `POINT_IN_TIME` work.
  `POINT_IN_TIME` returns the cumulative meter register, not consumption.
- **Readings lag by roughly two days.** The current week always has a blank tail. Distinguish
  "not published" from "used nothing": both look like zero, and only the first should be a gap.
- **Zero usage is data.** A meter reporting all zeros still returns readings and standing charges.
  Decide emptiness on reading count, never on consumption, or an unused supply reports as an error.

When data is missing, probe before guessing. A throwaway script that walks every reading frequency
against every way of identifying the meter — by supply point, by device id, and unfiltered — and
prints what each returns will answer it in one run. Every gas finding above came from doing that,
after two wrong guesses: an empty chart looked like the wrong frequency, then like the wrong
filter, and was actually a null field in a place I had not looked.

## Swift concurrency

Built in Swift 6 language mode, so the usual traps apply:

- Top-level code in `main.swift` is **not** MainActor-isolated. Creating the `AppDelegate` or
  touching a view needs `MainActor.assumeIsolated`.
- Global mutable state must be concurrency-safe. `FormatterCache` in `RateLogic.swift` is
  `@unchecked Sendable` with an `NSLock` guarding the dictionary; `DateFormatter` itself is safe to
  format from multiple threads.
- `UNUserNotificationCenterDelegate` callbacks arrive off the main actor and are marked
  `nonisolated`.

## Request budget

Octopus rate-limits by query complexity and an hourly point allowance. A usage window costs one
request per day fetched — seven per week — plus meter discovery. Two things keep that in check and
should not be undone lightly:

- Fetched weeks are cached in memory, keyed by meter and week offset. A settled week is kept
  indefinitely; one still waiting on Octopus is re-checked after 15 minutes. The current week is
  never "settled", so it always re-checks.
- **"Settled" is judged at the granularity the meter reports in**, via `UsageSeries.isComplete`.
  Judging it per day marks a part-published day as finished — today usually has an hour or two —
  so the week is cached for good and the rest of the day never appears. A daily-only meter is
  judged per day, since that is all it will ever send.
- A fetch that returns nothing throws and is not cached, so revisiting an unpublished week costs
  seven requests each time. Tolerable at the moment; a short-lived negative entry would fix it.
- Automatic refreshing stops after 10 consecutive failures.

Widening the window (a month, a year) multiplies requests linearly. Batch differently rather than
looping more days.

## The development account

Built against an account with two properties, each with an import electricity meter and a gas
meter, all on live agreements. Electricity is Intelligent Octopus Go with `ECO7_DAY`/`ECO7_NIGHT`
and `EV_DEVICE_PEAK`/`EV_DEVICE_OFF_PEAK` buckets, a 7 kW EV charger, and a Home-Mini-style device
reporting charge level. One gas meter reports real usage, the other is effectively unused and
returns all zeros — which is how the zero-usage bug was found.

Single-property, single-fuel and flat-tariff accounts are handled but have never been exercised
against real data. Treat those paths as unverified.

## Outstanding

- **The build is not portable.** `build.sh` passes no deployment target and builds for the host
  architecture only, so the app will not run on an older macOS or a different chip, despite
  `LSMinimumSystemVersion` claiming 13.0. Fix with `-target arm64-apple-macosx13.0` and
  `x86_64-apple-macosx13.0`, joined with `lipo`.
- **Ad-hoc signing re-prompts for the Keychain** on every rebuild, because the signature changes.
  Only a stable Developer ID certificate avoids it; notarization would also clear the
  unidentified-developer warning on another Mac.
- **The Python scripts duplicate** auth, meter selection and banding rather than sharing a module.
  Deliberate — they are meant to stay single-file and dependency-free — but it means a fix in the
  app does not reach them. `octopus_rate.py` was brought back into line with the app when balance,
  tariff-end and charge-goal reporting were added; it has no self-test, so its logic is only as
  good as the last time someone checked it against the Swift.
- **The usage cache is in memory only**, so a relaunch refetches. Persisting settled weeks would
  need invalidation on a tariff change.

## Design decisions worth keeping

- **Bands are prices, not devices.** The stack encodes off-peak versus standard, which is real. A
  smart charge is a marker under the axis. See the allocation note above for why.
- **Standard sits at the bottom** of the consumption bands, anchored to the baseline, so it can be
  compared day to day. Off-peak floats on top.
- **The standing charge stacks below both, in money mode only**, so a column totals what the day
  actually cost. It is neutral grey, not a categorical hue: it is not a rate, and no hue in the
  palette separates from blue in dark mode at the bottom of a stack — violet, the closest, is
  ΔE 1.9 for colourblind viewers. Grey separates by saturation instead and fails the chroma floor
  deliberately. It has no place on a kWh axis, where it would be energy never delivered.
- **The carbon chart uses a sequential ramp, not a green-to-red one.** The index is an ordinal
  scale, so it takes one hue stepped by lightness; a rainbow would be both a palette violation and
  a colourblind trap at five steps. Checked numerically rather than by eye: lightness is monotonic
  in both modes, adjacent steps differ by about 1.5:1, and the top bands clear 7:1 against their
  surface. Dark mode runs dim to bright rather than flipping the light steps, so that "more"
  stays "more ink" on a dark surface. Colour never carries it alone — all five bands are always
  in the legend, the tooltip names the band, and the bar height is the number.
- **`GridFuel`'s declaration order is the fuel-mix stack order and the palette slot order, and
  the three must stay in step.** The eight categorical slots clear their colourblind gates on the
  *adjacent* pairlist, and in a stack "adjacent" means neighbouring in that enum — so reordering
  the cases silently voids the guarantee. Validated as a nine-colour sequence (the eight slots
  plus grey for `other`): worst adjacent CVD ΔE 9.1 light, 8.4 dark, both above the 8 target.
  `other` sits at the bottom: with it on top, grey fell beside red at ΔE 6.2 in dark mode, inside
  the band that needs secondary encoding. Grey fails the chroma and lightness gates deliberately,
  as the standing charge does — it marks a residual, not a fuel. Re-run `validate_palette.js` if
  any of this moves.
- **Tooltip rows carry the swatch of the mark they describe**, drawn by the shared
  `drawTooltipBox` in `UsageChart.swift` — both charts use it, and it also owns the
  beside-not-over placement. The gutter is reserved for every row as soon as any row has a
  swatch, so the text stays in one column instead of stepping in and out. The carbon chart drops
  the index swatch in fuel-mix mode, where the bars are no longer coloured by band; the fuel
  swatches stay in both views, since those colours are that fuel's identity throughout the window.
- **The fuel-mix bar height is GB demand, and that forces the mix's geography.** Demand comes from
  Elexon (`data.elexon.co.uk/bmrs/api/v1`, keyless): `/demand/outturn` gives `initialDemandOutturn`
  for settled half hours, `/forecast/demand/day-ahead` gives `nationalDemand` ahead of now. Both
  are requested every time, because a window can straddle now and neither covers the other's half.
  Multiplying a *regional* mix by *national* demand yields a quantity that does not exist, so the
  national mix (`api.carbonintensity.org.uk/generation/{from}/{to}`) is used wherever it has been
  published. **It does forecast**, contrary to an earlier note here: a range *spanning now*
  returns the full 97 rows including the future. It is a range whose **start** is in the future
  that silently clamps to the last published half hour — which is what produced the wrong
  conclusion. The regional forecast remains the fallback, `mixIsNational` records which was used,
  and the tooltip prints per-fuel gigawatts **only** for the national basis.
  `CarbonSeries.mixBasis` is what tells the user, and it is covered by `--selftest`.
- **The carbon intensity forecast misfires at sunrise, and it is upstream.** On 23 September 2026
  the two half hours to 06:00Z carried solar at 78% and 84% of generation — 19.0 GW and 22.5 GW
  against demand of 24.3 and 26.6 GW — with an intensity of 5 and 8 gCO₂/kWh, before snapping
  back to 2.2% solar and 203 gCO₂ in the next period. Both the national and the regional series
  carried it, so it is not a parsing fault. `mixLooksImplausible` screens for it against a 16 GW
  solar ceiling (GB's record is about 14 GW from roughly 18 GW installed). Such half hours are
  **greyed, never corrected** — the number belongs to the grid operator. They are also excluded
  from the legend's averages, since one bad sunrise drags a whole window's solar figure up.
  In the mix view the bar keeps its real height, because demand is sound and only the split is
  not; in the intensity view the whole column is a faint band, because the glitch takes the
  intensity with it and plotting 8 gCO₂ would just repeat the bad number.
- **Screening runs on the Octopus source too, using national data it does not carry.** Octopus
  relays the same regional forecast — compared half hour by half hour against
  `api.carbonintensity.org.uk`, the two series match — so it inherits the same glitches while
  having no mix or demand to test them against. Demand and the national mix are therefore
  fetched for the Octopus path as well, for **screening only**: the national mix is deliberately
  not assigned to `mix`, or the fuel-mix view would switch itself on for a source that has none.
- **`cleanest` excludes suspect readings.** Without that the footer nominates the sunrise glitch —
  5 gCO₂/kWh — as the best time to use power, which is the single most actionable thing this
  window says. Covered by `--selftest`.
- **The 100 gCO₂/kWh rule is drawn over the columns, not behind them.** At half-hourly width the
  bars are a solid wall and a rule behind them is invisible for most of the chart. It appears on
  the intensity view only — it means nothing against a demand or percentage axis — and only when
  the axis actually reaches it. The threshold is Octopus's own published green/not-so-green line,
  which is why it earns a rule when an invented spike threshold would not.
- **Not every forecast oddity is screened.** The same series put 284 and 276 gCO₂ either side of
  half hours reading 52 and 51, and an isolated 197 between 51 and 49 — swings the grid cannot
  physically make. These are left alone: catching them needs a spike heuristic with a threshold
  nobody can justify from physics, and suppressing real variation is worse than showing a rough
  forecast. Say it is the operator's data rather than inventing a smoother.
- **The national demand forecast is republished every half hour, and each publication is its own
  block.** Usually an intraday update covering the rest of today; once a day, the day-ahead issue
  covering tomorrow. Two things follow, both of which cost a wrong fix first:
  - `/forecast/demand/day-ahead` returns **only the newest publication** and *ignores from/to when
    selecting it* — asked for tomorrow's range at 08:24 it still returned today's rows. Coverage
    of the same window swung from 88 slots to 40 within half an hour as an intraday update
    replaced the day-ahead one.
  - **Walking back one publication at a time does not work.** By mid-morning the day-ahead issue
    is already several intraday updates back, and by evening dozens; a four-call walk-back stalled
    at 38 of 96 slots because every step found another update covering only today.

  What does work: take the newest publication, then **ask** which publication covers the first
  half hour still missing. `/forecast/demand/day-ahead/evolution?settlementDate=&settlementPeriod=`
  names it, and `/history?publishTime=` then fetches that whole block — two calls per block, no
  guessing at publication times. Measured live: 85 of 95 forecast slots, the remainder genuinely
  past the horizon. The search starts at the half hour *after* now, since the one in progress is
  structural and hunting for it wastes a round. Settled outturn is loaded first and never
  overwritten, and the forecast calls are skipped for a window ending in the past.
- **The half hour in progress has no demand, and that is structural.** Elexon publishes a
  period's settled INDO *when the period ends* (19:30Z was published at 20:00Z), and the
  day-ahead forecast drops a period once it has started — so for up to thirty minutes the current
  half hour is covered by neither and then fills itself in. `DemandGap` separates that from
  running off the end of the forecast; they must not be worded the same way, and `--selftest`
  pins the classification down. Do not "fix" the gap by interpolating or by borrowing the
  5-minutely system demand from `/demand/outturn/summary`: that series is transmission demand,
  several GW above national demand, and splicing it in would put a step in one bar.
- **Demand is a garnish, not a dependency.** No demand call throws: a failure leaves the bars
  unscaled and the view falls back to percentages, rather than losing the whole window. Bars are
  only scaled when at least half the window has demand, or the edge of the forecast would leave
  most of a chart as gaps. That rule is `carbonScaledToDemand`, used by **both** the chart and the
  footer — they were separate, and the footer announced "bars are GB demand" while the chart,
  short of data, had quietly fallen back to percentages.
- **The mix stack is normalised to each column's own total.** The shares are rounded at source and
  can add to 100.1, which draws a sliver above a fixed 100% axis and reads as a bug.
- **The chart palette is validated**, not chosen by eye. Off-peak green `#1baf7a` / `#199e70`,
  standard blue `#2a78d6` / `#3987e5` (light/dark), smart-charge marker orange `#eb6834` /
  `#d95926`. These pass colourblind and contrast checks in both modes. Green is below 3:1 on the
  light surface, which is why the legend carries totals and columns are labelled — do not remove
  those without re-checking the palette.
- **Dark mode uses its own steps**, not an automatic flip.
- **Axis steps are chosen before the maximum.** Picking the maximum and quartering it gives ticks
  like 1.25 / 2.5 / 3.75. `axisScale` picks a round step from 1, 2, 2.5, 5 × a power of ten and
  takes the finest needing six lines or fewer.
- **Half-hourly bars snap both edges to the device pixel grid**, via `snapToPixel`. Rounding only
  the origin leaves a sub-pixel sliver that renders as a hairline between bars — 396 of them
  before this was fixed. Snapping to whole *points* fixes the hairlines but makes bars alternate
  1pt and 2pt, a visible 2:1 thickness difference, because a point is two device pixels on
  Retina. At 336 bars in 538pt the widths go from {1.0: 134, 2.0: 202} to {1.5: 268, 2.0: 68}.
  Some variation is unavoidable while bars are ~1.6pt wide; it shrinks as the window widens.
  Note `--chartdemo` renders at 1x, where snapping to points and to pixels are the same, so the
  PNGs show the worst case rather than what a Retina screen shows.
- **The menu is rebuilt only in `menuNeedsUpdate`**, which runs before display. Rebuilding an open
  menu makes it flicker or close, and anything fetched while it is open shows next time it opens.
- **Menu order is current rate, upcoming cheap rate, cars, account, footer**, then the action
  items: Electricity Use…, Gas Use…, Refresh Now, Settings…, Quit. The informational sections come
  from `menuLines`, which `--selftest` prints at three moments; the action items are built in
  `rebuildMenu` and are not covered by any test, so check those in the running app.
  A single-rate tariff skips the upcoming-cheap section rather than showing it empty — that used
  to be an early return, which forced the section to be last, and is now an `if` so the order is
  free to change.
- **`octopus_rate.py` mirrors the same order** and the same agreement and charge-goal rules. It
  shares no code with the app, so a change to one is a change to make twice.
- **Balance and agreement dates ride on the tariff request.** Both hang off the same `account`
  node, so folding them into the existing query costs no extra request. Do not split them out.
- **Tariff-end alerts fire once per threshold** (30, 14, 7, 1 days), with the tightest threshold
  reached recorded per agreement in `UserDefaults` so a relaunch doesn't repeat them. Alerting
  daily for two months would train you to ignore it. The record is pruned only when a fetch
  actually returned agreements, since an empty list after a failure would wipe it and re-alert
  everything.
- **The rate-change alert fires in both directions** and is keyed to the *boundary* it is about,
  not to when it last fired. A plain cooldown got this wrong twice over: it re-alerted for the
  same switch when Octopus nudged a dispatch by a minute, and on a dispatch shorter than the
  cooldown it silenced the end because the start had just been announced. `nextRateChange` is the
  rule, and `--selftest` walks it through a window, a dispatch and the gaps between them.
  Smart-charge dispatches are merged into the cheap windows, so a dispatch triggers it too, and a
  merged run of back-to-back slots yields one change rather than one per slot.
- **Dispatch alerts match slots within a five-minute tolerance** rather than comparing lists.
  Octopus re-plans by a minute or two on almost every fetch, so an exact comparison alerts several
  times an hour. Only future dispatches count; completed ones are history and churn. A ten-minute
  cooldown covers a plan that flaps between two shapes, and the first fetch after launch never
  alerts because there is nothing to compare against.
- **Automatic refreshing stops after 10 consecutive failures** until "Refresh Now". Without this a
  bad key retries every 30 seconds indefinitely.
- **Meters are discovered as matched pairs.** Taking the first property and the first agreement
  independently pairs a property with another address's meter on a multi-property account.
- **VAT-inclusive prices everywhere**, because that is what the bill says. The menu bar states it
  once in its footer rather than suffixing every number.
- **Start at login uses `SMAppService.mainApp`**, not a launch agent plist: it registers the
  bundle, so deleting the app removes it and macOS lists it under Login Items where the user's
  choice overrides the app's. The checkbox reads its state from `SMAppService` every time Settings
  opens rather than from `UserDefaults`, because the user can turn it off in System Settings and a
  stored preference would then lie. `.requiresApproval` counts as on — the user asked, macOS is
  the one hesitating — and `.notFound` is what you get running from `build/`.
- **Title case** for menu items, buttons and segmented controls, per Apple's HIG. Sentence case
  for descriptive labels and checkbox sentences.

## Conventions

- Comments explain *why*, not what. Several comments in this code record an API quirk or a bug
  that was fixed — keep those; they are the reason the code looks the way it does.
- The API key lives only in the Keychain. Never log it, write it to a file, or put it in a query
  string.
- Keychain writes are checked and surfaced in the UI. A silent failure means the key is gone on
  next launch.
- Prefer widening `--selftest` over adding assertions in the app.
