// Octopus Energy menu bar app: shows whether you're on the cheap or standard rate,
// your car's charge level, and the upcoming cheap-rate windows.
//
// Build: ./build.sh     Run: open build/OctopusMenuBar.app
// The API key is entered in Settings… and stored in the login Keychain.
//
// Entry point. Top-level code is only legal in a file called main.swift.

import Cocoa

// OctopusMenuBar --iconset DIR : write the PNGs that `iconutil -c icns` expects.
if let i = CommandLine.arguments.firstIndex(of: "--iconset"), i + 1 < CommandLine.arguments.count {
    let dir = CommandLine.arguments[i + 1]
    for size in [16, 32, 128, 256, 512] {
        renderIcon(pixels: size, to: "\(dir)/icon_\(size)x\(size).png")
        renderIcon(pixels: size * 2, to: "\(dir)/icon_\(size)x\(size)@2x.png")
    }
    exit(0)
}

// OctopusMenuBar --chartdemo DIR : render the usage chart to PNGs to check the layout.
if let i = CommandLine.arguments.firstIndex(of: "--chartdemo"), i + 1 < CommandLine.arguments.count {
    let dir = CommandLine.arguments[i + 1]
    MainActor.assumeIsolated {
        let series = sampleUsageWeek(tz: .current)
        for (name, unit, scale, dark, hover) in [
            ("kwh-light", UsageUnit.kwh, Granularity.day, false, Int?.none),
            ("money-light", .money, .day, false, nil),
            ("money-dark", .money, .day, true, nil),
            ("halfhour-light", .kwh, .halfHour, false, nil),
            ("halfhour-money", .money, .halfHour, false, nil),
            ("halfhour-dark", .kwh, .halfHour, true, nil),
            ("tooltip-day", .kwh, .day, false, 4),
            ("tooltip-halfhour", .kwh, .halfHour, false, 4 * 48 + 27),
            ("tooltip-money", .money, .day, true, 4),
        ] {
            renderUsageChart(
                periods: series.periods(scale), unit: unit, granularity: scale, dark: dark,
                size: CGSize(width: 604, height: 300), hover: hover, to: "\(dir)/chart-\(name).png")
        }
        renderUsageChart(
            periods: [], unit: .kwh, granularity: .day, dark: false,
            size: CGSize(width: 604, height: 300), placeholder: "No usage to show",
            to: "\(dir)/chart-empty.png")
        let hairlines = countHairlines(
            periods: series.periods(.halfHour), dark: false, size: CGSize(width: 604, height: 300))
        print("half-hour hairline pixels: \(hairlines)")

        // The carbon chart is drawn by hand too, so it gets the same treatment. `now` is fixed
        // rather than read from the clock, or the rule moves between runs and the images differ.
        let tz = TimeZone(identifier: "Europe/London") ?? .current
        let start = ISO8601DateFormatter().date(from: "2026-09-22T17:00:00Z")!
        let forecast = sampleCarbonForecast(from: start)
        for (name, dark, mode, hover) in [
            ("light", false, CarbonMode.intensity, Int?.none),
            ("dark", true, .intensity, nil),
            ("tooltip", false, .intensity, 31),
            ("mix-light", false, .mix, nil),
            ("mix-dark", true, .mix, nil),
            ("mix-tooltip", false, .mix, 31),
        ] {
            renderCarbonChart(
                readings: forecast, now: start.addingTimeInterval(3 * 3600), tz: tz, dark: dark,
                size: CGSize(width: 740, height: 320), mode: mode, hover: hover,
                to: "\(dir)/carbon-\(name).png")
        }
        renderCarbonChart(
            readings: [], now: start, tz: tz, dark: false, size: CGSize(width: 624, height: 300),
            placeholder: "No carbon intensity to show", to: "\(dir)/carbon-empty.png")
    }
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    selfTest()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
