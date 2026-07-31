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
final class NotchSurface: NSObject {
    private let state = NotchSurfaceState()
    private var panel: NSPanel?
    private var presentationQueue = AlertPresentationQueue()
    private var presentationDisplay = AlertPresentationDisplay()
    private var dismissalTask: Task<Void, Never>?
    private weak var model: FleetModel?
    var onPresentationUnavailable: (([CollectorEngine.Alert]) -> Void)?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Hover-to-expand availability; alerts show regardless. Persisted in AppState.
    var hudEnabled = false {
        didSet { applyVisibility() }
    }

    private func applyVisibility() {
        guard let panel else { return }
        let ambientVisible = AlertSurfaceVisibility.shouldOrderFront(
            hasNotchedScreen: anyNotchScreen != nil,
            hudEnabled: hudEnabled,
            hasTransientContent: state.mode != .collapsed
        )
        // Alerts are informational and have no controls. Let clicks pass through
        // even while the banner is animating over another app.
        let isInformationalAlert: Bool
        if case .alert = state.mode {
            isInformationalAlert = true
        } else {
            isInformationalAlert = false
        }
        panel.ignoresMouseEvents = AlertSurfaceInteraction.shouldIgnoreMouseEvents(
            isInformationalAlert: isInformationalAlert
        )
        if ambientVisible {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private var anyNotchScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    private func displayID(_ screen: NSScreen) -> Int? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue
    }

    private var connectedDisplays: [AlertDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let id = displayID(screen) else { return nil }
            return AlertDisplay(id: id, hasNotch: screen.safeAreaInsets.top > 0)
        }
    }

    private func screen(withID id: Int) -> NSScreen? {
        NSScreen.screens.first { displayID($0) == id }
    }

    private var interactionScreen: NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
    }

    /// Custom alerts belong only on the display containing the pointer. Unlike
    /// NSScreen.main, this remains meaningful for a background menu-bar app.
    /// If the active display has no notch, native macOS notifications are used.
    private var activeNotchScreen: NSScreen? {
        guard let screen = interactionScreen,
              AlertDisplayPolicy.customSurfaceTarget(
                activeDisplayID: displayID(screen), connectedDisplays: connectedDisplays
              ) != nil
        else { return nil }
        return screen
    }

    private var presentationScreen: NSScreen? {
        guard let target = presentationDisplay.connectedTarget(in: connectedDisplays) else { return nil }
        return screen(withID: target.id)
    }

    func attach(model: FleetModel) {
        self.model = model
        reconcilePanel()
    }

    @discardableResult
    private func ensurePanel() -> Bool {
        guard panel == nil else { return true }
        guard let model, anyNotchScreen != nil else { return false }
        let panel = makePanel()
        panel.contentView = NSHostingView(rootView: NotchRoot(
            state: state,
            model: model,
            onHoverChange: { [weak self] inside in self?.hoverChanged(inside) }
        ))
        self.panel = panel
        applyFrame()
        applyVisibility()
        return true
    }

    /// Returns true only after a real panel on the active notched screen accepts
    /// the alert. Callers must fall back to native delivery when this is false.
    func show(_ alert: CollectorEngine.Alert) -> Bool {
        guard let screen = activeNotchScreen,
              let screenID = displayID(screen),
              ensurePanel()
        else { return false }
        if let first = presentationQueue.enqueue(alert) {
            presentationDisplay.accept(displayID: screenID)
            present(first)
        }
        return true
    }

    private func alertFinished() {
        guard let next = presentationQueue.advance() else {
            collapse()
            return
        }
        guard presentationScreen != nil else {
            fallBackToSystemNotifications()
            return
        }
        present(next)
    }

    private func present(_ alert: CollectorEngine.Alert) {
        dismissalTask?.cancel()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
            state.mode = .alert(alert)
        }
        applyFrame()
        applyVisibility()
        dismissalTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.alertFinished()
        }
    }

    private func collapse() {
        dismissalTask?.cancel()
        dismissalTask = nil
        withAnimation(.easeIn(duration: 0.35)) {
            state.mode = .collapsed
        }
        presentationDisplay.clear()
        applyFrame()
        applyVisibility()
    }

    private func fallBackToSystemNotifications() {
        dismissalTask?.cancel()
        dismissalTask = nil
        let alerts = presentationQueue.drain()
        state.mode = .collapsed
        presentationDisplay.clear()
        applyFrame()
        applyVisibility()
        if !alerts.isEmpty {
            onPresentationUnavailable?(alerts)
        }
    }

    @objc private func screenParametersDidChange() {
        if presentationQueue.current != nil, presentationScreen == nil {
            fallBackToSystemNotifications()
        } else {
            reconcilePanel()
        }
    }

    private func reconcilePanel() {
        guard anyNotchScreen != nil else {
            if AlertSurfaceVisibility.shouldCollapseTransientState(
                hasNotchedScreen: false,
                isExpanded: state.mode == .expanded
            ) {
                state.mode = .collapsed
            }
            panel?.orderOut(nil)
            return
        }
        guard ensurePanel() else { return }
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
        let screen: NSScreen? = if case .alert = state.mode {
            presentationScreen
        } else {
            anyNotchScreen
        }
        guard let panel, let screen else { return }
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

    var body: some View {
        VStack(spacing: 0) {
            switch state.mode {
            case .collapsed:
                // Invisible hover target over the notch dead zone.
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
            case .alert(let alert):
                AlertCard(alert: alert)
                    .id(alert.key)
                    .transition(.move(edge: .top).combined(with: .opacity))
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
    }
}
