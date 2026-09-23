# Octopus

A macOS menu bar app for Octopus Energy, built around Intelligent Octopus Go. It shows whether you
are on the cheap or standard rate right now, when that next changes, your car's charge level, and
charts of your electricity and gas use.

There are also three command-line scripts covering the same ground, for the terminal or for cron.

> **This project was vibe-coded.** Every line was written by Claude (Anthropic's Claude Code) from
> conversational prompts, then checked against a real Octopus account. It has no test suite beyond
> the built-in `--selftest` (checked against its committed output by `./selftest.sh`), and much of it — the chart in particular — was verified by rendering
> it and looking, rather than by anything automated. Read it with that in mind before trusting it
> with anything that matters. `AGENTS.md` records what the API actually does and why the code is
> shaped the way it is.

## Menu bar app

Requires macOS 13 or later and Xcode's command line tools.

```bash
./install.sh          # build, then install into /Applications and launch
```

`install.sh` quits any running copy first, replaces the installed bundle outright rather than
copying over it, and takes a destination if you would rather not touch `/Applications`:

```bash
./install.sh ~/Applications    # no admin rights needed
```

To build without installing:

```bash
./build.sh
open build/OctopusMenuBar.app
```

On first launch choose **Settings…** from the menu and paste your Octopus API key, from the API
access page of your Octopus dashboard. It is stored in your login Keychain, never in a file.

### What it shows

- **Icon:** a green filled bolt on the cheap rate, an outline bolt on the standard rate, a warning
  triangle if there is no data or an error. Hover it for the current price.
- **Menu:** the current rate and when it next changes, the charge Octopus has planned for tonight,
  each car's charge level in both percent and kWh, charging status and today's charging goal, your account balance, any
  fixed tariff about to end, and the cheap windows in the next 48 hours including smart-charge
  dispatches.
- **Alerts:** a notification 10 minutes before the rate changes — either way, cheap starting or
  cheap ending — another when the smart-charge plan changes — a slot added, dropped, moved by more than five minutes, or cancelled
  altogether — and one as a fixed tariff nears its end, at 30 days, 14, 7 and the day before.
  Octopus nudges dispatches by a minute or two constantly, and those are ignored. All three can be
  turned off in Settings.
- **Electricity Use… / Gas Use…:** a week of use as stacked columns.
- **Carbon Intensity…:** how clean the grid is where you live, half hour by half hour.

### Starting at login

**Settings → Open at login** asks macOS to start the app when you log in. It registers the app
bundle itself rather than installing a launch agent, so there is nothing left behind if you delete
the app, and it appears under **System Settings → General → Login Items** where you can override
it. macOS may ask you to approve it there the first time.

Turn it on after installing rather than before: registered from `build/`, macOS has no installed
bundle to launch and the checkbox reports that it cannot find one.

### The usage windows

Each fuel gets its own window, with its own week position and meter. Both offer:

- **kWh or pounds**, and a column **per day or per half hour**.
- **Week navigation.** Back and forward a week at a time; forward stops at the current week.
  Weeks you have already looked at are remembered, so going back is instant.
- **Hover** a column for its breakdown, each band's price, and the exact period.

Columns stack by **price** — off-peak and standard — based on what each half hour was actually
billed, not on an assumed schedule. A smart charge is marked under the axis rather than split out
of the bar, because the tariff's per-device buckets are a billing allocation rather than a
measurement of what the car drew.

Gas is single-rate, so its columns are one band with no smart-charge marker.

Days Octopus has not published yet show a grey dash rather than an empty bar — the two mean
different things. Octopus runs roughly two days behind, so the last day or two of the current week
is normally blank.

In pounds, the standing charge stacks underneath as a grey band, so a column totals what the period
actually cost. It is left out of the kWh view, where it would be energy that was never delivered.

All prices and costs include VAT, matching your bill.

### The planned charge

The menu shows the slots Octopus has scheduled and roughly how much it intends to put in:

```
Charging 00:30–04:00, 05:30–06:00 · about 20 kWh planned
```

It says **about** on purpose. Octopus states the figure at a flat assumed rate rather than
measuring anything — on the account this was built against, a seven-slot plan came to exactly
seven times the same constant that appears in the billing data. It is a good guide to the plan's
intent, not a prediction of what the car will actually draw. A charge you asked for yourself is
labelled a boost rather than a smart charge.

### Balance and tariff end dates

The menu shows your account balance and the balance Octopus expects in a year's time — its own
projection, not a calculation of ours. A growing credit means your direct debit is running ahead of
what you use.

The **Tariffs** section lists every active agreement on the account — one line per meter point, nothing merged — with
the last day it covers, or "no end date" for a variable tariff like Intelligent Octopus Go. If the
account holds more than one property, each line names the address.

Octopus states an agreement's end as the instant cover stops, which is midnight, so the date shown
is the day before that instant: the last day you are actually on that tariff.

The balance is the account's, covering every address on it.

### The carbon intensity window

Grams of CO₂ per kWh for your region, one bar per half hour, shaded by the same five bands the
grid operator publishes — very low through very high. Hover a bar for the exact figure and what
the grid is burning. A dotted rule marks now, and a dashed one marks 100 gCO₂/kWh — the line
Octopus draws on its own site between green and not-so-green.

Two sources answer the same question, and the window switches between them:

- **National Grid** is the default. It needs no API key, covers 48 hours ahead, serves past weeks,
  and reports the generation mix behind every number.
- **Octopus** carries its own forecast. It covers 24 hours only, with no history and no mix, so it
  is mostly here for comparison — the two agreed within 2 gCO₂ when this was built.

**Intensity or Fuel Mix.** The mix view stacks each half hour by what generated it — gas, wind,
nuclear and the rest — with each fuel's average across the window in the legend. It is only
available from National Grid, and the switch disables itself otherwise.

A mix bar's **height is GB electricity demand** for that half hour, so the shape shows when the
country is actually drawing power: a trough around 20 GW overnight, a peak near 34 GW in the early
evening. Settled demand comes from the outturn, and the day-ahead forecast covers the near future;
half hours beyond the forecast show a baseline dash rather than an empty bar. If demand can't be
reached at all, bars fall back to showing shares out of 100%.

Demand is national, so the split stacked inside it is the national one wherever that has been
published — and there the tooltip gives real gigawatts per fuel. Where only the regional figure
exists, the segments are your region's proportions drawn at national scale and the tooltip drops
the gigawatt figures. The footer always states which basis is in use.

**Implausible half hours are greyed.** The published forecast occasionally misfires around
sunrise, reporting solar as most of the country's generation and the grid as almost carbon-free
for a half hour or two. Anything implying more solar than Britain can physically generate is
drawn in flat grey and left out of the legend's averages, with the tooltip saying why. The
figures are not corrected — they belong to the grid operator, and the glitch is in their data
rather than in this app.

**Week navigation.** Back and forward a week at a time, the same weeks the usage windows show, so
the two can be read against each other. Forward from the earliest week returns to the live
forecast. Past weeks are kept for the session, since they cannot change. Only National Grid serves
history, so the arrows are disabled on Octopus.

The region comes from the postcode of whichever electricity meter is selected in Settings, and
only the outward part of it is sent.

### Multiple properties and meters

Meters are matched to the property they actually sit at, and only those with an active agreement
are offered. If you have more than one of a fuel, **Settings** has a picker per fuel and remembers
your choice. The electricity choice also drives the menu bar rate.

A usage window is only listed for a fuel you have a meter for.

### Command-line scripts

```bash
OCTOPUS_API_KEY=sk_live_... python3 octopus_rate.py
```

Python 3.9 or later, standard library only. Prints the current rate, next change, and each car:

```
Standing charge 54.81p/day incl VAT
Now: PEAK  (30.37p/kWh incl VAT)
Next change Today 23:30 -> 6.90p/kWh
Mini Cooper: 62% (target 80% by 07:00)
    About 30.5 of 49.2 kWh in the battery
    Not charging · smart control not available
    Charge level as of Today 15:08
Balance £532.06 in credit · £710.62 in credit expected in a year
Octopus 12M Fixed (gas) ends Thu 8 Oct — in 16 days
```

`octopus_history.py` shows which half hours were billed at the off-peak rate, day by day:

```bash
OCTOPUS_API_KEY=sk_live_... python3 octopus_history.py --days 7
OCTOPUS_API_KEY=sk_live_... python3 octopus_history.py --meters    # list meters
```

`octopus_carbon.py` prints the carbon intensity chart as text. It needs **no API key** unless you
want the Octopus source or want the postcode looked up from your account:

```bash
python3 octopus_carbon.py --postcode SN13          # next 48 hours
python3 octopus_carbon.py --postcode SN13 --mix    # with the generation mix
python3 octopus_carbon.py --postcode SN13 --week 1 # last week
OCTOPUS_API_KEY=sk_live_... python3 octopus_carbon.py --source octopus
```

```
   13:00 ████████··························    69 low          22.7 GW  wind 36% (8.3 GW), solar 22% (5.0 GW)
   13:30 ████████··························    69 low          23.3 GW  wind 37% (8.6 GW), solar 21% (5.0 GW)

  97 half hours · 17 below 100 gCO2/kWh
  cleanest Thu 13:30 at 67 gCO2/kWh
```

Half hours whose published mix is impossible are marked `!` and left out of those figures, as in
the app.

### Known limitations

- The app is ad-hoc signed, so the first launch may need a right-click then Open. Each rebuild
  changes the signature, and macOS asks again for permission to read the Keychain item — choose
  **Always Allow**.
- The car's charge level is only as fresh as the last report Octopus received from the
  manufacturer, which can be an hour or more old.
- Octopus does not report whether the car is plugged in, so charging status is inferred from the
  live power reading and the smart-control state.
- The API cannot tell you how much of a period was the car versus the rest of the house. The
  per-device split in the billing data is an allocation, not a measurement.

## Security

Never commit or paste your API key. If it has been exposed, generate a new one in the Octopus
dashboard and revoke the old one.

## Contributing

`AGENTS.md` has the build commands, source layout, API behaviour and the findings behind the
design decisions above.
