import Foundation

/// Kimi Code subscription quota via the provider's coding usage endpoint.
///
/// Ground rules, matching SECURITY.md and the Claude quota provider:
///   * **Opt-in only.** Nothing here runs unless the `kimi_quota_optin`
///     setting is "true". Default is off.
///   * **Read-only.** The access token is read from the CLI's own
///     `~/.kimi-code/credentials/kimi-code.json`, used for one GET, and never
///     stored anywhere. The refresh token is never touched, so an active CLI
///     session cannot be invalidated.
///   * **Rare.** Callers must respect `minimumInterval` (15 min).
///   * **Honest failure.** This endpoint's response shape is not officially
///     documented. The parser below accepts several shapes and emits only
///     windows it can fully identify (label + percent); anything unrecognized
///     yields `malformed` → the UI shows "unavailable", never a guessed number.
public struct KimiQuotaProvider: Sendable {
    public static let providerName = "Kimi Code"
    public static let minimumInterval: TimeInterval = 900

    public enum FetchError: Error, Equatable {
        case credentialsUnavailable
        case tokenExpired
        case httpStatus(Int)
        case malformed
    }

    let credentialsURL: URL

    public init(credentialsURL: URL? = nil) {
        self.credentialsURL = credentialsURL ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code/credentials/kimi-code.json")
    }

    /// Reads the access token from the CLI's credential file. The refresh
    /// token in the same file is deliberately never read into a return value.
    func readAccessToken() -> (token: String, expiresAt: Date?)? {
        guard let data = try? Data(contentsOf: credentialsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty
        else { return nil }
        var expires: Date?
        if let t = json.int("expires_at") { expires = Date(timeIntervalSince1970: TimeInterval(t)) }
        return (token, expires)
    }

    /// Fetches current quota windows. Async; one request; token held in memory
    /// for the duration of the call only.
    public func fetch() async -> Result<[QuotaWindow], FetchError> {
        guard let (token, expiresAt) = readAccessToken() else { return .failure(.credentialsUnavailable) }
        if let expiresAt, expiresAt < Date() { return .failure(.tokenExpired) }

        var request = URLRequest(url: URL(string: "https://api.kimi.com/coding/v1/usages")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("kimi-code", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return .failure(.malformed)
        }
        guard let http = response as? HTTPURLResponse else { return .failure(.malformed) }
        guard http.statusCode == 200 else { return .failure(.httpStatus(http.statusCode)) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.malformed)
        }
        let windows = Self.parseWindows(from: root, now: Date())
        return windows.isEmpty ? .failure(.malformed) : .success(windows)
    }

    /// Parses the endpoint's response into quota windows, accepting the
    /// documented-community shape and small variations:
    ///
    ///   * top level or under a `data` envelope;
    ///   * windows keyed `five_hour` / `weekly` / `seven_day` (or nested under
    ///     a `quotas` / `limits` map), each with `utilization` or
    ///     `used_percent`, optional `resets_at` (RFC3339 or epoch seconds).
    ///
    /// Only windows with a recognizable identity AND a percent are emitted —
    /// a partial parse is reported as no data, never as a guessed window.
    static func parseWindows(from root: [String: Any], now: Date) -> [QuotaWindow] {
        let container = root.dict("data") ?? root
        let maps = [container, container.dict("quotas"), container.dict("limits")].compactMap { $0 }

        let known: [(keys: [String], id: String, label: String, minutes: Int)] = [
            (["five_hour", "fiveHour", "5h"], "kimi-five-hour", "5h", 300),
            (["weekly", "seven_day", "sevenDay", "week"], "kimi-weekly", "weekly", 10080),
        ]

        var windows: [QuotaWindow] = []
        for kind in known {
            for map in maps {
                guard let w = kind.keys.compactMap({ map[$0] as? [String: Any] }).first,
                      let percent = w.double("utilization") ?? w.double("used_percent") ?? w.double("usedPercent")
                else { continue }
                var resets: Date?
                if let s = w.str("resets_at") ?? w.str("resetsAt") {
                    resets = Timestamps.parse(s)
                } else if let t = w.int("resets_at") ?? w.int("resetsAt") {
                    resets = Date(timeIntervalSince1970: TimeInterval(t))
                }
                windows.append(QuotaWindow(
                    id: kind.id, label: kind.label, usedPercent: percent,
                    windowMinutes: kind.minutes, resetsAt: resets, observedAt: now, planType: "oauth"
                ))
                break
            }
        }
        return windows
    }
}
