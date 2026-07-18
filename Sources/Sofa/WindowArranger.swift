import AppKit
import ApplicationServices
import CoreGraphics

/// Builds Theater as a verified, reversible composition. Sofa-owned browser
/// Theater uses a real native full-screen Space with the video and call as its
/// only visible surfaces; external call apps use a desktop fallback.
@MainActor
enum WindowArranger {

    struct CallApp {
        let name: String
        let bundleID: String
    }

    static let knownCallApps: [CallApp] = [
        CallApp(name: "FaceTime", bundleID: "com.apple.FaceTime"),
        CallApp(name: "Zoom", bundleID: "us.zoom.xos"),
        CallApp(name: "Discord", bundleID: "com.hnc.Discord"),
        CallApp(name: "Microsoft Teams", bundleID: "com.microsoft.teams2"),
        CallApp(name: "Microsoft Teams", bundleID: "com.microsoft.teams"),
        CallApp(name: "WhatsApp", bundleID: "net.whatsapp.WhatsApp"),
        CallApp(name: "Slack", bundleID: "com.tinyspeck.slackmacgap"),
        CallApp(name: "Telegram", bundleID: "ru.keepcoder.Telegram"),
        CallApp(name: "Skype", bundleID: "com.skype.skype"),
        CallApp(name: "Webex", bundleID: "Cisco-Systems.Spark"),
    ]

    /// A running process is not necessarily a live call. Once Accessibility is
    /// available, require a plausible visible window as well.
    static func runningCallApp(in running: Set<String>? = nil) -> CallApp? {
        let running = running ?? Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        )
        let candidates = knownCallApps.filter { running.contains($0.bundleID) }
        guard hasAccessibilityPermission else { return candidates.first }
        return candidates.first { bestWindow(ofBundleID: $0.bundleID, purpose: .call) != nil }
    }

    // MARK: - Permission

    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    static func requestAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Session model

    enum CallTarget {
        case app(CallApp)
        case fake
        case none
    }

    enum ArrangeError: LocalizedError {
        case noPermission
        case noPlayerWindow(String)
        case noCallWindow(String)
        case noScreen
        case videoNotFullscreen
        case externalCallInFullscreen
        case fullscreenTimeout
        case couldNotMove(String)

        var errorDescription: String? {
            switch self {
            case .noPermission:
                return "Sofa needs Accessibility access to move windows."
            case .noPlayerWindow(let app):
                return "Couldn’t find a usable \(app) window — is your video open?"
            case .noCallWindow(let app):
                return "Couldn’t find a live \(app) call window. Open the call (or its pop-out) and try again."
            case .noScreen:
                return "Couldn’t read the screen containing the video."
            case .videoNotFullscreen:
                return "Put the video in full screen first (press F), then enter Theater."
            case .externalCallInFullscreen:
                return "This external call cannot join the video’s full-screen Space."
            case .fullscreenTimeout:
                return "The video did not finish leaving full screen. Try again once the animation stops."
            case .couldNotMove(let app):
                return "macOS would not place the \(app) window in Theater. Check Accessibility and try again."
            }
        }
    }

    private enum WindowPurpose { case player, call }

    private struct ManagedWindow {
        let element: AXUIElement
        let originalFrame: CGRect
        let name: String
        let wasFullscreen: Bool
    }

    private struct TheaterSession {
        let playerChoice: PlayerChoice
        let player: ManagedWindow
        let call: ManagedWindow?
        let fakeCallFrame: NSRect?
        let usesBrowserFullscreen: Bool
        let usesExistingPageFullscreen: Bool
        let browserToolbarWasAlwaysShown: Bool?
    }

    private struct Layout {
        let player: CGRect
        let call: CGRect?
        let fakeCall: NSRect?
    }

    private static var transitionToken: UUID?
    /// Every restoration owns a generation. Starting a new entrance advances
    /// it again, so delayed work from an older exit can never leave fullscreen
    /// or resize the new Theater session.
    private static var restoreGeneration: UInt64 = 0
    private static var restoringSession: (session: TheaterSession, generation: UInt64)?
    private static var pendingSession: TheaterSession?
    private static var activeSession: TheaterSession?

    /// Starts Theater asynchronously. Completion fires only after AX has read
    /// back the final frames and confirmed that both windows really moved.
    static func enterTheater(
        player: PlayerChoice,
        call: CallTarget,
        useBrowserFullscreenStage: Bool = false,
        browserPageFullscreen: Bool = false,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard hasAccessibilityPermission else {
            completion(.failure(ArrangeError.noPermission)); return
        }
        guard let playerBundle = player.bundleID,
              let initialPlayer = bestWindow(ofBundleID: playerBundle, purpose: .player),
              let initialPlayerFrame = axFrame(of: initialPlayer) else {
            completion(.failure(ArrangeError.noPlayerWindow(player.shortLabel))); return
        }
        // If the user exits and immediately re-enters, the previous Space may
        // still be animating. Inherit its true pre-Theater baseline instead of
        // mistaking that transient fullscreen/frame/toolbar state for user state.
        let inheritedSession: TheaterSession?
        if let restoring = restoringSession,
           restoring.generation == restoreGeneration,
           restoring.session.playerChoice == player,
           CFEqual(restoring.session.player.element, initialPlayer) {
            inheritedSession = restoring.session
        } else {
            inheritedSession = nil
        }
        let initialPlayerManaged = inheritedSession?.player ?? ManagedWindow(
            element: initialPlayer,
            originalFrame: initialPlayerFrame,
            name: player.shortLabel,
            wasFullscreen: isFullscreen(initialPlayer)
        )

        var initialCallManaged: ManagedWindow?
        if case .app(let app) = call {
            guard let window = bestWindow(ofBundleID: app.bundleID, purpose: .call),
                  let frame = axFrame(of: window) else {
                completion(.failure(ArrangeError.noCallWindow(app.name))); return
            }
            if let inheritedCall = inheritedSession?.call, CFEqual(inheritedCall.element, window) {
                initialCallManaged = inheritedCall
            } else {
                initialCallManaged = ManagedWindow(
                    element: window,
                    originalFrame: frame,
                    name: app.name,
                    wasFullscreen: isFullscreen(window)
                )
            }
        }

        cancelPendingTheater()
        restoreGeneration &+= 1
        restoringSession = nil
        let token = UUID()
        transitionToken = token

        let browser = player == .chrome || player == .safari
        // Browser Theater is an overlay on the page fullscreen the viewer
        // explicitly opened with F. Never fall through to the legacy desktop
        // layout or manufacture a replacement native fullscreen.
        if browser, (!useBrowserFullscreenStage || !browserPageFullscreen) {
            completion(.failure(ArrangeError.videoNotFullscreen)); return
        }
        if browser, !call.supportsOwnedFullscreenStage {
            completion(.failure(ArrangeError.externalCallInFullscreen)); return
        }
        if browser {
            guard let screen = screen(containingAXFrame: initialPlayerFrame) else {
                completion(.failure(ArrangeError.noScreen)); return
            }
            enterBrowserFullscreenStage(
                player: player,
                playerWindow: initialPlayer,
                playerBaseline: initialPlayerManaged,
                callBaseline: initialCallManaged,
                toolbarBaseline: inheritedSession?.browserToolbarWasAlwaysShown,
                fakeCallBaseline: inheritedSession?.fakeCallFrame,
                usesExistingPageFullscreen: browserPageFullscreen,
                screen: screen,
                call: call,
                token: token,
                completion: completion
            )
            return
        }

        let session = TheaterSession(
            playerChoice: player,
            player: initialPlayerManaged,
            call: initialCallManaged,
            fakeCallFrame: call.isFake ? (inheritedSession?.fakeCallFrame ?? FakeCall.shared.frame) : nil,
            usesBrowserFullscreen: false,
            usesExistingPageFullscreen: false,
            browserToolbarWasAlwaysShown: nil
        )
        pendingSession = session
        let windows = [session.player.element, session.call?.element].compactMap { $0 }
        let wasFullscreen = session.player.wasFullscreen || session.call?.wasFullscreen == true
        for window in windows where isFullscreen(window) {
            requestWindowed(window)
        }

        // Browser HTML fullscreen can report its AppleScript completion before
        // the macOS Space animation has fully settled. A stable-frame poll plus
        // this small not-before bound avoids racing that animation.
        let minimumWait: TimeInterval = wasFullscreen ? 1.0 : (browser ? 0.55 : 0.18)
        waitUntilWindowed(
            windows: windows,
            token: token,
            notBefore: Date().addingTimeInterval(minimumWait),
            deadline: Date().addingTimeInterval(5.0),
            lastFrame: nil,
            stableSamples: 0
        ) { result in
            guard transitionToken == token else { return }
            switch result {
            case .failure(let error):
                finishFailure(error, completion: completion)
            case .success:
                // Leaving a native full-screen Space reveals the app's real
                // saved desktop frame. Capture it before Theater resizes the
                // window so a later exit restores both state and geometry.
                let settledSession = sessionCapturingWindowedFrames(
                    session,
                    restorePlayerFullscreen: true
                )
                pendingSession = settledSession
                buildAndApplyLayout(
                    player: player,
                    call: call,
                    session: settledSession,
                    token: token,
                    completion: completion
                )
            }
        }
    }

    /// Cancels an entrance that is waiting on a Space/fullscreen transition.
    static func cancelPendingTheater() {
        transitionToken = nil
        TheaterBackdrop.shared.hide()
        if let pendingSession {
            restore(pendingSession)
            self.pendingSession = nil
        }
    }

    /// Leaves Theater and puts both windows back exactly where they were before
    /// the composition was applied.
    static func exitTheater() {
        cancelPendingTheater()
        TheaterBackdrop.shared.hide()
        if let activeSession {
            restore(activeSession)
            self.activeSession = nil
        }
    }

    static var theaterActive: Bool { activeSession != nil }
    /// Used during app termination so a just-started exit gets enough run-loop
    /// time to finish its delayed Space/frame restoration callbacks.
    static var restorationPending: Bool { restoringSession != nil }

    // MARK: - Transition and layout

    /// Safari/Chrome can provide a real macOS full-screen Space as long as every
    /// extra window belongs to Sofa. This covers the Test Zone today and the
    /// future Sofa-native call panel without exposing the menu bar, Dock or
    /// unrelated windows. Foreign call apps use the windowed path below.
    private static func enterBrowserFullscreenStage(
        player: PlayerChoice,
        playerWindow: AXUIElement,
        playerBaseline: ManagedWindow,
        callBaseline: ManagedWindow?,
        toolbarBaseline: Bool?,
        fakeCallBaseline: NSRect?,
        usesExistingPageFullscreen: Bool,
        screen: NSScreen,
        call: CallTarget,
        token: UUID,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let currentlyFullscreen = usesExistingPageFullscreen || isFullscreen(playerWindow)

        // A background browser can create its full-screen Space without moving
        // the user to it. Raise and activate the exact window first, then ask it
        // to enter fullscreen on the next run-loop beat.
        raise(playerWindow)
        if let bundleID = player.bundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate(options: [])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard transitionToken == token else { return }
            // Chromium only materializes its menu hierarchy while the app is
            // active, so capture the toolbar preference after activation.
            let toolbarWasAlwaysShown = usesExistingPageFullscreen
                ? nil
                : (toolbarBaseline ?? browserToolbarAlwaysShown(for: player))
            let session = TheaterSession(
                playerChoice: player,
                player: playerBaseline,
                call: callBaseline,
                fakeCallFrame: call.isFake ? (fakeCallBaseline ?? FakeCall.shared.frame) : nil,
                usesBrowserFullscreen: true,
                usesExistingPageFullscreen: usesExistingPageFullscreen,
                browserToolbarWasAlwaysShown: toolbarWasAlwaysShown
            )
            pendingSession = session

            if usesExistingPageFullscreen {
                // Netflix already owns a real HTML-fullscreen Space. Its DRM
                // player stays inside that element; only position Sofa's owned
                // call panel after the page layout has settled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard transitionToken == token else { return }
                    applyBrowserFullscreenStage(
                        screen: screen,
                        call: call,
                        session: session,
                        token: token,
                        attempt: 0,
                        completion: completion
                    )
                }
                return
            }

            if !currentlyFullscreen { requestFullscreen(playerWindow) }
            waitUntilFullscreen(
                window: playerWindow,
                token: token,
                notBefore: Date().addingTimeInterval(currentlyFullscreen ? 0.18 : 0.95),
                deadline: Date().addingTimeInterval(6.0)
            ) { result in
                guard transitionToken == token else { return }
                switch result {
                case .failure(let error):
                    finishFailure(error, completion: completion)
                case .success:
                    // The preference item is disabled outside full screen.
                    // Toggle only after the browser entered its Space.
                    if toolbarWasAlwaysShown == true {
                        setBrowserToolbarAlwaysShown(false, for: player)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                        applyBrowserFullscreenStage(
                            screen: screen,
                            call: call,
                            session: session,
                            token: token,
                            attempt: 0,
                            completion: completion
                        )
                    }
                }
            }
        }
    }

    private static func waitUntilFullscreen(
        window: AXUIElement,
        token: UUID,
        notBefore: Date,
        deadline: Date,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard transitionToken == token else { return }
        guard Date() < deadline else {
            completion(.failure(ArrangeError.fullscreenTimeout)); return
        }
        if isFullscreen(window), Date() >= notBefore {
            completion(.success(())); return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            waitUntilFullscreen(
                window: window,
                token: token,
                notBefore: notBefore,
                deadline: deadline,
                completion: completion
            )
        }
    }

    private static func applyBrowserFullscreenStage(
        screen: NSScreen,
        call: CallTarget,
        session: TheaterSession,
        token: UUID,
        attempt: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard transitionToken == token else { return }

        if call.isFake {
            if session.usesExistingPageFullscreen {
                FakeCall.shared.enterPageFullscreenOverlay(on: screen)
            } else {
                // Compatibility for older native-Space sessions. New browser
                // Theater is guarded above and always uses page fullscreen.
                let stage = axFrame(of: session.player.element)
                    .map { cocoaRect(fromAX: $0, on: screen) }
                    ?? screen.frame
                let width = min(460, max(340, stage.width * 0.26))
                let frame = NSRect(
                    x: stage.maxX - width,
                    y: stage.minY,
                    width: width,
                    height: stage.height
                )
                FakeCall.shared.enterFullscreenStage()
                FakeCall.shared.position(frame: frame)
            }
        }

        let realCallTarget: CGRect?
        if let realCall = session.call {
            let target = pageFullscreenCallFrame(
                on: screen,
                originalFrame: realCall.originalFrame
            )
            setAXFrame(realCall.element, target)
            raise(realCall.element)
            realCallTarget = target
        } else {
            realCallTarget = nil
        }

        // A panel can arrive one beat after the browser's Space transition.
        // Re-order it a few times, then declare the stage ready.
        if attempt < 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                applyBrowserFullscreenStage(
                    screen: screen,
                    call: call,
                    session: session,
                    token: token,
                    attempt: attempt + 1,
                    completion: completion
                )
            }
            return
        }

        if let realCall = session.call,
           let target = realCallTarget,
           !frame(of: realCall.element, matches: target) {
            finishFailure(ArrangeError.couldNotMove(realCall.name), completion: completion)
            return
        }

        pendingSession = nil
        activeSession = session
        transitionToken = nil
        completion(.success(()))
    }

    private static func waitUntilWindowed(
        windows: [AXUIElement],
        token: UUID,
        notBefore: Date,
        deadline: Date,
        lastFrame: CGRect?,
        stableSamples: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard transitionToken == token else { return }
        guard Date() < deadline else {
            completion(.failure(ArrangeError.fullscreenTimeout)); return
        }

        let allWindowed = windows.allSatisfy { !isFullscreen($0) }
        let frame = axFrame(of: windows[0])
        let frameStable = frame != nil && lastFrame.map { approximatelyEqual($0, frame!, tolerance: 3) } == true
        let samples = frameStable ? stableSamples + 1 : 0

        if allWindowed, Date() >= notBefore, samples >= 2 {
            completion(.success(())); return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            waitUntilWindowed(
                windows: windows,
                token: token,
                notBefore: notBefore,
                deadline: deadline,
                lastFrame: frame,
                stableSamples: samples,
                completion: completion
            )
        }
    }

    private static func buildAndApplyLayout(
        player: PlayerChoice,
        call: CallTarget,
        session: TheaterSession,
        token: UUID,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard transitionToken == token else { return }
        guard let playerFrame = axFrame(of: session.player.element) else {
            finishFailure(ArrangeError.noPlayerWindow(player.shortLabel), completion: completion)
            return
        }
        guard let screen = screen(containingAXFrame: playerFrame) else {
            finishFailure(ArrangeError.noScreen, completion: completion)
            return
        }

        let layout = makeLayout(
            on: screen,
            player: player,
            originalPlayerFrame: playerFrame,
            hasCall: !call.isNone
        )
        TheaterBackdrop.shared.show(on: screen)
        applyLayout(layout, session: session, token: token, attempt: 0, completion: completion)
    }

    private static func applyLayout(
        _ layout: Layout,
        session: TheaterSession,
        token: UUID,
        attempt: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard transitionToken == token else { return }

        setAXFrame(session.player.element, layout.player)
        if let call = session.call, let target = layout.call {
            setAXFrame(call.element, target)
        } else if let target = layout.fakeCall {
            FakeCall.shared.position(frame: target)
        }
        raise(session.player.element)
        if let call = session.call { raise(call.element) }

        // Window managers and minimum-size constraints can clamp the first AX
        // write while the previous resize is still landing. Reapply, then verify.
        if attempt < 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                applyLayout(layout, session: session, token: token, attempt: attempt + 1, completion: completion)
            }
            return
        }

        guard frame(of: session.player.element, matches: layout.player) else {
            finishFailure(ArrangeError.couldNotMove(session.player.name), completion: completion)
            return
        }
        if let call = session.call, let target = layout.call,
           !frame(of: call.element, matches: target) {
            finishFailure(ArrangeError.couldNotMove(call.name), completion: completion)
            return
        }

        pendingSession = nil
        activeSession = session
        transitionToken = nil
        completion(.success(()))
    }

    private static func finishFailure(_ error: Error, completion: (Result<Void, Error>) -> Void) {
        transitionToken = nil
        TheaterBackdrop.shared.hide()
        if let pendingSession {
            restore(pendingSession)
            self.pendingSession = nil
        }
        completion(.failure(error))
    }

    private static func restore(_ session: TheaterSession) {
        restoreGeneration &+= 1
        let generation = restoreGeneration
        restoringSession = (session, generation)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            guard restoringSession?.generation == generation else { return }
            restoringSession = nil
        }

        if session.usesBrowserFullscreen {
            FakeCall.shared.leaveFullscreenStage()
            if session.usesExistingPageFullscreen {
                // Cinema cleanup restores Netflix's own fullscreen tree; never
                // toggle the browser window or destroy the user's page fullscreen.
                if let call = session.call {
                    restoreManagedWindow(call, generation: generation)
                }
                if let frame = session.fakeCallFrame { FakeCall.shared.position(frame: frame) }
                return
            }
            if !session.player.wasFullscreen {
                let leaveFullscreen = {
                    guard restoreGeneration == generation else { return }
                    requestWindowed(session.player.element)
                    // Frame writes made during the Space animation are ignored
                    // by browsers, so reapply after it returns to the desktop.
                    for delay in [0.35, 0.85, 1.25] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            guard restoreGeneration == generation else { return }
                            if isFullscreen(session.player.element) {
                                requestWindowed(session.player.element)
                            } else {
                                setAXFrame(session.player.element, session.player.originalFrame)
                            }
                        }
                    }
                }
                let activateBrowser = {
                    if let bundleID = session.playerChoice.bundleID,
                       let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                        app.activate(options: [])
                    }
                }
                if session.browserToolbarWasAlwaysShown == true {
                    // Clicking Exit makes Sofa's panel key. Bring the browser
                    // back to the front so its full-screen-only menu command is
                    // enabled, restore the preference, then leave the Space.
                    activateBrowser()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        guard restoreGeneration == generation else { return }
                        setBrowserToolbarAlwaysShown(true, for: session.playerChoice)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
                            guard restoreGeneration == generation else { return }
                            leaveFullscreen()
                        }
                    }
                } else {
                    // AX fullscreen writes from a screen-saver-level Sofa panel
                    // can be ignored while Safari/Chrome is not the active app.
                    // Activate the exact browser window first, then leave its
                    // Space and keep the existing read-back retries below.
                    activateBrowser()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                        guard restoreGeneration == generation else { return }
                        leaveFullscreen()
                    }
                }
            } else if session.browserToolbarWasAlwaysShown == true {
                if let bundleID = session.playerChoice.bundleID,
                   let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                    app.activate(options: [])
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    guard restoreGeneration == generation else { return }
                    setBrowserToolbarAlwaysShown(true, for: session.playerChoice)
                }
            }
            if let call = session.call {
                restoreManagedWindow(call, generation: generation)
            }
            if let frame = session.fakeCallFrame { FakeCall.shared.position(frame: frame) }
            return
        }
        restoreManagedWindow(session.player, generation: generation)
        if let call = session.call { restoreManagedWindow(call, generation: generation) }
        if let frame = session.fakeCallFrame { FakeCall.shared.position(frame: frame) }
    }

    private static func restoreManagedWindow(_ window: ManagedWindow, generation: UInt64) {
        setAXFrame(window.element, window.originalFrame)
        if window.wasFullscreen {
            // Let the desktop-frame AX write land before beginning the Space
            // animation; otherwise macOS remembers Theater's split frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                guard restoreGeneration == generation else { return }
                requestFullscreen(window.element)
            }
        }
    }

    private static func sessionCapturingWindowedFrames(
        _ session: TheaterSession,
        restorePlayerFullscreen: Bool
    ) -> TheaterSession {
        func settled(_ window: ManagedWindow, restoreFullscreen: Bool) -> ManagedWindow {
            guard window.wasFullscreen else { return window }
            return ManagedWindow(
                element: window.element,
                originalFrame: axFrame(of: window.element) ?? window.originalFrame,
                name: window.name,
                wasFullscreen: restoreFullscreen
            )
        }
        return TheaterSession(
            playerChoice: session.playerChoice,
            player: settled(session.player, restoreFullscreen: restorePlayerFullscreen),
            call: session.call.map { settled($0, restoreFullscreen: true) },
            fakeCallFrame: session.fakeCallFrame,
            usesBrowserFullscreen: session.usesBrowserFullscreen,
            usesExistingPageFullscreen: session.usesExistingPageFullscreen,
            browserToolbarWasAlwaysShown: session.browserToolbarWasAlwaysShown
        )
    }

    private static func makeLayout(
        on screen: NSScreen,
        player: PlayerChoice,
        originalPlayerFrame: CGRect,
        hasCall: Bool
    ) -> Layout {
        let usable = visibleAXFrame(for: screen)
        let browser = player == .chrome || player == .safari
        let callFraction: CGFloat = browser ? 0.26 : 0.28
        let callWidth = hasCall ? min(460, max(340, usable.width * callFraction)) : 0
        // Third-party call apps cannot reliably join another application's
        // native full-screen Space, so that fallback uses flush desktop windows.
        let gap: CGFloat = hasCall && !browser ? 10 : 0
        let callRect: CGRect? = hasCall ? CGRect(
            x: usable.maxX - callWidth, y: usable.minY,
            width: callWidth, height: usable.height
        ) : nil
        let playerStage = CGRect(
            x: usable.minX, y: usable.minY,
            width: max(320, usable.width - callWidth - gap), height: usable.height
        )

        // QuickTime, VLC and TV preserve the movie's aspect ratio by constraining
        // their window. Ask for an aspect-fit frame up front instead of treating
        // that correct letterboxing as a failed AX resize. Browsers can fill the
        // whole stage because cinema CSS handles object-fit inside the window.
        let preserveWindowAspect = player == .quicktime || player == .vlc || player == .appleTV
        let playerRect: CGRect
        if preserveWindowAspect,
           originalPlayerFrame.width > 0, originalPlayerFrame.height > 0 {
            let ratio = originalPlayerFrame.width / originalPlayerFrame.height
            let stageRatio = playerStage.width / playerStage.height
            let size = stageRatio > ratio
                ? CGSize(width: playerStage.height * ratio, height: playerStage.height)
                : CGSize(width: playerStage.width, height: playerStage.width / ratio)
            playerRect = CGRect(
                x: playerStage.midX - size.width / 2,
                y: playerStage.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        } else {
            playerRect = playerStage
        }
        return Layout(
            player: playerRect,
            call: callRect,
            fakeCall: callRect.map { cocoaRect(fromAX: $0, on: screen) }
        )
    }

    // MARK: - Window selection

    private static func bestWindow(ofBundleID bundleID: String, purpose: WindowPurpose) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return nil
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let focused = elementAttribute(axApp, kAXFocusedWindowAttribute as String)
        let main = elementAttribute(axApp, kAXMainWindowAttribute as String)
        var candidates = elementArrayAttribute(axApp, kAXWindowsAttribute as String)
        for preferred in [focused, main].compactMap({ $0 }) where !candidates.contains(where: { CFEqual($0, preferred) }) {
            candidates.append(preferred)
        }

        return candidates
            .filter(isPlausibleWindow)
            .max { a, b in
                windowScore(a, purpose: purpose, focused: focused, main: main)
                    < windowScore(b, purpose: purpose, focused: focused, main: main)
            }
    }

    private static func isPlausibleWindow(_ window: AXUIElement) -> Bool {
        if boolAttribute(window, kAXMinimizedAttribute as String) == true { return false }
        guard let frame = axFrame(of: window), frame.width >= 220, frame.height >= 140 else { return false }
        let role = stringAttribute(window, kAXRoleAttribute as String)
        return role == nil || role == (kAXWindowRole as String)
    }

    private static func windowScore(
        _ window: AXUIElement,
        purpose: WindowPurpose,
        focused: AXUIElement?,
        main: AXUIElement?
    ) -> Double {
        let frame = axFrame(of: window) ?? .zero
        var score = Double(frame.width * frame.height)
        if let focused, CFEqual(window, focused) { score += 3_000_000 }
        if let main, CFEqual(window, main) { score += purpose == .player ? 2_000_000 : 500_000 }

        let title = stringAttribute(window, kAXTitleAttribute as String)?.lowercased() ?? ""
        if purpose == .call,
           ["call", "meeting", "zoom", "facetime", "stage", "conversation"].contains(where: title.contains) {
            score += 1_000_000
        }
        if ["settings", "preferences", "update", "launcher"].contains(where: title.contains) {
            score -= 2_000_000
        }
        return score
    }

    // MARK: - Fullscreen and AX plumbing

    private static let axFullScreen = "AXFullScreen" as CFString

    private static func isFullscreen(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, axFullScreen, &value) == .success else { return false }
        return (value as? Bool) == true
    }

    private static func requestWindowed(_ window: AXUIElement) {
        var settable = DarwinBoolean(false)
        let check = AXUIElementIsAttributeSettable(window, axFullScreen, &settable)
        if check == .success, settable.boolValue,
           AXUIElementSetAttributeValue(window, axFullScreen, kCFBooleanFalse) == .success {
            return
        }

        // Compatibility fallback for apps that expose fullscreen only through
        // their green title-bar button.
        if let button = elementAttribute(window, kAXFullScreenButtonAttribute as String) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    private static func requestFullscreen(_ window: AXUIElement) {
        var settable = DarwinBoolean(false)
        let check = AXUIElementIsAttributeSettable(window, axFullScreen, &settable)
        if check == .success, settable.boolValue,
           AXUIElementSetAttributeValue(window, axFullScreen, kCFBooleanTrue) == .success {
            return
        }

        if let button = elementAttribute(window, kAXFullScreenButtonAttribute as String) {
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    // MARK: - Browser chrome

    /// Safari and Chrome both have an "always show toolbar in full screen"
    /// preference. Theater temporarily disables it and restores the exact user
    /// setting on exit, so the Space contains the movie rather than browser UI.
    private static func browserToolbarAlwaysShown(for player: PlayerChoice) -> Bool? {
        guard let item = browserToolbarMenuItem(for: player) else { return nil }
        let mark = stringAttribute(item, kAXMenuItemMarkCharAttribute as String)
        return mark?.isEmpty == false
    }

    private static func setBrowserToolbarAlwaysShown(_ shown: Bool, for player: PlayerChoice) {
        guard let item = browserToolbarMenuItem(for: player) else { return }
        let current = stringAttribute(item, kAXMenuItemMarkCharAttribute as String)?.isEmpty == false
        if current != shown {
            AXUIElementPerformAction(item, kAXPressAction as CFString)
        }
    }

    private static func browserToolbarMenuItem(for player: PlayerChoice) -> AXUIElement? {
        guard let bundleID = player.bundleID,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return nil
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar = elementAttribute(axApp, kAXMenuBarAttribute as String) else { return nil }

        if player == .safari,
           let item = descendant(
               of: menuBar,
               identifier: "AlwaysShowToolbarInFullScreen",
               depth: 5
           ) {
            return item
        }

        // Chromium exposes the command with a generic identifier, so use only
        // semantic titles. Positional menu fallbacks are unsafe because a
        // browser update or extension can reorder the commands.
        let menuBarItems = elementArrayAttribute(menuBar, kAXChildrenAttribute as String)
        let viewItem = menuBarItems.first {
            stringAttribute($0, kAXTitleAttribute as String) == "View"
        }
        guard let viewItem,
              let menu = elementArrayAttribute(viewItem, kAXChildrenAttribute as String).first else {
            return nil
        }
        let items = elementArrayAttribute(menu, kAXChildrenAttribute as String).filter {
            stringAttribute($0, kAXRoleAttribute as String) == (kAXMenuItemRole as String)
        }
        return items.first { item in
            let title = stringAttribute(item, kAXTitleAttribute as String)?.lowercased() ?? ""
            return title.contains("toolbar") && title.contains("full screen")
        }
    }

    private static func descendant(
        of element: AXUIElement,
        identifier: String,
        depth: Int
    ) -> AXUIElement? {
        if stringAttribute(element, kAXIdentifierAttribute as String) == identifier { return element }
        guard depth > 0 else { return nil }
        for child in elementArrayAttribute(element, kAXChildrenAttribute as String) {
            if let match = descendant(of: child, identifier: identifier, depth: depth - 1) {
                return match
            }
        }
        return nil
    }

    private static func setAXFrame(_ window: AXUIElement, _ rect: CGRect) {
        var position = rect.origin
        var size = rect.size
        if let pos = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
        }
        if let size = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, size)
        }
        if let pos = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
        }
    }

    private static func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    private static func frame(of window: AXUIElement, matches target: CGRect) -> Bool {
        guard let actual = axFrame(of: window) else { return false }
        return approximatelyEqual(actual, target, tolerance: 42)
    }

    private static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance &&
        abs(a.minY - b.minY) <= tolerance &&
        abs(a.width - b.width) <= tolerance &&
        abs(a.height - b.height) <= tolerance
    }

    private static func axFrame(of window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = posRef, let sizeValue = sizeRef,
              CFGetTypeID(posValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func elementArrayAttribute(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let result = value as? [AXUIElement] else { return [] }
        return result
    }

    private static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: - Display geometry

    private static func displayBounds(for screen: NSScreen) -> CGRect? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
    }

    private static func screen(containingAXFrame frame: CGRect) -> NSScreen? {
        NSScreen.screens.max { a, b in
            let ai = displayBounds(for: a)?.intersection(frame).area ?? 0
            let bi = displayBounds(for: b)?.intersection(frame).area ?? 0
            return ai < bi
        }
    }

    private static func visibleAXFrame(for screen: NSScreen) -> CGRect {
        guard let display = displayBounds(for: screen) else { return screen.visibleFrame }
        let frame = screen.frame
        let visible = screen.visibleFrame
        return CGRect(
            x: display.minX + (visible.minX - frame.minX),
            y: display.minY + (frame.maxY - visible.maxY),
            width: visible.width,
            height: visible.height
        )
    }

    /// FaceTime's live-call window already opts into macOS full-screen Spaces.
    /// Accessibility can therefore place it inside the black column without
    /// leaving the browser's page fullscreen or duplicating/capturing the call.
    private static func pageFullscreenCallFrame(
        on screen: NSScreen,
        originalFrame: CGRect
    ) -> CGRect {
        let usable = visibleAXFrame(for: screen)
        let columnWidth = min(460, max(340, usable.width * 0.26))
        let inset: CGFloat = 8
        let available = CGSize(
            width: max(220, columnWidth - inset * 2),
            height: max(140, usable.height - inset * 2)
        )
        let ratio = originalFrame.width > 0 && originalFrame.height > 0
            ? originalFrame.width / originalFrame.height
            : 4.0 / 3.0
        var size = CGSize(width: available.width, height: available.width / ratio)
        if size.height > available.height {
            size.height = available.height
            size.width = available.height * ratio
        }
        return CGRect(
            x: usable.maxX - size.width - inset,
            y: usable.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func cocoaRect(fromAX rect: CGRect, on screen: NSScreen) -> NSRect {
        guard let display = displayBounds(for: screen) else { return rect }
        let localX = rect.minX - display.minX
        let localY = rect.minY - display.minY
        return NSRect(
            x: screen.frame.minX + localX,
            y: screen.frame.maxY - localY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}

private extension WindowArranger.CallTarget {
    var isNone: Bool {
        if case .none = self { return true }
        return false
    }

    var isFake: Bool {
        if case .fake = self { return true }
        return false
    }

    var supportsOwnedFullscreenStage: Bool {
        switch self {
        case .app(let app):
            // FaceTime's call/PiP window is a full-screen auxiliary window and
            // can be raised and resized while Safari/Chrome owns the Space.
            return app.bundleID == "com.apple.FaceTime"
        case .fake, .none:
            return true
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull || isInfinite ? 0 : max(0, width) * max(0, height) }
}

/// Black curtain above desktop icons but below ordinary app windows. Keeping it
/// out of `.normal` ordering prevents it from ever covering the movie or call.
@MainActor
final class TheaterBackdrop {
    static let shared = TheaterBackdrop()
    private var window: NSWindow?

    func show(on screen: NSScreen) {
        hide()
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false

        let hint = NSTextField(labelWithString: "Theater — open Sofa in the menu bar to exit")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor.white.withAlphaComponent(0.22)
        hint.sizeToFit()
        hint.frame.origin = NSPoint(x: 20, y: 16)
        window.contentView?.addSubview(hint)

        window.orderFront(nil)
        self.window = window
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}
