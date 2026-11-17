import Foundation
import Security

// Cursor IDE monthly plan usage (Cursor models vs Other models) from DashboardService.
// Pure logic: keychain token read, Connect JSON request, response parse — no logging of secrets.

public struct CursorQuotaSnapshot: Sendable, Equatable {
    public var autoPercentUsed: Double
    public var apiPercentUsed: Double
    public var billingCycleStart: Date?
    public var billingCycleEnd: Date?
    public var fetchedAt: Date

    /// The billing cycle this snapshot describes has ended; its percentages no longer apply.
    public func isPastBillingEnd(now: Date) -> Bool {
        billingCycleEnd.map { $0 <= now } ?? false
    }

    /// Monthly window length for chrome (from billing cycle when available).
    public var monthlyWindowMinutes: Int {
        guard let s = billingCycleStart, let e = billingCycleEnd, e > s else { return 43_200 }
        // Clamp in Double first: a malformed far-future end would trap `Int(_:)`.
        return max(1, Int(min(e.timeIntervalSince(s) / 60, 62_400)))
    }

    public init(autoPercentUsed: Double, apiPercentUsed: Double,
                billingCycleStart: Date?, billingCycleEnd: Date?, fetchedAt: Date) {
        self.autoPercentUsed = autoPercentUsed
        self.apiPercentUsed = apiPercentUsed
        self.billingCycleStart = billingCycleStart
        self.billingCycleEnd = billingCycleEnd
        self.fetchedAt = fetchedAt
    }
}

public enum CursorQuotaOutcome: Sendable, Equatable {
    case success(CursorQuotaSnapshot)
    case noUsageData
    case noKey
    case keyRejected
    case rateLimited(retryAfterSeconds: Double?)
    case schemaBreaking
    case invalidBody
    case endpointGone
    case serverError
    case badReply
    case networkError

    public var observationEvent: SourceObservationEvent {
        switch self {
        case .success, .noUsageData: return .success
        case .keyRejected: return .authRejected
        case .rateLimited: return .rateLimited
        case .schemaBreaking: return .schemaBreaking
        case .invalidBody: return .invalidBody
        case .endpointGone: return .endpointGone
        case .noKey, .serverError, .badReply, .networkError: return .transportFailure
        }
    }
}

public enum CursorKeychain {
    private static let service = "cursor-access-token"
    private static let account = "cursor-user"

    public static func loadAccessToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, !token.isEmpty, token.count <= 8192 else { return nil }
        return token
    }
}

public enum CursorQuotaEngine {
    public static let endpoint =
        URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
    public static let maxResponseBytes = 256_000

    public static func request(token: String, appVersion: String) -> URLRequest {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        req.setValue("connect-es/1.6.1", forHTTPHeaderField: "User-Agent")
        req.setValue("AI-Pet-Usage/\(appVersion)", forHTTPHeaderField: "X-Client-Name")
        return req
    }

    public static func isTrustedResponse(url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "api2.cursor.sh"
    }

    public static func parseResponse(statusCode: Int, data: Data, now: Date) -> CursorQuotaOutcome {
        switch statusCode {
        case 200:
            break
        case 401: return .keyRejected
        case 404, 410: return .endpointGone
        case 429:
            return .rateLimited(retryAfterSeconds: nil)
        case 500...599: return .serverError
        default: return .badReply
        }
        guard data.count <= maxResponseBytes else { return .badReply }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .invalidBody
        }
        guard let plan = root["planUsage"] as? [String: Any] else {
            // A JSON `null` decodes as NSNull, not nil: count only a real value, in either key spelling.
            let hasCycleEnd = [root["billingCycleEnd"], root["billing_cycle_end"]].contains { $0 != nil && !($0 is NSNull) }
            if hasCycleEnd { return .noUsageData }
            return .schemaBreaking
        }
        let auto = percentField(plan["autoPercentUsed"] ?? plan["auto_percent_used"])
        let api = percentField(plan["apiPercentUsed"] ?? plan["api_percent_used"])
        guard auto != nil || api != nil else { return .noUsageData }
        let start = millisDate(root["billingCycleStart"] ?? root["billing_cycle_start"])
        let end = millisDate(root["billingCycleEnd"] ?? root["billing_cycle_end"])
        let snap = CursorQuotaSnapshot(
            autoPercentUsed: clampPercent(auto ?? 0),
            apiPercentUsed: clampPercent(api ?? 0),
            billingCycleStart: start,
            billingCycleEnd: end,
            fetchedAt: now)
        return .success(snap)
    }

    private static func percentField(_ raw: Any?) -> Double? {
        switch raw {
        case let n as Double where n.isFinite: return n
        case let n as Int: return Double(n)
        case let s as String: return Double(s)
        default: return nil
        }
    }

    private static func millisDate(_ raw: Any?) -> Date? {
        let ms: Double?
        switch raw {
        case let n as Double: ms = n
        case let n as Int: ms = Double(n)
        case let s as String: ms = Double(s)
        default: ms = nil
        }
        // Reject implausible dates (past 2100-01-01): downstream labels convert intervals with `Int(_:)`,
        // which traps on a far-future value such as `1e30`.
        guard let ms, ms.isFinite, ms > 0, ms < maxPlausibleMillis else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    static let maxPlausibleMillis = 4_102_444_800_000.0   // 2100-01-01T00:00:00Z

    private static func clampPercent(_ p: Double) -> Double {
        min(100, max(0, p))
    }
}

// MARK: - Menu / dashboard chrome

public enum CursorQuotaDisplay {
    public static let autoId = "cursor-ide-auto"
    public static let apiId = "cursor-ide-api"

    public static func isQuotaChromeId(_ id: String) -> Bool {
        id == autoId || id == apiId
    }

    public static let categoryName = "Cursor"

    /// Full name (menu-bar badges, sorting, a11y).
    public static func displayName(forChromeId id: String) -> String? {
        switch id {
        case autoId: return "\(categoryName) · models"
        case apiId: return "\(categoryName) · other models"
        default: return nil
        }
    }

    /// Short sub-meter label under the Cursor category (settings, menu dropdown).
    public static func meterLabel(forChromeId id: String) -> String? {
        switch id {
        case autoId: return "Models"
        case apiId: return "Other models"
        default: return nil
        }
    }

    /// Stable sort key: both meters share the Cursor prefix and stay adjacent.
    public static func sortKey(forChromeId id: String) -> String? {
        switch id {
        case autoId: return "\(categoryName.lowercased()) · models"
        case apiId: return "\(categoryName.lowercased()) · other models"
        default: return nil
        }
    }

    public static func shortCode(forChromeId id: String) -> String? {
        switch id {
        case autoId: return "C1"
        case apiId: return "C3"
        default: return nil
        }
    }

    public static func syntheticLimitStates(from quota: CursorQuotaSnapshot,
                                            base: ProviderLimitState?,
                                            now: Date = Date()) -> [ProviderLimitState] {
        let win = quota.monthlyWindowMinutes
        let reset = quota.billingCycleEnd
        // The checker keeps the last snapshot when fetches fail: flag an old one stale, and drop
        // the value once its billing cycle has ended (same rule as the Antigravity quota rows).
        let stale = now.timeIntervalSince(quota.fetchedAt) > StatuslineAge.labelThreshold
        let expired = quota.isPastBillingEnd(now: now)
        func monthly(_ used: Double, label: String, pid: String) -> ProviderLimitState {
            ProviderLimitState(
                providerId: pid,
                fiveHour: LimitWindowState(windowMinutes: 300, confidence: .unknown),
                weekly: expired
                    ? LimitWindowState(windowMinutes: win, confidence: .high, idle: false)
                    : LimitWindowState(usedPercent: used, resetAt: reset, windowMinutes: win,
                                       confidence: .high, idle: false, observedAt: quota.fetchedAt),
                burnRateTokensPerHour: base?.burnRateTokensPerHour ?? 0,
                lastEventAt: base?.lastEventAt,
                lastReadingAt: quota.fetchedAt,
                warning: stale ? .stale : .ok,
                planType: base?.planType,
                lastSourceDescription: "cursor dashboard · \(label)",
                fiveHourOfficial: .absent,
                weeklyOfficial: expired ? .expiredUnusable : .usable,
                todayActivityPercent: nil)
        }
        return [
            monthly(quota.autoPercentUsed, label: "Cursor models", pid: autoId),
            monthly(quota.apiPercentUsed, label: "Other models", pid: apiId),
        ]
    }

    /// Dashboard line for one meter: a past billing cycle shows no value (same rule as the menu rows).
    public static func meterSummary(_ used: Double, quota: CursorQuotaSnapshot, now: Date) -> String {
        if quota.isPastBillingEnd(now: now) { return "— · awaiting Cursor refresh" }
        return "\(Int(used.rounded()))% used · resets \(ResetLabel.countdown(to: quota.billingCycleEnd, now: now))"
    }

    public static func expandLimitStates(_ states: [ProviderLimitState],
                                         quota: CursorQuotaSnapshot?,
                                         now: Date = Date()) -> [ProviderLimitState] {
        var out: [ProviderLimitState] = []
        for st in states {
            if st.providerId == "cursor-ide", let quota {
                let synth = syntheticLimitStates(from: quota, base: st, now: now)
                out.append(contentsOf: synth)
                continue
            }
            if isQuotaChromeId(st.providerId) { continue }
            out.append(st)
        }
        return out
    }

    /// Pet ring: one Cursor arc (Cursor models monthly primary).
    public static func collapseForPetRings(_ states: [ProviderLimitState]) -> [ProviderLimitState] {
        var out: [ProviderLimitState] = []
        var inserted = false
        for st in states {
            if isQuotaChromeId(st.providerId) {
                guard !inserted else { continue }
                if let auto = states.first(where: { $0.providerId == autoId }) {
                    out.append(auto)
                } else if let any = states.first(where: { isQuotaChromeId($0.providerId) }) {
                    out.append(any)
                }
                inserted = true
            } else {
                out.append(st)
            }
        }
        return out
    }
}

public enum CursorChromeDisplay {
    /// Monthly official % lives in the weekly column; no 5h meter (like Grok weekly-only).
    public static func usesMonthlyOnlyMeter(_ id: String) -> Bool {
        CursorQuotaDisplay.isQuotaChromeId(id)
    }
}