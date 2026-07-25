# Releasing Phanttom

Phanttom ships as a free, self-updating macOS download — no Apple Developer
Program membership. The pieces:

- **Build/publish:** [`.github/workflows/phanttom-release.yml`](.github/workflows/phanttom-release.yml)
  builds the app (ad-hoc signed `ReleaseLocal` configuration), zips it as
  `Phanttom.app`, and publishes a GitHub Release with the zip and a Sparkle
  `appcast.xml`.
- **Update feed:** the app checks
  `https://github.com/NoahHendrickson/phanttom/releases/latest/download/appcast.xml`
  (see `UpdateDelegate.swift`). `releases/latest` always redirects to the
  newest non-prerelease, so publishing a release *is* pushing an update.
- **Trust model:** no Apple notarization, so users approve the app once at
  first launch (System Settings → Privacy & Security → Open Anyway). After
  that, updates are downloaded by Sparkle itself — no quarantine, no
  prompts — and verified against the fork's EdDSA key. Never ship an update
  signed with a different key: existing installs will reject it.
  Know the limit of that: the EdDSA signature protects the *update channel*,
  not the installed app. Ad-hoc signing means no Team ID and no library
  validation, so anything already running as the user can modify
  `Phanttom.app` (or inject a dylib) without breaking any check macOS makes
  after the first approval. Notarization with a Developer ID is the fix and
  changes nothing else about this pipeline — see the last section.
- **Release builds skip the Actions cache** (the two `actions/cache` steps are
  `if:`-gated off for `refs/tags/*`). A tag build is signed and then
  auto-installed by every user, so its inputs stay the checkout plus the
  toolchain rather than a cache blob written by an earlier run. Costs ~20 min
  instead of ~8; dispatch/prerelease runs still use the cache.

## One-time setup (Sparkle keys)

Sparkle updates are verified with an EdDSA keypair you generate yourself.
Run this once, on your own machine:

```bash
curl -fsSL -o /tmp/sparkle.tar.xz https://github.com/sparkle-project/Sparkle/releases/download/2.9.0/Sparkle-2.9.0.tar.xz
mkdir -p /tmp/sparkle && tar -xJf /tmp/sparkle.tar.xz -C /tmp/sparkle
/tmp/sparkle/bin/generate_keys
```

`generate_keys` stores the private key in your login Keychain and prints the
**public** key (a short base64 string). Then:

1. Paste the public key into `macos/Ghostty-Info.plist` as the value of
   `SUPublicEDKey` (it is intentionally empty in the repo), and commit it.
   Public keys are not secret.
2. Add both keys as repository secrets:

   ```bash
   /tmp/sparkle/bin/generate_keys -x /tmp/sparkle_private_key
   gh secret set SPARKLE_KEY_PUB --body "PASTE_PUBLIC_KEY_HERE"
   gh secret set SPARKLE_PRIVATE_KEY < /tmp/sparkle_private_key
   rm /tmp/sparkle_private_key
   ```

The private key lives in exactly two places: your Keychain (back it up!) and
the GitHub secret. Losing it means shipping a new key that existing installs
will refuse — users would have to re-download manually.

## Cutting a release

```bash
git tag v0.1.0
git push origin v0.1.0
```

CI takes it from there (~30–45 min). When the release is live, every running
Phanttom picks it up on its next update check; users click the pill in the
sidebar/titlebar and the app relaunches updated.

To test the pipeline **without** shipping to users, use *Run workflow*
(workflow_dispatch) on the Phanttom Release action: it publishes a
`tip-<build>` **prerelease**, which `releases/latest` ignores, so the update
feed is untouched. The optional **xcframework-target** input builds
GhosttyKit (and the app) for the runner's architecture only (`native`),
which is faster for pipeline testing; the zip is then named after the arch
(e.g. `phanttom-macos-arm64.zip`) instead of `…-universal.zip`. Tag
releases always build universal.

CI caches the Zig and Xcode build artifacts between runs (see the comments
in the workflow): a warm run takes ~8 min vs ~20 min cold. Caches are
branch-scoped, so the first run after a workflow change lands on `phanttom`
is cold once; tag builds restore the default branch's caches.

One quirk to know when re-running pipeline tests: a `tip-<build>` number is
derived from the commit count, so dispatching twice from the same commit
tries to recreate the same tag — delete the previous prerelease first, or
push a commit in between (GitHub has been seen to 403 a re-created release
tag name even after deletion).

Version plumbing: Sparkle compares `CFBundleVersion`, which CI stamps with
`git rev-list --count HEAD` — strictly increasing as long as history moves
forward. The tag (minus `v`) becomes the human-readable version.

## If you later join the Apple Developer Program

Keep this workflow; add Developer ID signing + notarization steps between
build and zip (crib from upstream's `release-tip.yml`, which has the full
recipe). Existing users pick up the signed build through a normal Sparkle
update — the EdDSA key, feed, and everything else stay the same.
