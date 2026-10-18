// Octopus Energy menu bar app: shows whether you're on the cheap or standard rate,
// your car's charge level, and the upcoming cheap-rate windows.
//
// Build: ./build.sh     Run: open build/OctopusMenuBar.app
// The API key is entered in Settings… and stored in the login Keychain.
//
// Entry point. Top-level code is only legal in a file called main.swift.

import Cocoa

/// Creates an output directory for the flags below. Writing into one that doesn't exist fails
/// silently, which looks like a render that produced different images from last time.
func outputDirectory(_ path: String) -> String {
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

// OctopusMenuBar --iconset DIR : write the PNGs that `iconutil -c icns` expects.
if let i = CommandLine.arguments.firstIndex(of: "--iconset"), i + 1 < CommandLine.arguments.count {
    let dir = outputDirectory(CommandLine.arguments[i + 1])
    for size in [16, 32, 128, 256, 512] {
        renderIcon(pixels: size, to: "\(dir)/icon_\(size)x\(size).png")
        renderIcon(pixels: size * 2, to: "\(dir)/icon_\(size)x\(size)@2x.png")
    }
    exit(0)
}

// OctopusMenuBar --chartdemo DIR : render the usage chart to PNGs to check the layout.
if let i = CommandLine.arguments.firstIndex(of: "--chartdemo"), i + 1 < CommandLine.arguments.count {
    let dir = outputDirectory(CommandLine.arguments[i + 1])
    MainActor.assumeIsolated {
        // A fixed week in a fixed timezone, the one `--selftest` uses. Built from today's date and
        // the Mac's own zone, the day labels moved every midnight and every image differed from
        // the day before's — so a diff meant nothing, which is what the seeding was for.
        let tz = londonTimeZone
        let series = sampleUsageWeek(tz: tz, now: ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")!)
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
                periods: series.periods(scale), unit: unit, granularity: scale, tz: tz, dark: dark,
                size: CGSize(width: 604, height: 300), hover: hover, to: "\(dir)/chart-\(name).png")
        }
        renderUsageChart(
            periods: [], unit: .kwh, granularity: .day, tz: tz, dark: false,
            size: CGSize(width: 604, height: 300), placeholder: "No usage to show",
            to: "\(dir)/chart-empty.png")
        let hairlines = countHairlines(
            periods: series.periods(.halfHour), tz: tz, dark: false, size: CGSize(width: 604, height: 300))
        print("half-hour hairline pixels: \(hairlines)")

        // Electricity with its unpublished tail filled from a Home Mini, drawn faded.
        let filled = sampleUsageWeekFilled(tz: tz, now: ISO8601DateFormatter().date(from: "2026-09-25T15:00:00Z")!)
        for (name, unit, scale, dark, hover) in [
            ("day", UsageUnit.kwh, Granularity.day, false, Int?.none),
            ("money-dark", .money, .day, true, nil),
            ("halfhour", .kwh, .halfHour, false, nil),
            ("tooltip-halfhour", .kwh, .halfHour, false, 6 * 48 + 26),
        ] {
            renderUsageChart(
                periods: filled.periods(scale), unit: unit, granularity: scale, tz: tz, dark: dark,
                size: CGSize(width: 604, height: 300), hover: hover, to: "\(dir)/filled-\(name).png")
        }

        // Gas with its unpublished tail filled from a Home Mini, drawn faded.
        let gas = sampleGasWeek(tz: tz, now: ISO8601DateFormatter().date(from: "2026-09-25T15:00:00Z")!)
        for (name, unit, scale, dark, hover) in [
            ("day", UsageUnit.kwh, Granularity.day, false, Int?.none),
            ("money-dark", .money, .day, true, nil),
            ("halfhour", .kwh, .halfHour, false, nil),
            ("tooltip-day", .kwh, .day, false, 5),
            ("tooltip-halfhour", .kwh, .halfHour, false, 6 * 48 + 16),
        ] {
            renderUsageChart(
                periods: gas.periods(scale), unit: unit, granularity: scale, tz: tz, dark: dark,
                size: CGSize(width: 604, height: 300), hover: hover, to: "\(dir)/gas-\(name).png")
        }

        // The carbon chart is drawn by hand too, so it gets the same treatment. `now` is fixed
        // rather than read from the clock, or the rule moves between runs and the images differ.
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

        // The live power chart, at a fixed `now` for the same reason.
        let liveNow = ISO8601DateFormatter().date(from: "2026-10-12T19:13:05Z")!
        for (name, range, dark, hover) in [
            ("hour-light", LivePowerRange.hour, false, Int?.none),
            ("hour-dark", .hour, true, nil),
            ("hour-tooltip", .hour, false, 200),
            ("6h-light", .sixHours, false, nil),
            ("24h-light", .day, false, nil),
            ("24h-dark", .day, true, nil),
            ("24h-tooltip", .day, false, 60),
        ] {
            renderLivePowerChart(
                series: sampleLivePower(range: range, now: liveNow), dark: dark,
                size: CGSize(width: 604, height: 260), hover: hover, to: "\(dir)/live-\(name).png")
        }
        renderLivePowerChart(
            series: nil, dark: false, size: CGSize(width: 604, height: 260),
            placeholder: "No readings from the Home Mini in the last hour", to: "\(dir)/live-empty.png")
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
