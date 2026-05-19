import Foundation
import AppKit
import CryptoKit

/// In-app OTA self-update. Checks the project's GitHub Releases, and (on the
/// user's explicit request) downloads the new notarized build, verifies it
/// against Apple's trust chain + a published SHA-256, then swaps the running
/// `.app` bundle and relaunches.
///
/// Trust model: we don't ship a signing key. The installed app is Developer ID
/// signed (Team `6V9RN6W28J`) and notarized; the updater only accepts a
/// download that `codesign`/`spctl` confirm is signed by the same team and
/// notarized by Apple, plus the SHA-256 the release publishes. Builds that
/// aren't notarized Developer ID (from-source / ad-hoc / self-signed dev
/// builds) can't be verified that way, so they skip OTA entirely.
///
/// Threading mirrors `ModelDownloader`: a `URLSession` delegate plus callbacks
/// always marshalled to main. No actors / no `Sendable` (Swift-5 mode).

// MARK: - Semantic version (pure, selftest-able)

/// SemVer-2.0 precedence. Tolerates a leading `v`, short cores ("1.2"),
/// pre-release identifiers and build metadata. Build metadata is ignored for
/// ordering; a final release outranks any pre-release of the same core.
struct SemVer: Comparable, Equatable, CustomStringConvertible {
    let components: [Int]      // numeric release core, e.g. [1,2,0]
    let preRelease: [String]   // [] == final release
    let raw: String            // version string as parsed (no leading v)

    init(components: [Int], preRelease: [String] = [], raw: String? = nil) {
        self.components = components
        self.preRelease = preRelease
        self.raw = raw ?? (components.map(String.init).joined(separator: ".")
            + (preRelease.isEmpty ? "" : "-" + preRelease.joined(separator: ".")))
    }

    /// Parse "v1.2.0", "1.2", "1.2.0-rc.1+build". Returns nil if there's no
    /// numeric core (e.g. "nightly").
    static func parse(_ rawIn: String) -> SemVer? {
        var s = rawIn.trimmingCharacters(in: .whitespacesAndNewlines)
        if let f = s.first, f == "v" || f == "V" { s = String(s.dropFirst()) }
        guard !s.isEmpty else { return nil }
        let noBuild = s.split(separator: "+", maxSplits: 1,
                              omittingEmptySubsequences: false)[0]
        let dashParts = noBuild.split(separator: "-", maxSplits: 1,
                                      omittingEmptySubsequences: false)
        let core = dashParts[0]
        let pre = dashParts.count > 1
            ? dashParts[1].split(separator: ".").map(String.init) : []
        let nums = core.split(separator: ".").map { Int($0) }
        guard !nums.isEmpty, !nums.contains(where: { $0 == nil }) else { return nil }
        return SemVer(components: nums.compactMap { $0 }, preRelease: pre, raw: s)
    }

    static func < (a: SemVer, b: SemVer) -> Bool {
        let n = max(a.components.count, b.components.count)
        for i in 0..<n {
            let x = i < a.components.count ? a.components[i] : 0
            let y = i < b.components.count ? b.components[i] : 0
            if x != y { return x < y }
        }
        // Cores equal — apply pre-release precedence (SemVer §11.3/11.4).
        if a.preRelease.isEmpty && b.preRelease.isEmpty { return false }
        if a.preRelease.isEmpty { return false }  // final > any pre-release
        if b.preRelease.isEmpty { return true }
        let m = max(a.preRelease.count, b.preRelease.count)
        for i in 0..<m {
            if i >= a.preRelease.count { return true }   // shorter set is lower
            if i >= b.preRelease.count { return false }
            let ai = a.preRelease[i], bi = b.preRelease[i]
            switch (Int(ai), Int(bi)) {
            case let (.some(x), .some(y)): if x != y { return x < y }
            case (.some, .none):          return true    // numeric < alphanumeric
            case (.none, .some):          return false
            default:                      if ai != bi { return ai < bi }
            }
        }
        return false
    }

    static func == (a: SemVer, b: SemVer) -> Bool { !(a < b) && !(b < a) }
    var description: String { raw }
}

// MARK: - Parsed release

struct ReleaseInfo {
    let tag: String          // "v1.2.0"
    let version: SemVer
    let name: String         // release title (falls back to tag)
    let notes: String        // release body, sha comment stripped
    let assetURL: URL        // browser_download_url of Ghostie-<v>.zip
    let assetName: String
    let expectedSize: Int64  // assets[].size (sanity check; 0 = unknown)
    let sha256: String       // lowercased hex, from <!--sha256:…--> in body
}

enum UpdateAvailability {
    case upToDate(current: SemVer)
    case available(ReleaseInfo, current: SemVer)
    case skippedUnsupportedBuild
}

enum UpdateError: LocalizedError {
    case offline(String)
    case rateLimited
    case http(Int)
    case badManifest(String)
    case noUsableAsset
    case checksumMismatch(expected: String, got: String)
    case signatureInvalid(String)
    case notUpgradeable
    case appDirNotWritable(String)

    var errorDescription: String? {
        switch self {
        case .offline(let d):       return "Couldn't reach the update server (\(d))."
        case .rateLimited:          return "GitHub rate limit hit — try again later."
        case .http(let c):          return "Update check failed (HTTP \(c))."
        case .badManifest(let d):   return "Unreadable release manifest (\(d))."
        case .noUsableAsset:        return "The latest release has no verifiable Ghostie build."
        case .checksumMismatch(let e, let g):
            return "Download checksum mismatch (expected \(e.prefix(12))…, got \(g.prefix(12))…)."
        case .signatureInvalid(let d):
            return "Downloaded build failed verification: \(d)"
        case .notUpgradeable:
            return "This build can't self-update (not a notarized Developer ID build). Download the latest from GitHub Releases."
        case .appDirNotWritable(let p):
            return "Can't replace \(p) — move Ghostie to a writable location (drag it to /Applications) and update again."
        }
    }
}

// MARK: - Updater

final class Updater: NSObject, URLSessionDownloadDelegate {

    static let teamID = "6V9RN6W28J"
    static let canonicalFeed =
        "https://api.github.com/repos/sjunnesson/ghostie/releases/latest"
    static let releasesPage =
        URL(string: "https://github.com/sjunnesson/ghostie/releases")!
    static let assetPrefix = "Ghostie"

    // MARK: Pure helpers (selftest-able, no I/O)

    static func runningVersion() -> SemVer {
        let s = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return SemVer.parse(s ?? "1.0.0") ?? SemVer(components: [1, 0, 0])
    }

    /// True iff `latest` is a strict upgrade over `running` (downgrade- and
    /// pre-release-protected via SemVer precedence).
    static func compare(running: SemVer, latest: SemVer) -> Bool { running < latest }

    /// Parse GitHub's `releases/latest` JSON. Pure over `Data` so the selftest
    /// can feed a fixture. Throws rather than ever returning an unverifiable
    /// release (no checksum ⇒ no install).
    static func parseLatestJSON(_ data: Data,
                                assetPrefix: String = Updater.assetPrefix) throws -> ReleaseInfo {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw UpdateError.badManifest("not a JSON object") }
        guard let tag = obj["tag_name"] as? String,
              let version = SemVer.parse(tag) else {
            throw UpdateError.badManifest("missing or unparseable tag_name")
        }
        let body = (obj["body"] as? String) ?? ""
        let title = (obj["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tag

        let verStr: String = {
            if let f = tag.first, f == "v" || f == "V" { return String(tag.dropFirst()) }
            return tag
        }()
        let wantName = "\(assetPrefix)-\(verStr).zip"
        guard let assets = obj["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String) == wantName }),
              let urlStr = asset["browser_download_url"] as? String,
              let url = URL(string: urlStr) else {
            throw UpdateError.noUsableAsset
        }
        let size = (asset["size"] as? Int64)
            ?? Int64((asset["size"] as? Int) ?? 0)

        guard let sha = Self.extractSHA(from: body) else {
            throw UpdateError.noUsableAsset
        }
        let cleanNotes = Self.stripSHAComment(from: body)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ReleaseInfo(tag: tag, version: version, name: title,
                           notes: cleanNotes, assetURL: url, assetName: wantName,
                           expectedSize: size, sha256: sha.lowercased())
    }

    /// `<!--sha256:HEX-->` (64 hex chars) embedded in the release body.
    static func extractSHA(from body: String) -> String? {
        guard let re = try? NSRegularExpression(
            pattern: #"<!--\s*sha256:\s*([0-9a-fA-F]{64})\s*-->"#) else { return nil }
        let ns = body as NSString
        guard let m = re.firstMatch(
                in: body, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    static func stripSHAComment(from body: String) -> String {
        body.replacingOccurrences(
            of: #"<!--\s*sha256:\s*[0-9a-fA-F]{64}\s*-->"#,
            with: "", options: .regularExpression)
    }

    // MARK: Build eligibility

    /// True only when the *running* bundle is a notarized Developer ID build
    /// signed by our team — the only builds OTA can cryptographically verify.
    static func runningBuildSupportsOTA() -> Bool {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else { return false }
        guard run("/usr/bin/codesign",
                  ["--verify", "--deep", "--strict", path]).status == 0
        else { return false }
        let info = run("/usr/bin/codesign", ["-dvvv", path]).output
        guard info.contains("TeamIdentifier=\(teamID)") else { return false }
        // Notarized? spctl accepts, or a stapled ticket validates offline.
        let spctl = run("/usr/sbin/spctl",
                        ["--assess", "--type", "execute", "--verbose=4", path])
        if spctl.output.contains("accepted") { return true }
        return run("/usr/bin/xcrun", ["stapler", "validate", path]).status == 0
    }

    static func feedURL(_ config: Config) -> URL {
        let env = ProcessInfo.processInfo.environment["GHOSTIE_UPDATE_FEED"]
        if let env, !env.isEmpty, let u = URL(string: env) { return u }
        let o = config.updateFeedOverride?.trimmingCharacters(in: .whitespaces) ?? ""
        if !o.isEmpty, let u = URL(string: o) { return u }
        return URL(string: canonicalFeed)!
    }

    // MARK: Check

    /// Fetch the latest release and compare with the running version.
    /// `completion` is delivered on the main queue.
    func check(config: Config,
               completion: @escaping (Result<UpdateAvailability, Error>) -> Void) {
        if !Updater.runningBuildSupportsOTA() {
            DispatchQueue.main.async { completion(.success(.skippedUnsupportedBuild)) }
            return
        }
        var req = URLRequest(url: Updater.feedURL(config))
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Ghostie-Updater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            let done: (Result<UpdateAvailability, Error>) -> Void = { r in
                DispatchQueue.main.async { completion(r) }
            }
            if let err = err as? URLError {
                done(.failure(UpdateError.offline(err.localizedDescription))); return
            }
            if let err = err {
                done(.failure(UpdateError.offline(err.localizedDescription))); return
            }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                if http.statusCode == 403,
                   (http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0") {
                    done(.failure(UpdateError.rateLimited)); return
                }
                done(.failure(UpdateError.http(http.statusCode))); return
            }
            guard let data = data else {
                done(.failure(UpdateError.badManifest("empty response"))); return
            }
            do {
                let release = try Updater.parseLatestJSON(data)
                let current = Updater.runningVersion()
                Self.recordCheckTime()
                if Updater.compare(running: current, latest: release.version) {
                    done(.success(.available(release, current: current)))
                } else {
                    done(.success(.upToDate(current: current)))
                }
            } catch { done(.failure(error)) }
        }
        task.resume()
    }

    private static func recordCheckTime() {
        var c = Config.loadRaw()
        c.lastUpdateCheck = Date()
        c.save()
    }

    // MARK: Download + verify + install

    private var session: URLSession?
    private var dest: URL?
    private var release: ReleaseInfo?
    private weak var engine: Engine?
    private var onStatus: ((String) -> Void)?
    private var onFinish: ((Error?) -> Void)?
    private var onCommit: (() -> Void)?
    private var finished = false
    private(set) var isRunning = false

    /// Download `release`, verify it, then swap the running bundle.
    /// `commit` is invoked once the detached swap helper is launched and is
    /// responsible for terminating this process (the helper waits for our PID
    /// to exit, then relaunches). `finish(err)` fires only on failure or when
    /// the install is postponed-then-cancelled; on success the process ends.
    func downloadAndInstall(_ release: ReleaseInfo,
                            engine: Engine?,
                            status: @escaping (String) -> Void,
                            finish: @escaping (Error?) -> Void,
                            commit: @escaping () -> Void) {
        guard !isRunning else { return }
        isRunning = true; finished = false
        self.release = release
        self.engine = engine
        self.onStatus = status
        self.onFinish = finish
        self.onCommit = commit

        let dir = URL(fileURLWithPath: Config.updatesDir)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dest = dir.appendingPathComponent(release.assetName)

        post("Downloading \(release.tag)… 0%")
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForResource = 1800
        cfg.waitsForConnectivity = true
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        s.downloadTask(with: release.assetURL).resume()
    }

    func cancel() {
        guard isRunning else { return }
        finished = true; isRunning = false
        session?.invalidateAndCancel(); session = nil
    }

    private func post(_ s: String) {
        let cb = onStatus
        DispatchQueue.main.async { cb?(s) }
    }

    private func fail(_ e: Error) {
        guard !finished else { return }
        finished = true; isRunning = false
        session?.finishTasksAndInvalidate(); session = nil
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: Config.updatesDir))
        let cb = onFinish
        DispatchQueue.main.async { cb?(e) }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                     didWriteData _: Int64, totalBytesWritten w: Int64,
                     totalBytesExpectedToWrite e: Int64) {
        guard let tag = release?.tag else { return }
        func mb(_ b: Int64) -> String {
            b >= 1_000_000 ? "\(b / 1_000_000) MB" : "\(max(0, b) / 1000) KB"
        }
        if e > 0 {
            post("Downloading \(tag)… \(Int(Double(w) / Double(e) * 100))%  (\(mb(w))/\(mb(e)))")
        } else {
            post("Downloading \(tag)… \(mb(w))")
        }
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask,
                     didFinishDownloadingTo loc: URL) {
        guard let dest = dest else { return }
        if let http = t.response as? HTTPURLResponse, http.statusCode != 200 {
            fail(UpdateError.http(http.statusCode)); return
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: loc, to: dest)
        } catch { fail(error); return }
        // Verification + swap off the delegate queue.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.verifyAndSwap()
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask,
                     didCompleteWithError error: Error?) {
        if let error = error, !finished { fail(error) }
    }

    // MARK: Verification

    private func verifyAndSwap() {
        guard let dest = dest, let release = release else { return }
        let fm = FileManager.default

        post("Verifying download…")
        // 1. SHA-256 + size.
        guard let zipData = try? Data(contentsOf: dest) else {
            fail(UpdateError.signatureInvalid("couldn't read download")); return
        }
        if release.expectedSize > 0, Int64(zipData.count) != release.expectedSize {
            fail(UpdateError.signatureInvalid("size mismatch")); return
        }
        let got = SHA256.hash(data: zipData)
            .map { String(format: "%02x", $0) }.joined()
        guard got == release.sha256 else {
            fail(UpdateError.checksumMismatch(expected: release.sha256, got: got)); return
        }

        // 2. Unpack.
        let unpack = URL(fileURLWithPath: Config.updatesDir)
            .appendingPathComponent("unpacked")
        try? fm.removeItem(at: unpack)
        guard Self.run("/usr/bin/ditto",
                       ["-x", "-k", dest.path, unpack.path]).status == 0 else {
            fail(UpdateError.signatureInvalid("could not unpack archive")); return
        }
        let app = unpack.appendingPathComponent("Ghostie.app")
        guard fm.fileExists(atPath: app.path) else {
            fail(UpdateError.signatureInvalid("archive has no Ghostie.app")); return
        }

        // 3. codesign structural verify.
        let cs = Self.run("/usr/bin/codesign",
                          ["--verify", "--deep", "--strict", "--verbose=2", app.path])
        guard cs.status == 0 else {
            fail(UpdateError.signatureInvalid("codesign verify failed")); return
        }
        // 4. Team identity (two independent checks).
        let info = Self.run("/usr/bin/codesign", ["-dvvv", app.path]).output
        guard info.contains("TeamIdentifier=\(Updater.teamID)") else {
            fail(UpdateError.signatureInvalid("unexpected signing team")); return
        }
        let req = "=anchor apple generic and certificate leaf[subject.OU] = \"\(Updater.teamID)\""
        guard Self.run("/usr/bin/codesign",
                       ["--verify", "--deep", "--strict", "-R", req, app.path]).status == 0 else {
            fail(UpdateError.signatureInvalid("designated-requirement check failed")); return
        }
        // 5. Notarization / Gatekeeper.
        let spctl = Self.run("/usr/sbin/spctl",
                             ["--assess", "--type", "execute", "--verbose=4", app.path])
        let stapled = Self.run("/usr/bin/xcrun", ["stapler", "validate", app.path]).status == 0
        guard spctl.output.contains("accepted") || stapled else {
            fail(UpdateError.signatureInvalid("not notarized / Gatekeeper rejected")); return
        }
        // 6. Drop quarantine (best effort).
        _ = Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])

        proceedToSwap(verifiedApp: app)
    }

    // MARK: Swap & relaunch

    private func proceedToSwap(verifiedApp app: URL) {
        if let engine = engine, !engine.swapIsSafe() {
            post("Update ready — will install when the current call finishes…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, self.isRunning else { return }
                self.proceedToSwap(verifiedApp: app)
            }
            return
        }

        let installed = Bundle.main.bundlePath
        guard installed.hasSuffix(".app") else {
            // Not running from a bundle (CLI from a build dir) — nothing to swap.
            revealForManualInstall(app)
            fail(UpdateError.appDirNotWritable(installed)); return
        }
        let parent = (installed as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else {
            revealForManualInstall(app)
            fail(UpdateError.appDirNotWritable(installed)); return
        }

        post("Installing — Ghostie will restart…")
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let script = """
        #!/bin/bash
        set -e
        PID="$1"; SRC="$2"; DEST="$3"; SELF="$0"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        DIR="$(dirname "$DEST")"
        TMP="$DIR/.Ghostie.app.incoming.$$"
        OLD="$DIR/.Ghostie.app.old.$$"
        rm -rf "$TMP" "$OLD"
        /usr/bin/ditto "$SRC" "$TMP"
        mv "$DEST" "$OLD"
        mv "$TMP" "$DEST" || { mv "$OLD" "$DEST"; rm -f "$SELF"; exit 1; }
        rm -rf "$OLD"
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
        /usr/bin/open "$DEST"
        rm -f "$SELF"
        """
        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghostie-update-\(UUID().uuidString).sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            fail(UpdateError.signatureInvalid("could not stage installer")); return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptURL.path, pid, app.path, installed]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            fail(UpdateError.signatureInvalid("could not launch installer")); return
        }

        finished = true; isRunning = false
        let cb = onCommit
        DispatchQueue.main.async { cb?() }   // caller terminates; helper relaunches
    }

    private func revealForManualInstall(_ app: URL) {
        DispatchQueue.main.async {
            NSWorkspace.shared.activateFileViewerSelecting([app])
            NSWorkspace.shared.open(Updater.releasesPage)
        }
    }

    // MARK: Process helper

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
