import AppKit
import SwiftUI

/// A pretend FaceTime window for Test Zone, so Theater mode can be tried
/// without a real call. It's our own window, so Theater positions it directly —
/// no Accessibility permission needed for this half of the layout.
@MainActor
final class FakeCall: ObservableObject {
    static let shared = FakeCall()

    @Published var visible = false
    private var window: NSPanel?

    func toggle() {
        visible ? hide() : show()
    }

    func show() {
        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered, defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating          // above the theater backdrop
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: FakeCallView())
            window = panel
        }
        // First appearance: park it roughly where Theater would put it.
        if let screen = NSScreen.main, let window {
            let v = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: v.maxX - 320 - 8, y: v.midY - 210))
        }
        window?.orderFront(nil)
        visible = true
    }

    func hide() {
        window?.orderOut(nil)
        visible = false
    }

    /// Theater layout drops the call column here (native bottom-left coords).
    func position(frame: NSRect) {
        window?.setFrame(frame, display: true)
        window?.orderFront(nil)
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
