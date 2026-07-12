# Releasing Ghostie

## How a release ships

Releases are cut by a person, on purpose — there is deliberately no CI
workflow. One command does everything:

```bash
./scripts/publish-release.sh X.Y.Z
```

It refuses to start unless: `gh` is authenticated with write access, the git
tree is clean, tag `vX.Y.Z` is free locally and on origin, and the
`ghostie-notary` notarytool keychain profile exists (see `build-app.sh`).
After an explicit typed confirmation it builds a notarized + stapled `.dmg`
and OTA app-zip, tags, pushes the tag, and publishes a GitHub Release whose
body embeds `<!--sha256:HEX-->` for the zip.

## How installed copies pick it up

`Updater.check` (on launch +20 s and ~daily, throttled by `lastUpdateCheck`)
fetches **`/repos/sjunnesson/ghostie/releases/latest`** — GitHub's alias for
the newest non-draft, non-prerelease release. Nothing is cached between
checks. An update is offered only when the release's semver is a **strict
upgrade** over the running version (`running < latest` — the updater never
downgrades), and installs only after the zip's SHA-256 matches the embedded
hash, `codesign` confirms the same Developer ID team, and Gatekeeper/`spctl`
confirms notarization. Installs never interrupt an active call.

## Yanking a bad release

There is no kill switch: every install polls `releases/latest`
independently, so within ~24 h of publishing, most active installs will have
seen it. Recovery has one reliable move — **publish a fixed higher version
immediately**:

1. Fix (or revert) on `main`.
2. `./scripts/publish-release.sh X.Y.(Z+1)` — the moment it's published,
   `releases/latest` points at it and every ~daily check offers it,
   including to users already running the bad build.
3. *Optionally* also delete the bad GitHub release **and its tag**
   (`gh release delete vX.Y.Z --yes && git push origin :refs/tags/vX.Y.Z`).

Why deleting alone is **not** enough:

- Users who already updated are running the bad build. Deleting its release
  makes `releases/latest` resolve to the *previous* version, but the updater
  never downgrades (`running < latest` fails) — those users would be
  stranded on the bad build forever. Only a higher version reaches them.
- Deleting does help users who haven't checked yet: their next check sees
  the previous release and correctly reports "up to date".

### Checklist

- [ ] Bad build confirmed — capture *what* is wrong before it's overwritten
- [ ] Fix/revert merged to `main`, selftest green (`ghostie selftest`)
- [ ] `./scripts/publish-release.sh X.Y.(Z+1)` (higher than the bad version)
- [ ] Spot-check: `curl -s https://api.github.com/repos/sjunnesson/ghostie/releases/latest | grep tag_name`
- [ ] Optionally delete the bad release + tag
- [ ] Verify one installed copy offers and applies the new version
      (`ghostie update`, then `ghostie update --install`)
