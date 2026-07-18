import Foundation

enum StatusItemFormatter {
    static func compactValue(for window: UsageWindow) -> String {
        guard let used = window.usedPercentage else {
            return "--"
        }
        return String(Int(used.rounded()))
    }

    static func compactRemainingValue(for window: UsageWindow) -> String {
        guard let used = window.usedPercentage else {
            return "--"
        }
        let remaining = max(0, 100 - used)
        return String(Int(remaining.rounded()))
    }

    /// Compact "5h/week" (or just "week" when there is no 5h window) using the
    /// windows the provider actually reports. Model-scoped windows (e.g. Fable)
    /// are intentionally omitted from the compact label; they live in the
    /// popover only.
    static func compactPair(for snapshot: ProviderSnapshot, remaining: Bool) -> String {
        let parts = [snapshot.fiveHourWindow, snapshot.weeklyWindow].compactMap { window -> String? in
            guard let window else {
                return nil
            }
            return remaining ? compactRemainingValue(for: window) : compactValue(for: window)
        }
        return parts.isEmpty ? "--" : parts.joined(separator: "/")
    }

    static func text(prefix: String, snapshot: ProviderSnapshot, mode: MenuBarDisplayMode) -> String {
        switch mode {
        case .usage:
            return "\(prefix) \(compactPair(for: snapshot, remaining: false))"
        case .remaining:
            return "\(prefix) \(compactPair(for: snapshot, remaining: true))"
        case .insight:
            let insight = WeeklyPacing.formattedDelta(for: snapshot.weekly) ?? "--"
            return "\(prefix) \(insight)"
        case .usageAndInsight:
            let usage = compactPair(for: snapshot, remaining: false)
            let insight = WeeklyPacing.formattedDelta(for: snapshot.weekly) ?? "--"
            return "\(prefix) \(usage) \(insight)"
        case .remainingAndInsight:
            let remaining = compactPair(for: snapshot, remaining: true)
            let insight = WeeklyPacing.formattedDelta(for: snapshot.weekly) ?? "--"
            return "\(prefix) \(remaining) \(insight)"
        }
    }
}
