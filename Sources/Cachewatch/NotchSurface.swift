import AppKit
import SwiftUI
import CollectorEngine

/// The persistent notch presence. One always-on panel with three modes:
/// - collapsed: black wings flanking the physical notch, ambient stats
/// - alert: the notification banner, taking over the surface briefly
/// - expanded: the full fleet panel, on hover
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

    /// Ambient pill visibility; alerts show regardless. Persisted in AppState.
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

    /// Height of the ambient strip hanging below the physical notch.
    static let pillHeight: CGFloat = 22

    private func applyFrame() {
        guard let panel, let screen = notchScreen else { return }
        let notch = notchGeometry(of: screen)
        // Collapsed stays within the notch's own width: nothing clickable lives
        // under the camera housing, so the pill can never block menu items.
        let size: NSSize = switch state.mode {
        case .collapsed: NSSize(width: notch.width, height: notch.height + Self.pillHeight)
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
                UnderNotchPill(fleet: model.fleet)
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

/// Minimal ambient strip hanging just below the physical notch: mascot, 5h
/// quota, and status dots — never wider than the notch itself.
private struct UnderNotchPill: View {
    let fleet: FleetSnapshot

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(spacing: 0) {
                Spacer(minLength: 0)  // the notch band itself: physically invisible
                HStack(spacing: 8) {
                    if let icon = MascotIcon.image {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                    }
                    if let used = fleet.rateLimits?.fiveHour?.usedPercentage {
                        Text("\(Int(used))%")
                            .foregroundStyle(used >= 80 ? .red : used >= 60 ? .orange : .white.opacity(0.85))
                    }
                    counter(fleet.sessions.count { $0.status == .busy }, .green)
                    counter(fleet.sessions.count { $0.status == .waiting }, .orange)
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .frame(height: NotchSurface.pillHeight)
            }
            .frame(maxWidth: .infinity)
            .background(
                UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12)
                    .fill(.black)
            )
        }
    }

    @ViewBuilder
    private func counter(_ count: Int, _ color: Color) -> some View {
        if count > 0 {
            HStack(spacing: 3) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text("\(count)").foregroundStyle(.white.opacity(0.85))
            }
        }
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
