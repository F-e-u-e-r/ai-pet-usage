import Foundation
import UsageCore

// Canonical release contract (docs/release/VERSIONING.md) — F1 accept / F2 reject / F3 order / F4 extraction /
// F5 asset identity, plus Swift ↔ bash parity. Vectors: Fixtures/canonical-version-vectors.tsv — the frozen
// Phase 1 fixture (75 vectors), byte-identical to the copy the Homebrew tap's selector tests use.

/// One TSV row; fields split on TAB with empty fields kept. In the input column "\n" means a newline.
struct VersionVector {
    let kind: String
    let input: String
    let fields: [String]   // columns after the input column
}

func loadVersionVectors() -> [VersionVector] {
    guard let text = try? String(contentsOf: fixtureURL("canonical-version-vectors.tsv"), encoding: .utf8) else { return [] }
    var out: [VersionVector] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        if line.hasPrefix("#") { continue }
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard cols.count >= 2 else { continue }
        out.append(VersionVector(kind: cols[0], input: cols[1].replacingOccurrences(of: "\\n", with: "\n"),
                                 fields: Array(cols.dropFirst(2))))
    }
    return out
}

/// Repository root, located from this file (cwd-independent).
func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)     // …/Sources/usagecore-tests/CanonicalVersionTests.swift
        .deletingLastPathComponent()    // …/Sources/usagecore-tests
        .deletingLastPathComponent()    // …/Sources
        .deletingLastPathComponent()    // repo root
}

/// Runs Scripts/release-version.sh with /bin/bash; returns (exit status, stdout).
func runReleaseVersionScript(_ args: [String]) throws -> (status: Int32, stdout: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [repoRoot().appendingPathComponent("Scripts/release-version.sh").path] + args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

final class CanonicalVersionTests: XCTestCase {
    private let vectors = loadVersionVectors()
    private func of(_ kind: String) -> [VersionVector] { vectors.filter { $0.kind == kind } }

    /// Guards against a vacuous run: the fixture must load and keep its frozen shape.
    func testFixtureLoadsFrozenVectorCounts() {
        XCTAssertEqual(of("accept").count, 15)
        XCTAssertEqual(of("reject").count, 47)
        XCTAssertEqual(of("order").count, 13)
        XCTAssertEqual(vectors.count, 75)
        // the empty-string reject vector must survive TSV parsing as an empty input (not be skipped or merged)
        XCTAssertTrue(of("reject").contains { $0.input.isEmpty && $0.fields.first == "empty string" })
    }

    // F1 + F4: every accept vector parses and resolves to exactly the expected fields.
    func testAcceptVectorsResolveToExpectedFields() {
        for v in of("accept") {
            guard let c = CanonicalVersion(tag: v.input) else {
                XCTAssertTrue(false, "rejected canonical tag \(v.input)"); continue
            }
            let f = v.fields   // VERSION, CHANNEL, ITERATION|-, PRERELEASE, DISPLAY, ASSET
            XCTAssertEqual(c.core, f[0], v.input)
            XCTAssertEqual(c.channel.rawValue, f[1], v.input)
            XCTAssertEqual(c.iteration.map(String.init) ?? "-", f[2], v.input)
            XCTAssertEqual(c.isPrerelease ? "true" : "false", f[3], v.input)
            XCTAssertEqual(c.displayVersion, f[4], v.input)
            XCTAssertEqual(c.assetName, f[5], v.input)
            XCTAssertEqual(c.tag, v.input, "tag round-trips byte-exactly")
            XCTAssertEqual(CanonicalVersion(displayVersion: c.displayVersion), c, "display version round-trips")
        }
    }

    // F2: every reject vector (incl. all retired legacy forms) is refused by the tag parser.
    func testRejectVectorsAreRefused() {
        for v in of("reject") {
            XCTAssertNil(CanonicalVersion(tag: v.input), "accepted non-canonical [\(v.input)] (\(v.fields.first ?? ""))")
        }
    }

    // F3: semantic ordering — both directions, never lexical.
    func testOrderVectorsAreSemantic() {
        for v in of("order") {
            guard let lo = CanonicalVersion(tag: v.input), let hi = CanonicalVersion(tag: v.fields[0]) else {
                XCTAssertTrue(false, "order vector did not parse: \(v.input) / \(v.fields[0])"); continue
            }
            XCTAssertTrue(lo < hi, "\(lo) must be < \(hi)")
            XCTAssertFalse(hi < lo, "\(hi) must not be < \(lo)")
            XCTAssertFalse(lo == hi)
        }
        for v in of("accept") {
            guard let c = CanonicalVersion(tag: v.input) else { continue }
            XCTAssertFalse(c < c, "irreflexive: \(c)")
        }
        // owner examples, explicitly
        let t = { (s: String) in CanonicalVersion(tag: s)! }
        XCTAssertTrue(t("v0.1.1-alpha.1") > t("v0.1.0"))
        XCTAssertTrue(t("v0.2.0-alpha.1") > t("v0.1.9"))
        XCTAssertTrue(t("v0.1.0-alpha.10") > t("v0.1.0-alpha.2"), "numeric, not lexical")
        XCTAssertTrue(t("v0.1.0-rc.1") < t("v0.1.0"), "prerelease sorts below its stable")
    }

    // Swift ↔ bash parity: Scripts/release-version.sh agrees with CanonicalVersion on every vector.
    func testBashScriptAgreesWithSwiftOnEveryVector() throws {
        for v in vectors {
            switch v.kind {
            case "accept":
                guard let c = CanonicalVersion(tag: v.input) else { XCTAssertTrue(false, v.input); continue }
                let r = try runReleaseVersionScript([v.input])
                XCTAssertEqual(r.status, 0, "bash rejected \(v.input)")
                let want = ["RELEASE_TAG=\(c.tag)", "VERSION=\(c.core)", "RELEASE_CHANNEL=\(c.channel.rawValue)",
                            "RELEASE_ITERATION=\(c.iteration.map(String.init) ?? "")",
                            "PRERELEASE=\(c.isPrerelease)", "DISPLAY_VERSION=\(c.displayVersion)",
                            "ASSET_NAME=\(c.assetName)"].joined(separator: "\n") + "\n"
                XCTAssertEqual(r.stdout, want, "bash/Swift resolve mismatch for \(v.input)")
            case "reject":
                let r = try runReleaseVersionScript([v.input])
                XCTAssertEqual(r.status, 2, "bash accepted [\(v.input)]")
                XCTAssertEqual(r.stdout, "", "bash printed output for rejected [\(v.input)]")
            case "order":
                let lo = try runReleaseVersionScript(["--sort-key", v.input])
                let hi = try runReleaseVersionScript(["--sort-key", v.fields[0]])
                XCTAssertEqual(lo.status, 0)
                XCTAssertEqual(hi.status, 0)
                XCTAssertTrue(lo.stdout < hi.stdout, "bash sort keys disagree with Swift order: \(v.input) vs \(v.fields[0])")
            default:
                XCTAssertTrue(false, "unknown vector kind \(v.kind)")
            }
        }
    }

    // F5: asset / release tag / Homebrew cask URL agree mechanically for every canonical tag.
    func testAssetNameTagAndCaskURLAgreeMechanically() {
        let caskURLTemplate = "https://github.com/F-e-u-e-r/ai-pet-usage/releases/download/v#{version}/AI-Pet-Usage-v#{version}-arm64.zip"
        for v in of("accept") {
            guard let c = CanonicalVersion(tag: v.input) else { continue }
            // the release workflow's legacy label sanitizer ([^A-Za-z0-9._-] → "-") is the identity on canonical tags
            let sanitized = String(c.tag.map { ch -> Character in
                (ch.isASCII && (ch.isLetter || ch.isNumber)) || ch == "." || ch == "_" || ch == "-" ? ch : "-"
            })
            XCTAssertEqual(sanitized, c.tag)
            XCTAssertEqual(c.assetName, "AI-Pet-Usage-\(c.tag)-arm64.zip")
            XCTAssertEqual("v" + c.displayVersion, c.tag, "cask version = tag without v")
            let releaseURL = "https://github.com/F-e-u-e-r/ai-pet-usage/releases/download/\(c.tag)/\(c.assetName)"
            XCTAssertEqual(caskURLTemplate.replacingOccurrences(of: "#{version}", with: c.displayVersion), releaseURL)
        }
        let beta = CanonicalVersion(tag: "v0.1.0-beta.1")!
        XCTAssertEqual(beta.assetName, "AI-Pet-Usage-v0.1.0-beta.1-arm64.zip")
        XCTAssertEqual(beta.displayVersion, "0.1.0-beta.1")
        XCTAssertEqual(CanonicalVersion(tag: "v0.1.0")!.assetName, "AI-Pet-Usage-v0.1.0-arm64.zip")
    }
}
