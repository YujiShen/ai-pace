import Foundation
import Testing
@testable import AIPace

struct AIUsageProbeTests {
    private func decode(_ json: String) throws -> AIUsageResponse {
        try JSONDecoder().decode(AIUsageResponse.self, from: Data(json.utf8))
    }

    private var sampleJSON: String {
        """
        {
          "schemaVersion": 2,
          "ok": true,
          "providers": [
            {
              "provider": "claude",
              "ok": true,
              "identity": {"email": "yuji@gridwise.io", "subscriptionType": "team"},
              "windows": [
                {"kind": "fiveHour", "title": "5h", "usedPercent": 55, "resetsAt": "2026-07-18T07:00:00Z", "windowMinutes": 300},
                {"kind": "weekly", "title": "Week", "usedPercent": 9, "resetsAt": "2026-07-24T23:59:59Z", "windowMinutes": 10080},
                {"kind": "scoped", "title": "Fable", "usedPercent": 2, "resetsAt": "2026-07-24T23:59:59Z", "windowMinutes": 10080}
              ]
            },
            {
              "provider": "codex",
              "ok": true,
              "source": "cma",
              "identity": {"email": "vickyleewhy@hotmail.com", "planType": "plus"},
              "windows": [
                {"kind": "weekly", "title": "Week", "usedPercent": 17, "resetsAt": "2026-07-24T23:24:00Z", "windowMinutes": 10080}
              ],
              "accounts": [
                {"id": "a", "name": "gridwise-team", "active": false, "identity": {"email": "yuji@gridwise.io", "planType": "team"}, "windows": [
                  {"kind": "weekly", "title": "Week", "usedPercent": 0, "resetsAt": "2026-07-25T05:00:00Z", "windowMinutes": 10080}
                ]},
                {"id": "b", "name": "yuji-plus", "active": false, "identity": {"email": "acss21acss@gmail.com", "planType": "prolite"}, "windows": [
                  {"kind": "weekly", "title": "Week", "usedPercent": 0, "resetsAt": "2026-07-25T05:00:00Z", "windowMinutes": 10080}
                ]},
                {"id": "c", "name": "danyang-plus", "active": true, "identity": {"email": "vickyleewhy@hotmail.com", "planType": "plus"}, "windows": [
                  {"kind": "weekly", "title": "Week", "usedPercent": 17, "resetsAt": "2026-07-24T23:24:00Z", "windowMinutes": 10080}
                ]}
              ]
            }
          ]
        }
        """
    }

    @Test
    func mapsClaudeWindowsIncludingScoped() throws {
        let response = try decode(sampleJSON)
        let claude = try #require(response.providers.first { $0.provider == "claude" })

        let snapshot = AIUsageMapper.snapshot(for: .claude, from: claude)

        #expect(snapshot.accounts.isEmpty)
        #expect(snapshot.windows.map(\.kind) == [.fiveHour, .weekly, .scoped("Fable")])
        #expect(snapshot.fiveHourWindow?.usedPercentage == 55)
        #expect(snapshot.detail == "Team · yuji@gridwise.io")
    }

    @Test
    func mapsCodexMultipleAccountsWithActiveFlag() throws {
        let response = try decode(sampleJSON)
        let codex = try #require(response.providers.first { $0.provider == "codex" })

        let snapshot = AIUsageMapper.snapshot(for: .codex, from: codex)

        #expect(snapshot.accounts.count == 3)
        #expect(snapshot.accounts.filter(\.active).map(\.name) == ["danyang-plus"])
        // Absent 5h stays absent; each account shows only its weekly window.
        #expect(snapshot.accounts.allSatisfy { $0.windows.map(\.kind) == [.weekly] })
        // Top-level windows mirror the active account (menu-bar source).
        #expect(snapshot.weeklyWindow?.usedPercentage == 17)
    }

    @Test
    func singleAccountCodexRendersFlat() throws {
        let codex = AIUsageProvider(
            provider: "codex",
            ok: true,
            error: nil,
            code: nil,
            identity: AIUsageIdentity(email: "solo@example.com", name: nil, displayName: nil, planType: "plus", subscriptionType: nil, organizationName: nil),
            windows: [AIUsageWindow(kind: "weekly", title: "Week", usedPercent: 5, resetsAt: nil, windowMinutes: 10080)],
            accounts: [AIUsageAccount(id: nil, name: nil, active: true, identity: nil, windows: [AIUsageWindow(kind: "weekly", title: "Week", usedPercent: 5, resetsAt: nil, windowMinutes: 10080)])]
        )

        let snapshot = AIUsageMapper.snapshot(for: .codex, from: codex)

        #expect(snapshot.accounts.isEmpty)
        #expect(snapshot.weeklyWindow?.usedPercentage == 5)
    }

    @Test
    func errorProviderMapsToMessageWindows() {
        let provider = AIUsageProvider(
            provider: "claude",
            ok: false,
            error: "Claude session expired; log in again.",
            code: "sessionExpired",
            identity: nil,
            windows: nil,
            accounts: nil
        )

        let snapshot = AIUsageMapper.snapshot(for: .claude, from: provider)

        #expect(snapshot.windows.allSatisfy { $0.usedPercentage == nil })
        #expect(snapshot.windows.contains { $0.message == "Claude session expired; log in again." })
    }

    @Test
    func probeFallsBackWhenAIUsageUnavailable() async {
        let fallbackSnapshot = ProviderSnapshot(provider: .codex, windows: [makeWindow(.weekly, used: 42)], detail: "native")
        let probe = AIUsageProbe(
            provider: .codex,
            outcome: { .unavailable },
            fallback: ProbeStub(queue: ProbeQueue([fallbackSnapshot]))
        )

        let snapshot = await probe.fetch()

        #expect(snapshot.detail == "native")
        #expect(snapshot.weeklyWindow?.usedPercentage == 42)
    }

    @Test
    func probeUsesAIUsageResultWhenAvailable() async throws {
        let response = try decode(sampleJSON)
        let probe = AIUsageProbe(
            provider: .codex,
            outcome: { .success(response) },
            fallback: ProbeStub(queue: ProbeQueue([ProviderSnapshot.loading(.codex)]))
        )

        let snapshot = await probe.fetch()

        #expect(snapshot.accounts.count == 3)
    }
}
