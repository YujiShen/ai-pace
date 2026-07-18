import Foundation
import Testing
@testable import AIPace

struct CodexProbeTests {
    @Test
    func numericValueParsesCommonJSONRepresentations() {
        let probe = CodexProbe()

        #expect(probe.numericValue(12) == 12)
        #expect(probe.numericValue("12.5") == 12.5)
        #expect(probe.numericValue(NSNumber(value: 7.25)) == 7.25)
        #expect(probe.numericValue("nope") == nil)
    }

    @Test
    func parseWindowRequiresUsedPercentAndParsesResetTimestamp() {
        let probe = CodexProbe()
        let window = probe.parseWindow([
            "usedPercent": "62.5",
            "resetsAt": 1_710_000_000,
        ])

        #expect(window?.usedPercent == 62.5)
        #expect(window?.resetsAt == Date(timeIntervalSince1970: 1_710_000_000))
        #expect(probe.parseWindow(["resetsAt": 1_710_000_000]) == nil)
    }

    @Test
    func parseWindowReadsReportedDuration() {
        let probe = CodexProbe()
        let window = probe.parseWindow([
            "usedPercent": 9,
            "windowDurationMins": 10_080,
            "resetsAt": 1_784_949_880,
        ])

        #expect(window?.windowMinutes == 10_080)
    }

    @Test
    func classifyWindowsRoutesWeeklyPrimaryToWeekly() {
        let probe = CodexProbe()
        // Codex retired the 5h window: `primary` now carries the weekly window.
        let limits = CodexRateLimits(
            primary: CodexRateLimitWindow(usedPercent: 9, resetsAt: nil, windowMinutes: 10_080),
            secondary: nil,
            planType: "plus"
        )

        let (fiveHour, weekly) = probe.classifyWindows(limits)

        #expect(fiveHour == nil)
        #expect(weekly?.usedPercent == 9)
        #expect(weekly?.windowMinutes == 10_080)
    }

    @Test
    func classifyWindowsUsesDurationForBothWindows() {
        let probe = CodexProbe()
        let limits = CodexRateLimits(
            primary: CodexRateLimitWindow(usedPercent: 40, resetsAt: nil, windowMinutes: 300),
            secondary: CodexRateLimitWindow(usedPercent: 12, resetsAt: nil, windowMinutes: 10_080),
            planType: "plus"
        )

        let (fiveHour, weekly) = probe.classifyWindows(limits)

        #expect(fiveHour?.usedPercent == 40)
        #expect(weekly?.usedPercent == 12)
    }

    @Test
    func windowsOmitsFiveHourWhenCodexReturnsOnlyWeekly() {
        let probe = CodexProbe()
        let limits = CodexRateLimits(
            primary: CodexRateLimitWindow(usedPercent: 9, resetsAt: nil, windowMinutes: 10_080),
            secondary: nil,
            planType: "plus"
        )

        let windows = probe.windows(from: limits)

        #expect(windows.count == 1)
        #expect(windows.first?.kind == .weekly)
        #expect(windows.first?.usedPercentage == 9)
        #expect(!windows.contains { $0.kind == .fiveHour })
    }

    @Test
    func windowsIncludesBothWhenCodexReturnsFiveHourAndWeekly() {
        let probe = CodexProbe()
        let limits = CodexRateLimits(
            primary: CodexRateLimitWindow(usedPercent: 40, resetsAt: nil, windowMinutes: 300),
            secondary: CodexRateLimitWindow(usedPercent: 12, resetsAt: nil, windowMinutes: 10_080),
            planType: "plus"
        )

        let windows = probe.windows(from: limits)

        #expect(windows.count == 2)
        #expect(windows.contains { $0.kind == .fiveHour })
        #expect(windows.contains { $0.kind == .weekly })
    }

    @Test
    func classifyWindowsFallsBackToPositionWhenDurationMissing() {
        let probe = CodexProbe()
        // Older Codex builds omit windowDurationMins: keep primary=5h, secondary=weekly.
        let limits = CodexRateLimits(
            primary: CodexRateLimitWindow(usedPercent: 30, resetsAt: nil, windowMinutes: nil),
            secondary: CodexRateLimitWindow(usedPercent: 8, resetsAt: nil, windowMinutes: nil),
            planType: "plus"
        )

        let (fiveHour, weekly) = probe.classifyWindows(limits)

        #expect(fiveHour?.usedPercent == 30)
        #expect(weekly?.usedPercent == 8)
    }

    @Test
    func readResponseReturnsMatchingPayload() async throws {
        let stream = AsyncStream<String> { continuation in
            continuation.yield("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ignored\":true}}")
            continuation.yield("not json")
            continuation.yield("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"rateLimits\":{}}}")
            continuation.finish()
        }

        let payload = try await readResponse(withID: 2, from: stream)

        #expect(payload["id"] as? Int == 2)
        #expect((payload["result"] as? [String: Any]) != nil)
    }

    @Test
    func readResponseThrowsMatchingServerError() async {
        let stream = AsyncStream<String> { continuation in
            continuation.yield("{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"message\":\"No session\"}}")
            continuation.finish()
        }

        do {
            _ = try await readResponse(withID: 2, from: stream)
            Issue.record("Expected invalid response error")
        } catch let error as ProcessRunnerError {
            guard case .invalidResponse(let message) = error else {
                Issue.record("Unexpected error type: \(error)")
                return
            }
            #expect(message == "No session")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
