import AppKit
import SwiftUI
import CollectorEngine

/// The notch as an interaction zone, not a display — nothing can render inside
/// the physical cutout, and anything visible around it is a black blob over the
/// user's windows. Three modes:
/// - collapsed: an INVISIBLE hover target exactly covering the notch dead zone
/// - alert: the notification banner, taking over the surface briefly
/// - expanded: the full fleet panel, flowing out of the notch on hover
@MainActor
@Observable
final class NotchSurfaceState {
    enum Mode: Equatable {
        case collapsed
        case alert(CollectorEngine.Alert)
        case expanded
    }

    var mode: Mode = .collapsed
}

@MainActor
final class NotchSurface {
    private let state = NotchSurfaceState()
    private var panel: NSPanel?
    private var queue: [CollectorEngine.Alert] = []
    private weak var model: FleetModel?

    var canShow: Bool { notchScreen != nil }

    /// Hover-to-expand availability; alerts show regardless. Persisted in AppState.
    var hudEnabled = true {
        didSet { applyVisibility() }
    }

    private func applyVisibility() {
        guard let panel else { return }
        let ambientVisible = hudEnabled || state.mode != .collapsed
        if ambientVisible {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private var notchScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    func attach(model: FleetModel) {
        self.model = model
        guard canShow, panel == nil else { return }
        let panel = makePanel()
        panel.contentView = NSHostingView(rootView: NotchRoot(
            state: state,
            model: model,
            onHoverChange: { [weak self] inside in self?.hoverChanged(inside) },
            onAlertDone: { [weak self] in self?.alertFinished() }
        ))
        self.panel = panel
        applyFrame()
        applyVisibility()
    }

    func show(_ alert: CollectorEngine.Alert) {
        guard canShow else { return }
        if case .alert = state.mode {
            queue.append(alert)
        } else {
            state.mode = .alert(alert)
            applyFrame()
            applyVisibility()
        }
    }

    private func alertFinished() {
        if !queue.isEmpty {
            state.mode = .alert(queue.removeFirst())
        } else {
            state.mode = .collapsed
        }
        applyFrame()
        applyVisibility()
    }

    private func hoverChanged(_ inside: Bool) {
        if case .alert = state.mode { return }
        let target: NotchSurfaceState.Mode = inside ? .expanded : .collapsed
        guard state.mode != target else { return }
        state.mode = target
        applyFrame()
    }

    private func applyFrame() {
        guard let panel, let screen = notchScreen else { return }
        let notch = notchGeometry(of: screen)
        // Collapsed is an INVISIBLE hover target exactly matching the notch dead
        // zone — the physical cutout has no pixels and takes no clicks, so a
        // panel there has zero visual or interaction footprint.
        let size: NSSize = switch state.mode {
        case .collapsed: NSSize(width: notch.width, height: notch.height)
        case .alert: NSSize(width: 560, height: 130)
        case .expanded: NSSize(width: 510, height: 640)
        }
        panel.setFrame(
            NSRect(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.maxY - size.height,
                width: size.width, height: size.height
            ),
            display: true
        )
    }

    private func notchGeometry(of screen: NSScreen) -> (width: CGFloat, height: CGFloat) {
        let height = screen.safeAreaInsets.top
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return (screen.frame.width - left.width - right.width, height)
        }
        return (200, height)
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
        panel.ignoresMouseEvents = false
        return panel
    }
}

private struct NotchRoot: View {
    let state: NotchSurfaceState
    let model: FleetModel
    let onHoverChange: (Bool) -> Void
    let onAlertDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch state.mode {
            case .collapsed:
                // Invisible hover target over the notch dead zone.
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
            case .alert(let alert):
                AlertCard(alert: alert, dismiss: onAlertDone)
            case .expanded:
                FleetView(model: model)
                    .background(
                        UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18)
                            .fill(.black)
                    )
            }
            Spacer(minLength: 0)
        }
        .onHover(perform: onHoverChange)
    }
}

/// The notification takeover, mascot and all.
private struct AlertCard: View {
    let alert: CollectorEngine.Alert
    let dismiss: () -> Void
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 14) {
            BannerMascot()
            VStack(alignment: .leading, spacing: 3) {
                Text(alert.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(alert.body)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 38)
        .padding(.bottom, 18)
        .frame(width: 560, alignment: .leading)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22)
                .fill(.black)
        )
        .offset(y: revealed ? 0 : -140)
        .opacity(revealed ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
                revealed = true
            }
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
