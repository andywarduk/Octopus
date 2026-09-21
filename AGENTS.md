# Working on this project

Notes for anyone — human or agent — changing the code. `README.md` covers what the app does; this
covers how it is built and what the API actually returns, including the things that are not
obvious and cost time to rediscover.

## Build and check

```bash
./build.sh                                          # compiles every .swift in the root
open build/OctopusMenuBar.app
```

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
axis steps, and the menu text at three moments.

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
| `AppIcon.swift` | The app icon, drawn in code |
| `AppDelegate.swift` | Status item, the 30-second tick, the refresh cycle |
| `AppDelegate+Menu.swift` | Icon state and menu building |
| `AppDelegate+Notifications.swift` | "Cheap rate soon" alerts |
| `AppDelegate+Settings.swift` | The Settings window and meter pickers |
| `SelfTest.swift` | `--selftest` output |
| `main.swift` | Entry point and command-line flags |

`octopus_rate.py` and `octopus_history.py` are standalone; standard library only, Python 3.9+.
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
  app does not reach them. `octopus_rate.py` in particular lags the app's logic.
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
- **The chart palette is validated**, not chosen by eye. Off-peak green `#1baf7a` / `#199e70`,
  standard blue `#2a78d6` / `#3987e5` (light/dark), smart-charge marker orange `#eb6834` /
  `#d95926`. These pass colourblind and contrast checks in both modes. Green is below 3:1 on the
  light surface, which is why the legend carries totals and columns are labelled — do not remove
  those without re-checking the palette.
- **Dark mode uses its own steps**, not an automatic flip.
- **Axis steps are chosen before the maximum.** Picking the maximum and quartering it gives ticks
  like 1.25 / 2.5 / 3.75. `axisScale` picks a round step from 1, 2, 2.5, 5 × a power of ten and
  takes the finest needing six lines or fewer.
- **Half-hourly bars snap both edges to the pixel grid.** Rounding only the origin leaves a
  sub-pixel sliver that renders as a hairline between bars — 396 of them before this was fixed.
- **The menu is rebuilt only in `menuNeedsUpdate`**, which runs before display. Rebuilding an open
  menu makes it flicker or close, and anything fetched while it is open shows next time it opens.
- **Automatic refreshing stops after 10 consecutive failures** until "Refresh Now". Without this a
  bad key retries every 30 seconds indefinitely.
- **Meters are discovered as matched pairs.** Taking the first property and the first agreement
  independently pairs a property with another address's meter on a multi-property account.
- **VAT-inclusive prices everywhere**, because that is what the bill says. The menu bar states it
  once in its footer rather than suffixing every number.
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
