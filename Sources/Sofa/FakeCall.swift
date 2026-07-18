import AppKit
import SwiftUI

/// A pretend FaceTime window for Test Zone, so Theater mode can be tried
/// without a real call. It's our own window, so Theater positions it directly —
/// no Accessibility permission needed for this half of the layout.
@MainActor
final class FakeCall: ObservableObject {
    static let shared = FakeCall()

    private static let normalWidth: CGFloat = 320
    private static let theaterWidth: CGFloat = 240
    private static let callHeight: CGFloat = 420

    @Published var visible = false
    private var window: NSPanel?

    func toggle() {
        visible ? hide() : show()
    }

    func show() {
        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(
                    x: 0,
                    y: 0,
                    width: Self.normalWidth,
                    height: Self.callHeight
                ),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered, defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [
                .canJoinAllApplications,
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .stationary,
                .ignoresCycle,
            ]
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: FakeCallView())
            window = panel
        }
        // First appearance: park it roughly where Theater would put it.
        if let screen = NSScreen.main, let window {
            let v = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: v.maxX - Self.normalWidth - 8,
                y: v.midY - Self.callHeight / 2
            ))
        }
        window?.orderFrontRegardless()
        visible = true
    }

    func hide() {
        window?.orderOut(nil)
        window?.level = .floating
        visible = false
    }

    /// The browser already owns the fullscreen Space because the viewer pressed
    /// F. Use a narrower call panel in Theater so the movie can be expanded
    /// farther right while the call remains fully outside the video.
    func enterPageFullscreenOverlay(on screen: NSScreen) {
        show()
        guard let window else { return }
        let visibleFrame = screen.visibleFrame
        let frame = NSRect(
            x: visibleFrame.maxX - Self.theaterWidth - 8,
            y: visibleFrame.midY - Self.callHeight / 2,
            width: Self.theaterWidth,
            height: Self.callHeight
        )
        window.level = .floating
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
    }

    /// Native browser full screen lives in its own Space. Temporarily raise the
    /// Sofa-owned call surface above that Space, then return it to an ordinary
    /// floating panel when Theater exits.
    func enterFullscreenStage() {
        guard let window else { return }
        window.level = .screenSaver
        window.orderFrontRegardless()
    }

    func leaveFullscreenStage() {
        guard let window else { return }
        window.level = .floating
        if visible { window.orderFrontRegardless() }
    }

    /// Saved by Theater so leaving the mode restores the rehearsal window too.
    var frame: NSRect? { window?.frame }

    /// Theater layout drops the call column here (native bottom-left coords).
    func position(frame: NSRect) {
        window?.setFrame(frame, display: true)
        window?.orderFrontRegardless()
    }
}

/// Looks enough like a FaceTime tile to make Theater rehearsals feel real.
private struct FakeCallView: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.13, green: 0.14, blue: 0.19),
                                    Color(red: 0.05, green: 0.05, blue: 0.08)],
                           startPoint: .top, endPoint: .bottom)

            VStack(spacing: 12) {
                Spacer()
                AvatarView(name: "Test Friend", size: 72)
                Text("Test Friend")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Sofa test call")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()

                HStack(spacing: 18) {
                    ForEach(["mic.slash.fill", "video.fill", "phone.down.fill"], id: \.self) { symbol in
                        Image(systemName: symbol)
                            .font(.system(size: 15))
                            .foregroundStyle(symbol == "phone.down.fill" ? .white : .white.opacity(0.8))
                            .frame(width: 40, height: 40)
                            .background(
                                symbol == "phone.down.fill"
                                    ? Color.red.opacity(0.85)
                                    : Color.white.opacity(0.14),
                                in: Circle()
                            )
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1)))
    }
}
