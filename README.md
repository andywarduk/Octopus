# Octopus

Tools for checking your Octopus Energy rate (built around Intelligent Octopus Go) using the
[Kraken GraphQL API](https://developer.octopus.energy/graphql).

- **`OctopusMenuBar.swift`**: a macOS menu bar app that shows whether you're on the cheap or
  standard rate, your car's charge level and charging status, and upcoming cheap windows.
- **`octopus_rate.py`**: a command-line version showing the same rate, charge level and charging status.

## Menu bar app

Requires macOS 13 or later and Xcode's command line tools (`swiftc`).

```bash
./build.sh
open build/OctopusMenuBar.app
```

On first launch choose **Settings…** from the menu and paste your Octopus API key. It is stored in
your login Keychain, never in a file. Get the key from the API access page of your Octopus dashboard.

### What it shows

- **Icon:** a green filled bolt on the cheap rate, an outline bolt on the standard rate, and a warning
  triangle if there is no data or an error.
- **Menu:**
  - The current rate and when it next changes.
  - Each car's charge level, target, and charging status.
  - The cheap windows in the next 48 hours, including smart-charging dispatches.
- **Alert:** a notification 10 minutes before a cheap window starts. Turn it on or off, or send a test, in Settings.

### Refreshing

- The icon and cheap/standard decision are recalculated every 30 seconds from data already held.
- Fresh data is fetched from Octopus every 5 minutes, or every 30 seconds within 3 minutes either side
  of a rate change (cheap starting or ending).
- It also fetches when the menu is opened and the data is over a minute old, and from **Refresh now**.
- After 10 consecutive failures it stops fetching and shows the error in the menu, so a bad key or an
  outage can't keep hitting the API. **Refresh now** (or saving a key) starts it again.

### Notes

- The app is ad-hoc signed. The first launch may need a right-click, then Open. Each rebuild changes
  the signature, so macOS asks again for permission to read the Keychain item; choose **Always Allow**.
- The car's charge level is only as fresh as the last report Octopus received from the manufacturer.
- Octopus doesn't report "plugged in" directly. Charging status is inferred from the live power
  reading and the smart-control state.
- The app icon is drawn in code. `build.sh` renders it into `AppIcon.icns` with `iconutil`; if that fails
  the app still builds, but notifications use a generic icon.
- `OctopusMenuBar --selftest` prints sample menus from fixed data, without using the network.
  `OctopusMenuBar --iconset DIR` writes the icon PNGs.

## Command-line script

```bash
OCTOPUS_API_KEY=sk_live_... python3 octopus_rate.py
```

Python 3.9 or later, standard library only. It logs in, finds your account and import meter,
and prints something like:

```
Now: PEAK  (28.93p/kWh)
Next change Today 23:30 -> 6.57p/kWh
Mini Cooper: 62% (target 100%)
    Not charging · smart control not available
    Charge level as of Today 15:08
```

Set `DEBUG=1` to also print the raw rates, tariff schedule, dispatches and devices.

## How the rate is worked out

`applicableRates` returns the tariff's rate bands, but not when each one applies. So:

1. The cheap and standard rates are the lowest and highest values returned.
2. The cheap window comes from the agreement's `timeOfUseScheme`, matching slots whose name contains
   "off", "cheap" or "night" (for example `ECO7_NIGHT`, 23:30 to 05:30). If none match, 23:30 to 05:30 is used.
3. Smart-charging dispatches (`plannedDispatches` and `completedDispatches`) also count as cheap.

## API

- Endpoint: `https://api.octopus.energy/v1/graphql/`
- Auth: exchange your API key for a token with the `obtainKrakenToken` mutation, then send the token
  in the `Authorization` header.
- Introspection works without logging in, so the schema can be explored in the GraphiQL page at the endpoint.

## Security

Never commit or paste your API key. If it has been exposed, generate a new one in the Octopus dashboard
and revoke the old one.
