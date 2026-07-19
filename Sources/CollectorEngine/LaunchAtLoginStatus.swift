public enum LaunchAtLoginStatus: Sendable {
    case unavailable
    case disabled
    case pendingApproval
    case enabled

    public var canManage: Bool {
        self != .unavailable
    }

    public var isRegistered: Bool {
        switch self {
        case .pendingApproval, .enabled: true
        case .unavailable, .disabled: false
        }
    }

}
