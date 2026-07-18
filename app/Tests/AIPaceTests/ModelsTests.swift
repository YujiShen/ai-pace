import Foundation
import Testing
@testable import AIPace

struct ModelsTests {
    @Test
    func weeklyPacingCalculatesDeltaAndFormattedValue() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let reset = now.addingTimeInterval(3.5 * 24 * 60 * 60)
        let window = makeWindow(.weekly, used: 40, resetsAt: reset)

        #expect(abs((WeeklyPacing.delta(for: window, now: now) ?? 0) - 10) < 0.001)
        #expect(WeeklyPacing.formattedDelta(for: window, now: now) == "+10%")
    }

    @Test
    func weeklyPacingReturnsNilForNonWeeklyWindows() {
        let window = makeWindow(.fiveHour, used: 50, resetsAt: Date())

        #expect(WeeklyPacing.delta(for: window) == nil)
        #expect(WeeklyPacing.formattedDelta(for: window) == nil)
    }

    @Test
    func usageWindowKeyBuildsStableStorageKey() {
        let key = UsageWindowKey(provider: .codex, kind: .weekly)

        #expect(key.storageKey == "codex-week")
    }

    @Test
    func usageWindowKeyStorageKeyIsStableForScopedWindows() {
        #expect(UsageWindowKey(provider: .claude, kind: .fiveHour).storageKey == "claude-5h")
        #expect(UsageWindowKey(provider: .claude, kind: .weekly).storageKey == "claude-week")
        #expect(UsageWindowKey(provider: .claude, kind: .scoped("Fable")).storageKey == "claude-scoped-fable")
    }

    @Test
    func providerSnapshotExposesOnlyReportedWindows() {
        let snapshot = ProviderSnapshot(provider: .codex, windows: [makeWindow(.weekly, used: 22)], detail: nil)

        #expect(snapshot.fiveHourWindow == nil)
        #expect(snapshot.weeklyWindow?.usedPercentage == 22)
        // Non-optional accessor reads an absent window as empty.
        #expect(snapshot.fiveHour.usedPercentage == nil)
    }

    @Test
    func agentAvailabilityPopoverVisibilityMatchesExpectedStates() {
        #expect(AgentAvailability.loading.showsInPopover)
        #expect(AgentAvailability.available.showsInPopover)
        #expect(!AgentAvailability.notInstalled.showsInPopover)
        #expect(!AgentAvailability.error("boom").showsInPopover)
    }

    @Test
    func autoRefreshDefaults() {
        #expect(AutoRefreshInterval.defaultValue == .fiveMinutes)
        #expect(AutoRefreshInterval.manual.label == "Manual")
        #expect(AutoRefreshInterval.tenMinutes.label == "10 minutes")
        #expect(AutoRefreshInterval.thirtyMinutes.duration == 1800)
    }
}
