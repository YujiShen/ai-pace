import Foundation

enum ProviderKind: String {
    case claude = "Claude"
    case codex = "Codex"
}

enum ProviderDisplayName {
    static let maxLength = 7
    static let customClaudeNameDefaultsKey = "customClaudeName"
    static let customCodexNameDefaultsKey = "customCodexName"

    static func defaultsKey(for provider: ProviderKind) -> String {
        switch provider {
        case .claude:
            return customClaudeNameDefaultsKey
        case .codex:
            return customCodexNameDefaultsKey
        }
    }

    static func defaultName(for provider: ProviderKind) -> String {
        switch provider {
        case .claude:
            return "Cl"
        case .codex:
            return "Cx"
        }
    }

    static func sanitizedInput(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
    }

    static func displayName(
        for provider: ProviderKind,
        customName: String? = nil,
        userDefaults: UserDefaults = .standard
    ) -> String {
        let storedName = customName ?? userDefaults.string(forKey: defaultsKey(for: provider)) ?? ""
        let sanitizedName = sanitizedInput(storedName)
        return sanitizedName.isEmpty ? defaultName(for: provider) : sanitizedName
    }
}

enum UsageWindowKind: Hashable, Sendable {
    case fiveHour
    case weekly
    /// A model-scoped window (e.g. a per-model weekly cap like "Fable"), keyed
    /// by the model's display name. These appear only while the provider
    /// actually reports them.
    case scoped(String)

    /// Stable identifier used for notification storage keys and view identity.
    /// Kept as "5h"/"week" for the primary windows so existing persisted
    /// notification preferences survive the dynamic-window change.
    var storageKey: String {
        switch self {
        case .fiveHour:
            return "5h"
        case .weekly:
            return "week"
        case .scoped(let name):
            return "scoped-\(name.lowercased())"
        }
    }

    /// Human-facing label used where a window kind is shown verbatim
    /// (notifications). Localized rendering lives in `Loc.windowLabel`.
    var displayLabel: String {
        switch self {
        case .fiveHour:
            return "5h"
        case .weekly:
            return "Week"
        case .scoped(let name):
            return name
        }
    }
}

enum AgentAvailability: Equatable {
    case loading
    case available
    case missingAuth
    case accessDenied
    case sessionExpired
    case notInstalled
    case notLoggedIn
    case error(String)

    var showsInPopover: Bool {
        switch self {
        case .loading, .available:
            return true
        case .missingAuth, .accessDenied, .sessionExpired, .notInstalled, .notLoggedIn, .error:
            return false
        }
    }
}

struct AgentStatus: Equatable {
    let provider: ProviderKind
    let availability: AgentAvailability
    let message: String?
}

enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case usage
    case remaining
    case insight
    case usageAndInsight
    case remainingAndInsight

    var id: String { rawValue }
}

enum PopoverDisplayMode: String, CaseIterable, Identifiable {
    case usage
    case remaining

    var id: String { rawValue }
}

enum AutoRefreshInterval: Int, CaseIterable, Identifiable {
    case manual = 0
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300
    case tenMinutes = 600
    case fifteenMinutes = 900
    case thirtyMinutes = 1800

    var id: Int { rawValue }

    var duration: TimeInterval { TimeInterval(rawValue) }

    var label: String {
        switch self {
        case .manual:
            return "Manual"
        case .oneMinute:
            return "1 minute"
        case .twoMinutes:
            return "2 minutes"
        case .fiveMinutes:
            return "5 minutes"
        case .tenMinutes:
            return "10 minutes"
        case .fifteenMinutes:
            return "15 minutes"
        case .thirtyMinutes:
            return "30 minutes"
        }
    }

    static let defaultValue: AutoRefreshInterval = .fiveMinutes
}

enum NotificationSoundOption: String, CaseIterable, Identifiable {
    case systemDefault
    case glass
    case hero
    case purr
    case frog
    case bottle
    case submarine
    case silent

    var id: String { rawValue }

    var soundName: String? {
        switch self {
        case .systemDefault, .silent:
            return nil
        case .glass:
            return "Glass"
        case .hero:
            return "Hero"
        case .purr:
            return "Purr"
        case .frog:
            return "Frog"
        case .bottle:
            return "Bottle"
        case .submarine:
            return "Submarine"
        }
    }
}

enum LaunchAtStartupState: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case unsupported
}

struct UsageWindowKey: Hashable, Sendable {
    let provider: ProviderKind
    let kind: UsageWindowKind

    var storageKey: String {
        "\(provider.rawValue.lowercased())-\(kind.storageKey)"
    }
}

struct UsageWindow: Identifiable {
    let kind: UsageWindowKind
    var usedPercentage: Double?
    var resetsAt: Date?
    var message: String?

    var id: String { kind.storageKey }

    static func placeholder(_ kind: UsageWindowKind, message: String = "Loading…") -> UsageWindow {
        UsageWindow(kind: kind, usedPercentage: nil, resetsAt: nil, message: message)
    }
}

/// One account within a provider (used for Codex multi-account). The active
/// account's `windows` are also promoted to the snapshot's top-level `windows`
/// so the menu-bar label and single-account code paths stay unchanged.
struct ProviderAccount: Identifiable {
    let id: String
    let name: String?
    let active: Bool
    let detail: String?
    var windows: [UsageWindow]

    /// The window to show on the account's single row (prefers weekly, which is
    /// currently the only Codex window).
    var primaryWindow: UsageWindow? {
        windows.first { $0.kind == .weekly } ?? windows.first
    }
}

struct ProviderSnapshot {
    let provider: ProviderKind
    /// The windows the provider currently reports, in display order. A window
    /// is present only when the provider actually returns it, so absent
    /// windows (e.g. Codex's retired 5h) simply do not appear. For a
    /// multi-account provider these mirror the active account's windows.
    var windows: [UsageWindow]
    var detail: String?
    /// Populated only for multi-account providers (Codex via cma); empty for
    /// single-account providers, which render `windows` directly.
    var accounts: [ProviderAccount]

    init(
        provider: ProviderKind,
        windows: [UsageWindow],
        detail: String?,
        accounts: [ProviderAccount] = []
    ) {
        self.provider = provider
        self.windows = windows
        self.detail = detail
        self.accounts = accounts
    }

    /// Back-compat initializer for the fixed 5h + weekly shape. Retained so
    /// existing call sites and tests keep constructing both primary windows.
    init(provider: ProviderKind, fiveHour: UsageWindow, weekly: UsageWindow, detail: String?) {
        self.init(provider: provider, windows: [fiveHour, weekly], detail: detail)
    }

    /// The 5h window if the provider currently reports one.
    var fiveHourWindow: UsageWindow? { windows.first { $0.kind == .fiveHour } }
    /// The weekly window if the provider currently reports one.
    var weeklyWindow: UsageWindow? { windows.first { $0.kind == .weekly } }

    /// Non-optional accessors that read an absent window as empty. Convenient
    /// for consumers (insight, status derivation) that tolerate missing data;
    /// presentation code that must hide absent windows iterates `windows`.
    var fiveHour: UsageWindow {
        fiveHourWindow ?? UsageWindow(kind: .fiveHour, usedPercentage: nil, resetsAt: nil, message: nil)
    }
    var weekly: UsageWindow {
        weeklyWindow ?? UsageWindow(kind: .weekly, usedPercentage: nil, resetsAt: nil, message: nil)
    }

    static func loading(_ provider: ProviderKind) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            fiveHour: .placeholder(.fiveHour),
            weekly: .placeholder(.weekly),
            detail: nil
        )
    }
}

enum WeeklyPacing {
    static func delta(for window: UsageWindow, now: Date = .now) -> Double? {
        guard window.kind == .weekly,
              let used = window.usedPercentage,
              let resetsAt = window.resetsAt else {
            return nil
        }

        let totalWeeklyWindow: TimeInterval = 7 * 24 * 60 * 60
        let timeRemaining = min(max(resetsAt.timeIntervalSince(now) / totalWeeklyWindow * 100, 0), 100)
        let usageRemaining = min(max(100 - used, 0), 100)
        return usageRemaining - timeRemaining
    }

    static func formattedDelta(for window: UsageWindow, now: Date = .now) -> String? {
        guard let delta = delta(for: window, now: now) else {
            return nil
        }

        let roundedDelta = delta.rounded()
        if abs(roundedDelta) < 0.5 {
            return "0%"
        }
        return String(format: "%+.0f%%", roundedDelta)
    }
}
