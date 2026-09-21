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
        for (name, unit, scale, dark) in [
            ("kwh-light", UsageUnit.kwh, Granularity.day, false),
            ("money-dark", .money, .day, true),
            ("halfhour-light", .kwh, .halfHour, false),
            ("halfhour-dark", .kwh, .halfHour, true),
        ] {
            renderUsageChart(
                periods: series.periods(scale), unit: unit, granularity: scale, dark: dark,
                size: CGSize(width: 604, height: 300), to: "\(dir)/chart-\(name).png")
        }
        let hairlines = countHairlines(
            periods: series.periods(.halfHour), dark: false, size: CGSize(width: 604, height: 300))
        print("half-hour hairline pixels: \(hairlines)")
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
