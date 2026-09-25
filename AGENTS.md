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

`build.sh` compiles the whole root directory into one binary, as a whole module so the optimiser
sees across files, renders the app icon into
`AppIcon.icns`, and ad-hoc signs the bundle. If `iconutil` fails the build still succeeds and
notifications fall back to a generic icon.

Three flags check the app without launching it or touching the network:

```bash
build/OctopusMenuBar.app/Contents/MacOS/OctopusMenuBar --selftest        # logic, from fixed data
build/OctopusMenuBar.app/Contents/MacOS/OctopusMenuBar --chartdemo DIR   # chart PNGs, both themes
build/OctopusMenuBar.app/Contents/MacOS/OctopusMenuBar --iconset DIR     # icon PNGs
```

**Run `./selftest.sh` after any change to the logic, and `--chartdemo` after any change to the
chart, then look at the PNGs.** `--selftest` only prints; `selftest.sh` diffs that output against
the committed `SelfTest.expected` and fails on any difference. When a change is intended, read the
diff, then accept it with `./selftest.sh --update` and commit the new expected output alongside the
code. The output is fixed-date and timezone-independent, so a diff always means something changed. The chart has repeatedly been broken in ways only visible in the
rendered output. The sample week is seeded, so the images are identical run to run and a diff is
meaningful.

`--chartdemo` and `--iconset` create their output directory if it is missing; they used to write
nothing into one that didn't exist, without saying so, which reads as every image having changed.

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

There is no unit-test target. `--selftest` is the test suite; extend it rather than adding one, and
keep its output free of the clock — a stray `Date()` in anything printed makes `SelfTest.expected`
go stale overnight. It currently covers charging-status wording, band assignment and thresholds (including a single-rate
tariff), both reading shapes, unpublished days, zero-usage days, week windows, cache freshness,
axis steps, agreement-end parsing and its alert thresholds, the SmartFlex charge goal, balance
wording, carbon parsing, cleanest and the mean mix, the mix basis wording and mean mix, the
dispatch alert cooldown, a failed device query, the refresh split and its queries, page sizes and completeness across a clock change,
tariff-end wording, login-item wording, and the menu text at three moments.

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
| `OctopusAPI.swift` | GraphQL transport, the shared session cache, and the tariff and device halves of a `Snapshot` |
| `Usage.swift` | Usage model, banding, aggregation, the measurements query and fetch |
| `UsageChart.swift` | The stacked column chart, its palette, and the offscreen renderer |
| `UsageWindowController.swift` | One usage window; one instance per meter |
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
| `SelfTest.expected`, `selftest.sh` | The accepted `--selftest` output, and the script that diffs against it |
| `main.swift` | Entry point and command-line flags |

`octopus_rate.py`, `octopus_history.py`, `octopus_carbon.py` and `octopus_compare.py` are standalone; standard library
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
  `tariff` rates where they exist: the fixed-rate types (`StandardTariff`, `DayNightTariff`,
  `FourRateEvTariff`, …) name them (`dayRate`, `evDeviceOffPeakRate`, …) including VAT, alongside
  `preVat…` siblings and a `standingCharge`. `applicableRates` is the fallback, grossed up by
  `vatMultiplier`.
- **Intelligent Octopus Go is a `HalfHourlyTariff`, not a `FourRateEvTariff`.** On the development
  account the agreement's tariff arrives as `HalfHourlyTariff`, which has no named rates — only
  `standingCharge`, `preVatStandingCharge` and a `unitRates` list whose contents have not been
  inspected. So the app's prices for that tariff come from the `applicableRates` fallback, and
  for a long time the standing charge came from nowhere: the query didn't ask this type for it,
  and the menu's footnote silently dropped it. The query now takes `standingCharge` from it. The
  earlier claim here that the agreement's rates "come named" held only for the fixed-rate types.
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
- **`plannedDispatches` is deprecated, and gave only start and end.** `flexPlannedDispatches`
  also carries `energyAddedKwh` and `type` (`SMART` / `BOOST` / `TEST`), but it is keyed by
  **device**, so the device list has to be fetched before it — one alias per device keeps it to a
  single request however many there are. `completedDispatches` stays keyed by account and gains
  `delta` (kWh, import negative) and `meta.location`. Like `chargingPreferences`, the deprecation
  is invisible without `fields(includeDeprecated:true)`.
- **The charge held in the battery is derived, not reported.** `SmartFlexVehicle` gives
  `vehicleBatterySize` (usable capacity) and the status gives a state of charge, and the app
  multiplies them. Shown as "about" because the percentage arrives rounded and one percent of a
  49 kWh battery is half a kilowatt-hour. A car that reports no capacity simply omits the line.
- **`energyAddedKwh` is the planner's arithmetic, not a measurement.** On the development account
  a plan of 18.277 kWh over seven half hours is *exactly* 7 × 2.611 — the same constant as the
  `EV_DEVICE_OFF_PEAK` billing allocation, which is 5.222 kW flat. The last slot is a partial
  top-up to the target state of charge. So it is fine for "about N kWh planned" and must never be
  charted as what the car drew; that is the same trap the per-device buckets set.
  `completedDispatches.delta` looks different in kind — 2.65 kWh against the allocation's 2.611,
  and trickle values of 0.04–0.07 kWh that no allocation would produce — but only four rows came
  back, all from the same day, so there is no history to plot even if it is sound.
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
- **A local day is not always 48 half hours.** The measurements query pages by `first:`, and the
  day the clocks go back has 50. Asking for 48 cut off the last hour, which then read as "not
  published yet" forever and kept the week from ever counting as settled. `halfHours(from:to:)`
  sizes each day's request; the spring day has 46.
- **Published costs are not final.** A half hour on 23 September 2026 — the car drawing 3.72 kWh at
  15:30 during an Intelligent Octopus Go session — was published at the standard rate with no
  `EV_DEVICE` bucket, and about two days later came back reclassified as a smart charge at the
  off-peak rate. So a day whose readings are all in is not a day whose costs are settled, and
  `completedDispatches` can't be used to check, since it keeps only about a day. The usage window
  counts a week settled only once it ended over a week before it was fetched (`CachedUsage.settled`),
  and `octopus_compare.py` refetches its last week on every run. The seven days are a margin on one
  observed two-day correction, not a published limit.
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

Octopus rate-limits by query complexity and an hourly point allowance. A menu-bar refresh runs
every five minutes, every 30 seconds near a rate switch, and on opening the menu if the data is
over a minute old. It normally costs **one** request; it used to cost six. A usage window costs one
request per day fetched — seven per week. These keep that in check and should not be undone
lightly:

- **The Kraken token and the discovered meters are shared** through `OctopusSession`. Every
  refresh used to log in again and rediscover every meter. The token is kept 45 minutes (it lasts
  an hour) and the meters an hour; any failed request drops everything cached, so a revoked token
  or a changed account costs one failure rather than the full timeout.
- **A refresh is split by how fast each half changes.** The tariff half — prices, schedule,
  balance, agreements — changes a few times a year, so `TariffState` is reused for an hour
  (`tariffIsReusable`), and refetched at once for "Refresh Now", a key change or a meter change.
  The device half — devices, the charge plan and completed dispatches — is one request every
  time, built by `deviceQuery`. A tariff with no fixed rates (Agile) needs `applicableRates`,
  which slides with the clock, so that rides in the device request rather than the hourly one.
- **The charge plan rides with the device list** because the device ids are remembered from the
  previous refresh. `flexPlannedDispatches` is keyed by device, so the plan used to need a second
  round trip after the device list. A device not seen before costs one follow-up request, once. A
  failed device request forgets the ids — a stale id makes its alias error, and with it the whole
  request — so the next attempt rediscovers them rather than failing the same way.
- Fetched weeks are cached in memory, keyed by meter and week offset. A settled week is kept
  indefinitely; one still waiting on Octopus is re-checked after 15 minutes. The current week is
  never "settled", so it always re-checks, and nor is last week until a week after it ended,
  since Octopus corrects costs after publishing them.
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
  swatch, so the text stays in one column instead of stepping in and out. The carbon chart keeps
  the intensity band's swatch in both views: in fuel-mix mode no bar is drawn in that colour, but
  it names the band the same way it does in the intensity view. It used to be dropped there. The
  fuel swatches also appear in both views, since those colours are that fuel's identity
  throughout the window, and both views list every fuel.
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
  `CarbonSeries.mixBasis` is what tells the user, and it is covered by `--selftest`. It separates
  national half hours already over ("GB actual") from those still ahead ("GB forecast"), judged
  against `fetchedAt`: it used to call the whole 48-hour forecast view "GB actual".
- **The carbon intensity forecast misfires at sunrise, and it is upstream.** On 23 September 2026
  the two half hours to 06:00Z carried solar at 78% and 84% of generation — 19.0 GW and 22.5 GW
  against demand of 24.3 and 26.6 GW — with an intensity of 5 and 8 gCO₂/kWh, before snapping
  back to 2.2% solar and 203 gCO₂ in the next period. Both the national and the regional series
  carried it, so it is not a parsing fault. **It is shown as published.** A screen against a 16 GW
  solar ceiling (`mixLooksImplausible`) used to grey such half hours, keep them out of the
  averages and out of `cleanest`, and fetched demand and the national mix on the Octopus source
  purely to run it; all of that was removed. So `cleanest` and the legend's averages take every
  half hour as the operator publishes it, and a misfire can be named the cleanest time.
- **The 100 gCO₂/kWh rule is drawn over the columns, not behind them.** At half-hourly width the
  bars are a solid wall and a rule behind them is invisible for most of the chart. It appears on
  the intensity view only — it means nothing against a demand or percentage axis — and only when
  the axis actually reaches it. The threshold is Octopus's own published green/not-so-green line,
  which is why it earns a rule when an invented spike threshold would not.
- **Forecast oddities are left alone.** The same series put 284 and 276 gCO₂ either side of
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
- **Half-hourly bars always meet**, in both charts and at any width, and have square tops. Both
  charts used to open a 2pt gap once bars were wide enough (6pt usage, 14pt carbon), which striped
  the stack and read as a cap on how wide a bar could get; rounded tops on meeting bars would
  notch the strip. Daily columns still sit apart, capped at 46pt, with rounded tops.
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
- **The icon encodes two things, one per visual channel.** The shape is the carbon intensity — a
  leaf at or under 100 gCO₂/kWh (`greenThresholdGrams`, the carbon chart's own line), smoke above —
  and fill plus colour is the rate: filled green when cheap, an outline template otherwise.
  Keeping green for "cheap" alone matters, so the leaf is not green in its own right; it is only
  green because the rate is. Carbon unknown falls back to the bolt, which says the rate alone
  rather than guessing. `statusSymbol` is the rule and `--selftest` checks every symbol exists,
  since a missing one leaves the item as bare text.
- **The icon's carbon comes from one keyless request every half hour** (`fetchRegionalReadings`,
  National Grid's regional forecast for the selected meter's postcode), not the carbon window's
  full fetch with its demand and national-mix calls. A failed refresh keeps the last forecast
  until it runs out, since it covers 48 hours. A sunrise misfire like 23 September's 5 gCO₂ shows a
  leaf for that half hour, as it does everywhere else. The menu's carbon section (`carbonLines`)
  works from the same readings and says when the grid is next green; it names no "cleanest half
  hour", which is the carbon window's job.
- **Menu order is current rate, upcoming cheap rate, carbon intensity, cars, account, tariffs**,
  then Refresh Now, Settings… and Quit. **The windows open from the information itself**: the
  carbon section's "Now … gCO₂/kWh" line opens the carbon window, with when it is next green as
  its subtitle, and each tariff line opens its meter's usage, with its end date as the subtitle —
  macOS 14+; a grey line under it on 13 — and a tooltip saying what it opens. Until the carbon
  forecast loads, a plain "Carbon Intensity…" item stands in. A two-property account gets one
  usage item per address with nothing to match up, and an export tariff, having no usage, stays
  plain text. These are `Line.action` entries from `menuLines`, so `--selftest` prints their
  placement; `rebuildMenu` turns them into items, numbering the usage
  items ⌘1, ⌘2… in listing order (none past nine) and giving the carbon one ⌘C. Each tariff carries its `MeterChoice`, built from the supply
  point the tariff query returns, so the items need no meter discovery; an export meter gets
  none. The carbon item stays even with no Octopus data, since the window needs none. Usage
  windows are one per meter, keyed by `MeterChoice.id`, and closed when the key changes.
  Refresh Now, Settings… and Quit are built in `rebuildMenu` and are not covered by any test. An error,
  when there is one, comes before everything, split off by a separator: at the foot of the
  information it sat under the tariff list while the prices above it went stale.
  A single-rate tariff skips the upcoming-cheap section rather than showing it empty — that used
  to be an early return, which forced the section to be last, and is now an `if` so the order is
  free to change. The VAT and standing-charge footnote sits directly under the prices it
  qualifies rather than at the foot of the menu, as the subtitle of the line below the rate
  heading — or alone, in the same style, when there is no such line. **Details sit under their
  line in the subtitle style**:
  a clickable line uses the menu item's own subtitle (macOS 14+), and a non-clickable one — a
  car, the balance, an export tariff — is a `Line.info`, drawn by `infoItem` with the same
  smaller secondary type under the title, aligned with it rather than indented.
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
  alerts because there is nothing to compare against. The cooldown **holds** a change rather than
  dropping it: `DispatchAlertGate` keeps the last announced plan as the comparison point and
  announces once the cooldown ends, unless the plan has flapped back. Skipping the check instead
  lost the change for good, since the next fetch compared against one that already contained it.
- **A failed device query is "don't know", not "nothing planned".** It is swallowed so the rate
  display survives, but it also costs the device ids and so the whole charge plan. The snapshot
  says `devicesKnown: false`, `carryForwardDevices` keeps the last known cars and plan, and a plan
  that was never known is never compared — otherwise one transient failure announced "Smart charge
  cancelled" and blanked the charge windows out of the menu and the icon.
- **A fetch checks, when it lands, that it is still wanted.** Changing the key or the meter bumps
  a generation; a fetch started under an older one is discarded rather than shown. A manual
  refresh asked for mid-fetch is queued, not dropped. The usage and carbon windows do the same,
  and reload whatever was asked for while they were busy — before this, clicking back twice
  quickly left a window on "Loading…" and a meter change mid-load showed the old meter's week.
- **Automatic refreshing stops after 10 consecutive failures** until "Refresh Now". Without this a
  bad key retries every 30 seconds indefinitely.
- **The account section lists every agreement, one per meter point, merged with nothing.** Two
  earlier shapes were both wrong: filtering to agreements *ending* dropped Intelligent Octopus Go
  entirely, because a variable tariff has no `validTo` — so the menu never named the tariff its
  own prices came from — and collapsing identical agreements hid which address each belonged to.
  `parseTariffEnds` now returns one `TariffEnd` per meter point, `ends` is optional, and each
  carries its property's short address, shown only when the account holds more than one.
  **Alerts still collapse**, through `alertKey`, which excludes the property: being told twice
  that the same tariff ends on the same day at two houses is noise, even though the list shows
  both. The balance stays unlabelled because it genuinely is account-wide.
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
