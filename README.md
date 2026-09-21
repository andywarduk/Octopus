# Octopus

A macOS menu bar app for Octopus Energy, built around Intelligent Octopus Go. It shows whether you
are on the cheap or standard rate right now, when that next changes, your car's charge level, and
charts of your electricity and gas use.

There are also two command-line scripts covering the same ground, for the terminal or for cron.

> **This project was vibe-coded.** Every line was written by Claude (Anthropic's Claude Code) from
> conversational prompts, then checked against a real Octopus account. It has no test suite beyond
> the built-in `--selftest`, and much of it — the chart in particular — was verified by rendering
> it and looking, rather than by anything automated. Read it with that in mind before trusting it
> with anything that matters. `AGENTS.md` records what the API actually does and why the code is
> shaped the way it is.

## Menu bar app

Requires macOS 13 or later and Xcode's command line tools.

```bash
./build.sh
open build/OctopusMenuBar.app
```

On first launch choose **Settings…** from the menu and paste your Octopus API key, from the API
access page of your Octopus dashboard. It is stored in your login Keychain, never in a file.

### What it shows

- **Icon:** a green filled bolt on the cheap rate, an outline bolt on the standard rate, a warning
  triangle if there is no data or an error. Hover it for the current price.
- **Menu:** the current rate and when it next changes, each car's charge level and charging status,
  and the cheap windows in the next 48 hours including smart-charge dispatches.
- **Alert:** a notification 10 minutes before a cheap window starts. Toggle it in Settings.
- **Electricity Use… / Gas Use…:** a week of use as stacked columns.

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
Now: PEAK  (30.37p/kWh incl VAT)
Standing charge 54.81p/day incl VAT
Next change Today 23:30 -> 6.90p/kWh
Mini Cooper: 62% (target 100%)
    Not charging · smart control not available
    Charge level as of Today 15:08
```

`octopus_history.py` shows which half hours were billed at the off-peak rate, day by day:

```bash
OCTOPUS_API_KEY=sk_live_... python3 octopus_history.py --days 7
OCTOPUS_API_KEY=sk_live_... python3 octopus_history.py --meters    # list meters
```

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
