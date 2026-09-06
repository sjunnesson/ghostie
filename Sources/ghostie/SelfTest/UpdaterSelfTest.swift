import Foundation

/// Regression check for the OTA updater's pure parts — SemVer precedence and
/// the GitHub manifest parser. No network/disk/models, so it's green
/// everywhere (per CLAUDE.md selftest policy).
func runUpdaterSelfTest() -> Bool {
    var passed = 0, failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1; print("  ✓ \(name)") }
        else { failed += 1; print("  ✗ \(name)  \(detail())") }
    }
    func v(_ s: String) -> SemVer { SemVer.parse(s)! }

    check("equal versions are not an upgrade",
          !Updater.compare(running: v("1.2.0"), latest: v("1.2.0")))
    check("patch/minor/major bumps are upgrades",
          Updater.compare(running: v("1.2.0"), latest: v("1.2.1"))
          && Updater.compare(running: v("1.2.0"), latest: v("1.3.0"))
          && Updater.compare(running: v("1.9.0"), latest: v("2.0.0")))
    check("downgrade is never offered",
          !Updater.compare(running: v("1.3.0"), latest: v("1.2.0")))
    check("v / V prefix tolerated",
          v("v1.2.0") == v("1.2.0") && v("V1.2.0") == v("1.2.0"))
    check("short cores zero-pad",
          v("1.2") == v("1.2.0") && v("1") == v("1.0.0")
          && Updater.compare(running: v("1.2"), latest: v("1.2.1")))
    check("pre-release precedence (SemVer 2.0)",
          v("1.2.0-rc.1") < v("1.2.0")
          && v("1.2.0-rc.1") < v("1.2.0-rc.2")
          && v("1.2.0-alpha") < v("1.2.0-beta")
          && !Updater.compare(running: v("1.2.0"), latest: v("1.2.0-rc.1")))
    check("build metadata ignored", v("1.2.0+abc123") == v("1.2.0"))
    check("non-numeric version → nil",
          SemVer.parse("nightly") == nil && SemVer.parse("") == nil
          && SemVer.parse("v") == nil)

    func json(_ s: String) -> Data { Data(s.utf8) }
    let sha = String(repeating: "a", count: 64)
    let good = json("""
    {"tag_name":"v1.3.0","name":"Ghostie 1.3.0",
     "body":"Shiny new things.\\n<!--sha256:\(sha)-->",
     "assets":[{"name":"Ghostie-1.3.0.zip",
       "browser_download_url":"https://example.com/Ghostie-1.3.0.zip","size":4242}]}
    """)
    if let r = try? Updater.parseLatestJSON(good) {
        check("manifest: tag/asset/sha/size parsed",
              r.version == v("1.3.0")
              && r.assetURL.absoluteString == "https://example.com/Ghostie-1.3.0.zip"
              && r.sha256 == sha && r.expectedSize == 4242)
        check("manifest: sha comment stripped from notes",
              !r.notes.contains("sha256") && r.notes.contains("Shiny new things."))
    } else {
        check("manifest: tag/asset/sha/size parsed", false, "threw")
        check("manifest: sha comment stripped from notes", false, "threw")
    }
    let noAsset = json("""
    {"tag_name":"v1.3.0","body":"x <!--sha256:\(sha)-->",
     "assets":[{"name":"Other.zip","browser_download_url":"https://e/o.zip","size":1}]}
    """)
    check("manifest: missing matching asset throws",
          (try? Updater.parseLatestJSON(noAsset)) == nil)
    let noSha = json("""
    {"tag_name":"v1.3.0","body":"no checksum here",
     "assets":[{"name":"Ghostie-1.3.0.zip","browser_download_url":"https://e/g.zip","size":1}]}
    """)
    check("manifest: no sha → throws (never install unverified)",
          (try? Updater.parseLatestJSON(noSha)) == nil)
    let badTag = json("""
    {"tag_name":"nightly","body":"<!--sha256:\(sha)-->","assets":[]}
    """)
    check("manifest: unparseable tag throws",
          (try? Updater.parseLatestJSON(badTag)) == nil)

    // The website mirror (`/updates.json`) re-emits GitHub's field names so
    // this same parser reads it. Pinned here: if the route's shape ever drifts,
    // the app would silently fall back to GitHub forever and nobody would
    // notice until the rate limit bit again.
    let mirror = json("""
    {"tag_name":"v1.7.1","name":"Ghostie v1.7.1",
     "body":"## Ghostie v1.7.1\\n\\n- fix(audio)\\n\\n<!--sha256:\(sha)-->\\n",
     "published_at":"2026-08-30T07:00:27Z",
     "assets":[
       {"name":"Ghostie-1.7.1.sha256","browser_download_url":"https://e/s","size":65},
       {"name":"Ghostie-1.7.1.zip","browser_download_url":"https://e/Ghostie-1.7.1.zip","size":16874456},
       {"name":"Ghostie.dmg","browser_download_url":"https://e/d","size":19398141}]}
    """)
    if let r = try? Updater.parseLatestJSON(mirror) {
        check("mirror manifest parses like GitHub's",
              r.version == v("1.7.1") && r.sha256 == sha
              && r.assetName == "Ghostie-1.7.1.zip" && r.expectedSize == 16874456)
    } else {
        check("mirror manifest parses like GitHub's", false, "threw")
    }

    // Feed chain. GitHub's 60-per-hour is per IP and shared with every other
    // client on the network, so the mirror goes first.
    if ProcessInfo.processInfo.environment["GHOSTIE_UPDATE_FEED"] == nil {
        var cfg = Config()
        let chain = Updater.feedURLs(cfg).map(\.absoluteString)
        check("feeds: mirror first, GitHub as fallback",
              chain == [Updater.mirrorFeed, Updater.canonicalFeed], "\(chain)")
        cfg.updateFeedOverride = "https://example.test/feed.json"
        check("feeds: an explicit override replaces the chain (no silent fallback)",
              Updater.feedURLs(cfg).map(\.absoluteString) == ["https://example.test/feed.json"])
    }

    // Rate-limit classification. All three shapes GitHub actually sends have
    // to land on `.rateLimited`; a plain 403 must not.
    func isRateLimited(_ e: UpdateError) -> Bool {
        if case .rateLimited = e { return true }
        return false
    }
    func resetOf(_ e: UpdateError) -> Date? {
        if case .rateLimited(let d) = e { return d }
        return nil
    }
    func statusOf(_ e: UpdateError) -> Int? {
        if case .http(let c) = e { return c }
        return nil
    }
    let now = Date(timeIntervalSince1970: 1_788_368_000)
    let reset = 1_788_368_583.0

    let hourly = Updater.classify(
        status: 403,
        headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "\(Int(reset))"],
        now: now)
    check("403 + exhausted hourly budget → rate limited, with the reset time",
          isRateLimited(hourly)
          && resetOf(hourly)?.timeIntervalSince1970 == reset)

    let secondary = Updater.classify(
        status: 403, headers: ["Retry-After": "60"], now: now)
    check("403 + Retry-After (secondary limit) → rate limited",
          isRateLimited(secondary)
          && resetOf(secondary)?.timeIntervalSince1970 == now.timeIntervalSince1970 + 60)

    check("429 → rate limited even with no headers",
          isRateLimited(Updater.classify(status: 429, headers: [:], now: now)))

    check("header lookup is case-insensitive",
          isRateLimited(Updater.classify(
              status: 403, headers: ["x-ratelimit-remaining": "0"], now: now)))

    check("a plain 403 stays an HTTP error",
          statusOf(Updater.classify(status: 403, headers: [:], now: now)) == 403)
    check("403 with budget left stays an HTTP error",
          statusOf(Updater.classify(
              status: 403, headers: ["X-RateLimit-Remaining": "42"], now: now)) == 403)
    check("404 stays an HTTP error",
          statusOf(Updater.classify(status: 404, headers: [:], now: now)) == 404)

    check("rate-limit message names the network, not the user",
          (hourly.errorDescription ?? "").contains("this network"),
          hourly.errorDescription ?? "nil")
    check("a reset already in the past doesn't promise a stale time",
          (UpdateError.rateLimited(retryAfter: Date(timeIntervalSince1970: 1))
              .errorDescription ?? "").contains("try again shortly"))

    print("\nupdater self-test: \(passed) passed, \(failed) failed")
    return failed == 0
}
