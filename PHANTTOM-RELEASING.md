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
feed is untouched.

Version plumbing: Sparkle compares `CFBundleVersion`, which CI stamps with
`git rev-list --count HEAD` — strictly increasing as long as history moves
forward. The tag (minus `v`) becomes the human-readable version.

## If you later join the Apple Developer Program

Keep this workflow; add Developer ID signing + notarization steps between
build and zip (crib from upstream's `release-tip.yml`, which has the full
recipe). Existing users pick up the signed build through a normal Sparkle
update — the EdDSA key, feed, and everything else stay the same.
