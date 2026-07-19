import AppKit
import SwiftUI
import CollectorEngine

/// Shows alerts as a banner flowing out from behind the notch: slides down,
/// dwells, retracts. Falls back to nothing when no notch screen exists
/// (clamshell/external-only) — the caller keeps its osascript path for that.
@MainActor
final class NotchNotifier {
    private var panel: NSPanel?
    private var queue: [CollectorEngine.Alert] = []
    private var showing = false

    /// True when a banner can be shown on this display setup.
    var canShow: Bool { notchScreen != nil }

    func show(_ alert: CollectorEngine.Alert) {
        queue.append(alert)
        showNextIfIdle()
    }

    private var notchScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    private func showNextIfIdle() {
        guard !showing, !queue.isEmpty, let screen = notchScreen else { return }
        showing = true
        let alert = queue.removeFirst()

        let size = NSSize(width: 440, height: 96)
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width, height: size.height
        )
        let panel = self.panel ?? makePanel()
        panel.setFrame(frame, display: false)
        panel.contentView = NSHostingView(rootView: NotchBanner(alert: alert) { [weak self] in
            Task { @MainActor in
                panel.orderOut(nil)
                self?.showing = false
                self?.showNextIfIdle()
            }
        })
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        self.panel = panel
        return panel
    }
}

/// The banner itself: emerges from under the notch, breathes, retracts.
private struct NotchBanner: View {
    let alert: CollectorEngine.Alert
    let dismiss: () -> Void

    @State private var revealed = false
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "sparkle")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .scaleEffect(pulse ? 1.15 : 0.95)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
                VStack(alignment: .leading, spacing: 2) {
                    Text(alert.title)
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(alert.body)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 34)   // clears the physical notch band
            .padding(.bottom, 14)
            .frame(width: 440, alignment: .leading)
            .background(
                UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22)
                    .fill(.black)
            )
            .offset(y: revealed ? 0 : -110)
            .opacity(revealed ? 1 : 0)
            Spacer(minLength: 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                revealed = true
            }
            pulse = true
            Task {
                try? await Task.sleep(for: .seconds(5))
                withAnimation(.easeIn(duration: 0.35)) {
                    revealed = false
                }
                try? await Task.sleep(for: .seconds(0.4))
                dismiss()
            }
        }
    }
}
