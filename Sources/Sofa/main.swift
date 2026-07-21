import AppKit
import SwiftUI

MainActor.assumeIsolated {
    // Dev-only design snapshot (never in released builds):
    //   SOFA_SNAPSHOT=/path/out.png  [SOFA_APPEARANCE=dark|light]
    if let path = ProcessInfo.processInfo.environment["SOFA_SNAPSHOT"] {
        let app = NSApplication.shared
        if let mode = ProcessInfo.processInfo.environment["SOFA_APPEARANCE"] {
            app.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        }
        _ = AppState.shared
        _ = SocialService.shared
        let priorWelcomeDone = AppState.shared.welcomeDone
        if ProcessInfo.processInfo.environment["SOFA_SNAPSHOT_WELCOME"] != nil {
            AppState.shared.welcomeDone = false
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2.5))
        let dark = ProcessInfo.processInfo.environment["SOFA_APPEARANCE"] == "dark"
        // Approximate the glass panel behind the content so contrast reads
        // realistically: a mid grey, like the wallpaper-tinted glass.
        let backing = dark
            ? Color(red: 0.14, green: 0.15, blue: 0.17)
            : Color(red: 0.92, green: 0.93, blue: 0.95)
        let root = ZStack {
            backing
            ContentView()
        }
        .environment(\.colorScheme, dark ? .dark : .light)
        let view = NSHostingView(rootView: root)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.frame = NSRect(origin: .zero, size: NSSize(width: 380, height: view.fittingSize.height))
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        if let rep {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        // exit() skips deinitializers, so put defaults back explicitly
        // (the welcome flag persists via UserDefaults).
        AppState.shared.welcomeDone = priorWelcomeDone
        UserDefaults.standard.synchronize()
        guard let rep, let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
        try? data.write(to: URL(fileURLWithPath: path))
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
