import Foundation

/// Antigravity 把每个模型的额度汇总成本机语言服务里的几份额度窗口。
/// 语言服务由 Antigravity 客户端启动，在 `~/.gemini/antigravity/daemon` 下留下端口与 CSRF 令牌，
/// 读取时直接向本机接口要一份汇总，沿用客户端自己展示的分组与窗口。
public struct AntigravityLimitsProvider: Sendable {
    private static let servicePath = "/exa.language_server_pb.LanguageServerService/"
    private static let sessionWindowMinutes = 300
    private static let weeklyWindowMinutes = 10_080

    private let daemonDirectory: URL
    private let urlSession: URLSession

    public init() {
        daemonDirectory = LocalPaths.override(
            "ANTIGRAVITY_DAEMON_DIR",
            fallback: LocalPaths.directory(".gemini/antigravity/daemon")
        )
        urlSession = .shared
    }

    init(daemonDirectory: URL, urlSession: URLSession) {
        self.daemonDirectory = daemonDirectory
        self.urlSession = urlSession
    }

    public func fetch() async throws -> ProviderLimits {
        guard let hub = try hubEntry() else {
            return unavailable("本机没有运行中的 Antigravity，打开 Antigravity 后就能读到 Gemini 的额度")
        }
        do {
            let account = try await account(hub)
            let buckets = try await quotaBuckets(hub)
            guard !buckets.isEmpty else {
                return unavailable("Antigravity 没有返回可展示的额度")
            }
            return ProviderLimits(
                provider: .antigravity,
                buckets: buckets,
                planType: account.plan,
                accountLabel: account.email,
                status: .ok,
                updatedAt: Date()
            )
        } catch let error as URLError where Self.hubUnreachable(error) {
            return unavailable("Antigravity 的本机接口没有响应，打开 Antigravity 后就能读到额度")
        }
    }

    private struct HubEntry: Decodable {
        let httpPort: Int
        let csrfToken: String
    }

    struct Account {
        let email: String?
        let plan: String?
    }

    /// 客户端每次启动都会在这个目录写下当前端口与 CSRF 令牌，存在多份时取最新的一份
    private func hubEntry() throws -> HubEntry? {
        guard FileManager.default.fileExists(atPath: daemonDirectory.path(percentEncoded: false)) else {
            return nil
        }
        let files = try FileManager.default.contentsOfDirectory(
            at: daemonDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let candidates = files
            .filter { $0.lastPathComponent.hasPrefix("hub_") && $0.pathExtension == "json" }
            .sorted {
                let left = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let right = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return (left ?? .distantPast) > (right ?? .distantPast)
            }
        for file in candidates {
            let data = try Data(contentsOf: file)
            if let entry = try? JSONDecoder().decode(HubEntry.self, from: data) {
                return entry
            }
        }
        return nil
    }

    private func account(_ hub: HubEntry) async throws -> Account {
        let url = try endpoint(hub, method: "GetUserStatus")
        let payload = try await post(url, hub: hub)
        guard (200..<300).contains(payload.status) else {
            throw LimitsError.responseRejected(url.absoluteString, payload.status)
        }
        guard let root = try payload.json() as? [String: Any] else {
            throw LimitsError.responseMalformed(url.absoluteString)
        }
        guard let account = Self.account(from: root) else {
            throw LimitsError.credentialsMissing("Antigravity")
        }
        return account
    }

    private func quotaBuckets(_ hub: HubEntry) async throws -> [RateLimitBucket] {
        let url = try endpoint(hub, method: "RetrieveUserQuotaSummary")
        let payload = try await post(url, hub: hub, body: ["forceRefresh": true])
        guard (200..<300).contains(payload.status) else {
            throw LimitsError.responseRejected(url.absoluteString, payload.status)
        }
        guard let root = try payload.json() as? [String: Any],
              let response = root["response"] as? [String: Any] else {
            throw LimitsError.responseMalformed(url.absoluteString)
        }
        return Self.buckets(from: response)
    }

    private func endpoint(_ hub: HubEntry, method: String) throws -> URL {
        guard let url = URL(string: "http://127.0.0.1:\(hub.httpPort)\(Self.servicePath)\(method)") else {
            throw LimitsError.requestFailed("Antigravity 的本机接口地址无法生成")
        }
        return url
    }

    private func post(_ url: URL, hub: HubEntry, body: [String: Any] = [:]) async throws -> HTTPPayload {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await HTTP.postJSON(
            url,
            body: data,
            headers: ["x-codeium-csrf-token": hub.csrfToken],
            urlSession: urlSession
        )
    }

    private func unavailable(_ message: String) -> ProviderLimits {
        ProviderLimits(
            provider: .antigravity,
            status: .unavailable,
            error: message,
            updatedAt: Date()
        )
    }

    private static func hubUnreachable(_ error: URLError) -> Bool {
        [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost].contains(error.code)
    }

    /// `GetUserStatus` 里带当前登录账号与套餐；没有 `userStatus` 说明客户端还没登录
    static func account(from root: [String: Any]) -> Account? {
        guard let user = root["userStatus"] as? [String: Any] else { return nil }
        let planInfo = (user["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any]
        return Account(
            email: nonEmptyString(user["email"]),
            plan: nonEmptyString(planInfo?["planName"])
        )
    }

    /// 汇总响应按分组给出每个窗口的剩余比例，分组顺序就是客户端里的顺序
    static func buckets(from response: [String: Any]) -> [RateLimitBucket] {
        guard let groups = response["groups"] as? [[String: Any]] else { return [] }
        return groups.flatMap { group -> [RateLimitBucket] in
            let groupName = nonEmptyString(group["displayName"]) ?? "Antigravity"
            guard let rawBuckets = group["buckets"] as? [[String: Any]] else { return [] }
            return rawBuckets
                .compactMap { bucket -> (RateLimitBucket, Int)? in
                    guard let remaining = finiteNumber(bucket["remainingFraction"]) else { return nil }
                    let window = windowDescription(nonEmptyString(bucket["window"]))
                    let limits = makeWindow(
                        usedPercent: (1 - remaining) * 100,
                        windowMinutes: window.minutes,
                        resetsAt: parseResetDate(bucket["resetTime"])
                    )
                    return (RateLimitBucket(name: "\(groupLabel(groupName)) · \(window.name)", window: limits), window.minutes)
                }
                .sorted { $0.1 < $1.1 }
                .map(\.0)
        }
    }

    private static func groupLabel(_ name: String) -> String {
        switch name {
        case "Gemini Models": "Gemini"
        case "Claude and GPT models": "Claude / GPT"
        default: name
        }
    }

    private static func windowDescription(_ raw: String?) -> (name: String, minutes: Int) {
        switch raw {
        case "5h": ("5 小时", sessionWindowMinutes)
        case "weekly": ("7 天", weeklyWindowMinutes)
        default: (raw ?? "额度", 0)
        }
    }
}
