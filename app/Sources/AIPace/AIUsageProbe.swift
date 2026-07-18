import Foundation

// MARK: - ai-usage JSON contract (schemaVersion 2)

struct AIUsageResponse: Decodable, Sendable {
    let providers: [AIUsageProvider]
}

struct AIUsageProvider: Decodable, Sendable {
    let provider: String
    let ok: Bool
    let error: String?
    let code: String?
    let identity: AIUsageIdentity?
    let windows: [AIUsageWindow]?
    let accounts: [AIUsageAccount]?
}

struct AIUsageAccount: Decodable, Sendable {
    let id: String?
    let name: String?
    let active: Bool?
    let identity: AIUsageIdentity?
    let windows: [AIUsageWindow]?
}

struct AIUsageIdentity: Decodable, Sendable {
    let email: String?
    let name: String?
    let displayName: String?
    let planType: String?
    let subscriptionType: String?
    let organizationName: String?
}

struct AIUsageWindow: Decodable, Sendable {
    let kind: String
    let title: String?
    let usedPercent: Double?
    let resetsAt: String?
    let windowMinutes: Double?
}

// MARK: - Runner

/// Runs `ai-usage --json` once per refresh and hands the parsed result to the
/// per-provider probes. A short cache plus in-flight de-duplication means the
/// concurrent Claude and Codex fetches in one refresh share a single process.
actor AIUsageRunner {
    enum Outcome: Sendable {
        case success(AIUsageResponse)
        case unavailable
    }

    private let timeout: TimeInterval
    private let cacheTTL: TimeInterval
    private let clock: @Sendable () -> Date
    private var cached: (Date, Outcome)?
    private var inFlight: Task<Outcome, Never>?

    init(
        timeout: TimeInterval = 60,
        cacheTTL: TimeInterval = 5,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.timeout = timeout
        self.cacheTTL = cacheTTL
        self.clock = clock
    }

    func outcome() async -> Outcome {
        if let (stamp, outcome) = cached, clock().timeIntervalSince(stamp) < cacheTTL {
            return outcome
        }
        if let inFlight {
            return await inFlight.value
        }
        let timeout = self.timeout
        let task = Task { await Self.runOnce(timeout: timeout) }
        inFlight = task
        let outcome = await task.value
        cached = (clock(), outcome)
        inFlight = nil
        return outcome
    }

    static func runOnce(timeout: TimeInterval) async -> Outcome {
        guard
            let json = try? await fetchJSON(timeout: timeout),
            let data = json.data(using: .utf8),
            let response = try? JSONDecoder().decode(AIUsageResponse.self, from: data)
        else {
            return .unavailable
        }
        return .success(response)
    }

    /// `ai-usage` prints its JSON to stdout even when it exits non-zero (a
    /// provider errored), and `runSync` surfaces that stdout in the thrown
    /// `.terminated` error when stderr is empty, so recover it there.
    static func fetchJSON(timeout: TimeInterval) async throws -> String {
        do {
            return try await ProcessRunner.run(
                executable: "ai-usage",
                arguments: ["--json"],
                timeout: timeout
            )
        } catch ProcessRunnerError.terminated(_, let output) {
            return output
        } catch ProcessRunnerError.executableNotFound {
            return try await runExplicitPath(timeout: timeout)
        }
    }

    static func runExplicitPath(timeout: TimeInterval) async throws -> String {
        let path = ("~/hub/config/dotfiles/bin/ai-usage" as NSString).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw ProcessRunnerError.executableNotFound("ai-usage")
        }
        do {
            return try await Task.detached(priority: .utility) {
                try ProcessRunner.runSync(
                    executable: path,
                    arguments: ["--json"],
                    input: nil,
                    timeout: timeout,
                    currentDirectory: nil
                )
            }.value
        } catch ProcessRunnerError.terminated(_, let output) {
            return output
        }
    }
}

// MARK: - Probes

/// Maps the ai-usage result for one provider to a `ProviderSnapshot`, falling
/// back to a native probe when ai-usage is unavailable so AIPace still works
/// without the CLI installed.
struct AIUsageProbe: ProviderSnapshotFetching {
    let provider: ProviderKind
    let outcome: @Sendable () async -> AIUsageRunner.Outcome
    let fallback: any ProviderSnapshotFetching

    init(
        provider: ProviderKind,
        runner: AIUsageRunner,
        fallback: any ProviderSnapshotFetching
    ) {
        self.init(provider: provider, outcome: { await runner.outcome() }, fallback: fallback)
    }

    init(
        provider: ProviderKind,
        outcome: @escaping @Sendable () async -> AIUsageRunner.Outcome,
        fallback: any ProviderSnapshotFetching
    ) {
        self.provider = provider
        self.outcome = outcome
        self.fallback = fallback
    }

    func fetch() async -> ProviderSnapshot {
        switch await outcome() {
        case .success(let response):
            guard let match = response.providers.first(where: { $0.provider == provider.rawValue.lowercased() }) else {
                return await fallback.fetch()
            }
            return AIUsageMapper.snapshot(for: provider, from: match)
        case .unavailable:
            return await fallback.fetch()
        }
    }
}

// MARK: - Mapping

enum AIUsageMapper {
    static func snapshot(for provider: ProviderKind, from source: AIUsageProvider) -> ProviderSnapshot {
        guard source.ok else {
            let message = source.error ?? "ai-usage reported an error."
            return ProviderSnapshot(
                provider: provider,
                fiveHour: UsageWindow(kind: .fiveHour, usedPercentage: nil, resetsAt: nil, message: message),
                weekly: UsageWindow(kind: .weekly, usedPercentage: nil, resetsAt: nil, message: message),
                detail: nil
            )
        }

        let accounts = (source.accounts ?? []).enumerated().map { index, account in
            ProviderAccount(
                id: account.id ?? account.name ?? "\(provider.rawValue.lowercased())-\(index)",
                name: account.name,
                active: account.active ?? false,
                detail: detailText(account.identity),
                windows: (account.windows ?? []).map(window(from:))
            )
        }

        let topWindows = (source.windows ?? []).map(window(from:))
        let activeDetail = accounts.first(where: { $0.active })?.detail ?? detailText(source.identity)

        return ProviderSnapshot(
            provider: provider,
            windows: topWindows,
            detail: activeDetail,
            // Only expose multiple named accounts; a single account renders flat.
            accounts: accounts.count > 1 ? accounts : []
        )
    }

    static func window(from source: AIUsageWindow) -> UsageWindow {
        let kind: UsageWindowKind
        switch source.kind {
        case "fiveHour":
            kind = .fiveHour
        case "weekly":
            kind = .weekly
        default:
            kind = .scoped(source.title ?? source.kind)
        }
        return UsageWindow(
            kind: kind,
            usedPercentage: source.usedPercent,
            resetsAt: parseISODate(source.resetsAt),
            message: nil
        )
    }

    static func detailText(_ identity: AIUsageIdentity?) -> String? {
        guard let identity else {
            return nil
        }
        let plan = (identity.subscriptionType ?? identity.planType)
            .flatMap { $0.isEmpty ? nil : $0.capitalized }
        let who = [identity.email, identity.displayName, identity.name, identity.organizationName]
            .compactMap { $0 }
            .first { !$0.isEmpty }
        let joined = [plan, who].compactMap { $0 }.joined(separator: " · ")
        return joined.isEmpty ? nil : joined
    }

    static func parseISODate(_ isoString: String?) -> Date? {
        guard let isoString else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: isoString)
    }
}
