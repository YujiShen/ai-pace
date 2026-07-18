import Foundation
import Testing
@testable import AIPace

struct ClaudeProbeTests {
    @Test
    func fetchReturnsUsageSnapshotAndDetailText() async throws {
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let credentialsURL = homeDirectory.appendingPathComponent(".claude/.credentials.json")
        try FileManager.default.createDirectory(at: credentialsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            {
              "claudeAiOauth": {
                "accessToken": "token",
                "refreshToken": "refresh",
                "expiresAt": 9999999999999,
                "subscriptionType": "claude_max"
              }
            }
            """.utf8
        ).write(to: credentialsURL)

        let configURL = homeDirectory.appendingPathComponent(".claude.json")
        try Data(
            """
            {
              "oauthAccount": {
                "displayName": "Ada Lovelace"
              }
            }
            """.utf8
        ).write(to: configURL)

        let loader = ClaudeCredentialLoader(
            homeDirectory: homeDirectory,
            environment: [:],
            keychainLoadOverride: .success(nil)
        )
        let resolver = ClaudeAccountInfoResolver(configURL: configURL)
        let apiClient = ClaudeAPIClient(
            fetchStatus: { ClaudeAuthStatus(loggedIn: nil) },
            refreshToken: { credentials, _ in
                Issue.record("refreshToken should not be called for fresh credentials")
                return credentials
            },
            fetchUsage: { _ in
                ClaudeUsageResponse(
                    fiveHour: ClaudeQuotaData(utilization: 25, resetsAt: "2026-04-06T12:00:00Z"),
                    sevenDay: ClaudeQuotaData(utilization: 60, resetsAt: "2026-04-12T12:00:00Z")
                )
            }
        )

        let snapshot = await ClaudeProbe(
            credentialLoader: loader,
            accountInfoResolver: resolver,
            apiClient: apiClient
        ).fetch()

        #expect(snapshot.provider == .claude)
        #expect(snapshot.fiveHour.usedPercentage == 25)
        #expect(snapshot.weekly.usedPercentage == 60)
        #expect(snapshot.detail == "Max · Ada Lovelace")
        #expect(snapshot.fiveHour.message == nil)
        #expect(snapshot.weekly.message == nil)
    }

    @Test
    func scopedWindowsBuildsModelScopedWindowsAndIgnoresUnscopedLimits() {
        let probe = ClaudeProbe()
        let limits = [
            ClaudeLimit(percent: 30, resetsAt: nil, scope: nil, isActive: true),
            ClaudeLimit(
                percent: 12,
                resetsAt: "2026-07-24T23:59:59Z",
                scope: ClaudeLimitScope(model: ClaudeLimitModel(displayName: "Fable")),
                isActive: false
            ),
        ]

        let windows = probe.scopedWindows(from: limits)

        #expect(windows.count == 1)
        #expect(windows.first?.kind == .scoped("Fable"))
        #expect(windows.first?.usedPercentage == 12)
    }

    @Test
    func claudeWindowsOmitsAbsentFiveHourAndIncludesScoped() {
        let probe = ClaudeProbe()
        let usage = ClaudeUsageResponse(
            fiveHour: nil,
            sevenDay: ClaudeQuotaData(utilization: 5, resetsAt: "2026-07-24T23:59:59Z"),
            limits: [
                ClaudeLimit(
                    percent: 0,
                    resetsAt: "2026-07-24T23:59:59Z",
                    scope: ClaudeLimitScope(model: ClaudeLimitModel(displayName: "Fable")),
                    isActive: false
                ),
            ]
        )

        let windows = probe.claudeWindows(from: usage)

        #expect(!windows.contains { $0.kind == .fiveHour })
        #expect(windows.contains { $0.kind == .weekly })
        #expect(windows.contains { $0.kind == .scoped("Fable") })
    }

    @Test
    func fetchReportsLoggedInWhenCredentialsCannotBeRead() async throws {
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let loader = ClaudeCredentialLoader(
            homeDirectory: homeDirectory,
            environment: [:],
            keychainLoadOverride: .success(nil)
        )
        let apiClient = ClaudeAPIClient(
            fetchStatus: { ClaudeAuthStatus(loggedIn: true) },
            refreshToken: { credentials, _ in credentials },
            fetchUsage: { _ in
                Issue.record("fetchUsage should not be called when credentials are missing")
                return ClaudeUsageResponse(fiveHour: nil, sevenDay: nil)
            }
        )

        let snapshot = await ClaudeProbe(
            credentialLoader: loader,
            accountInfoResolver: ClaudeAccountInfoResolver(configURL: homeDirectory.appendingPathComponent(".missing")),
            apiClient: apiClient
        ).fetch()

        #expect(snapshot.fiveHour.message == "Claude is logged in, but credentials could not be read from file, Keychain, or environment.")
        #expect(snapshot.weekly.message == snapshot.fiveHour.message)
    }

    @Test
    func fetchRetriesAfterAuthenticationFailureForRefreshableCredentials() async throws {
        actor State {
            var usageTokens: [String] = []
            var refreshCalls = 0

            func recordUsageToken(_ token: String) -> Int {
                usageTokens.append(token)
                return usageTokens.count
            }

            func recordRefresh() {
                refreshCalls += 1
            }
        }

        let state = State()
        let homeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let credentialsURL = homeDirectory.appendingPathComponent(".claude/.credentials.json")
        try FileManager.default.createDirectory(at: credentialsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(
            """
            {
              "claudeAiOauth": {
                "accessToken": "old-token",
                "refreshToken": "refresh-token",
                "expiresAt": 9999999999999
              }
            }
            """.utf8
        ).write(to: credentialsURL)

        let loader = ClaudeCredentialLoader(
            homeDirectory: homeDirectory,
            environment: [:],
            keychainLoadOverride: .success(nil)
        )
        let apiClient = ClaudeAPIClient(
            fetchStatus: { ClaudeAuthStatus(loggedIn: nil) },
            refreshToken: { credentials, _ in
                await state.recordRefresh()
                var updated = credentials
                updated.oauth.accessToken = "new-token"
                return updated
            },
            fetchUsage: { token in
                let call = await state.recordUsageToken(token)
                if call == 1 {
                    throw ProcessRunnerError.invalidResponse("Claude authentication failed.")
                }
                return ClaudeUsageResponse(
                    fiveHour: ClaudeQuotaData(utilization: 30, resetsAt: "2026-04-06T12:00:00Z"),
                    sevenDay: ClaudeQuotaData(utilization: 55, resetsAt: "2026-04-12T12:00:00Z")
                )
            }
        )

        let snapshot = await ClaudeProbe(
            credentialLoader: loader,
            accountInfoResolver: ClaudeAccountInfoResolver(configURL: homeDirectory.appendingPathComponent(".missing")),
            apiClient: apiClient
        ).fetch()

        #expect(snapshot.fiveHour.usedPercentage == 30)
        #expect(snapshot.weekly.usedPercentage == 55)
        let usageTokens = await state.usageTokens
        let refreshCalls = await state.refreshCalls
        #expect(usageTokens == ["old-token", "new-token"])
        #expect(refreshCalls == 1)
    }
}
