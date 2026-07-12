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

    print("\nupdater self-test: \(passed) passed, \(failed) failed")
    return failed == 0
}
