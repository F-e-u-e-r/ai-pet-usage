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

    /// Monthly window length for chrome (from billing cycle when available).
    public var monthlyWindowMinutes: Int {
        guard let s = billingCycleStart, let e = billingCycleEnd, e > s else { return 43_200 }
        let mins = Int(e.timeIntervalSince(s) / 60)
        return max(1, min(mins, 62_400))
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
            if root["billingCycleEnd"] != nil { return .noUsageData }
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
        guard let ms, ms.isFinite, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

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
                                            base: ProviderLimitState?) -> [ProviderLimitState] {
        let win = quota.monthlyWindowMinutes
        let reset = quota.billingCycleEnd
        func monthly(_ used: Double, label: String, pid: String) -> ProviderLimitState {
            ProviderLimitState(
                providerId: pid,
                fiveHour: LimitWindowState(windowMinutes: 300, confidence: .unknown),
                weekly: LimitWindowState(usedPercent: used, resetAt: reset, windowMinutes: win,
                                         confidence: .high, idle: false),
                burnRateTokensPerHour: base?.burnRateTokensPerHour ?? 0,
                lastEventAt: base?.lastEventAt,
                lastReadingAt: quota.fetchedAt,
                warning: .ok,
                planType: base?.planType,
                lastSourceDescription: "cursor dashboard · \(label)",
                fiveHourOfficial: .absent,
                weeklyOfficial: .usable,
                todayActivityPercent: nil)
        }
        return [
            monthly(quota.autoPercentUsed, label: "Cursor models", pid: autoId),
            monthly(quota.apiPercentUsed, label: "Other models", pid: apiId),
        ]
    }

    public static func expandLimitStates(_ states: [ProviderLimitState],
                                         quota: CursorQuotaSnapshot?) -> [ProviderLimitState] {
        var out: [ProviderLimitState] = []
        for st in states {
            if st.providerId == "cursor-ide", let quota {
                let synth = syntheticLimitStates(from: quota, base: st)
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