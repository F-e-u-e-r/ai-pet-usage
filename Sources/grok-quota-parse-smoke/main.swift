import Foundation
import UsageCore

let now = ISO8601DateFormatter().date(from: "2026-11-15T10:00:00Z")!
let json = """
{"config":{"creditUsagePercent":30,"productUsage":[{"product":"GrokBuild","usagePercent":30}]}}
""".data(using: .utf8)!
guard case .success(let snap) = GrokQuotaEngine.parseResponse(statusCode: 200, data: json, now: now) else {
    fputs("FAIL: expected success\n", stderr)
    exit(1)
}
guard snap.usedPercent == 30 else {
    fputs("FAIL: usedPercent=\(snap.usedPercent)\n", stderr)
    exit(1)
}
print("OK grok quota parse usedPercent=\(Int(snap.usedPercent))")