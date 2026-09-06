# Releasing Dictator

The release pipeline lives at `.github/workflows/release.yml`. It triggers on `v*` tag pushes (or via the *Run workflow* button) and produces a signed, notarized, Sparkle-signed DMG on the matching GitHub Release. This document is the one-time setup checklist that has to happen before that workflow can run end-to-end.

The same workflow also ships **Dictator Meetings**, the standalone meeting-notes app, off `meetings-v*` tags — see [Cutting a Dictator Meetings release](#cutting-a-dictator-meetings-release) below. Both apps share the Apple signing cert, notary credentials, and Sparkle EdDSA keypair, so the one-time setup below covers both; they publish to separate GitHub Releases, separate appcasts (`docs/appcast.xml` vs `docs/appcast-meetings.xml`), and separate changelogs (`CHANGELOG.md` vs `CHANGELOG-Meetings.md`).

## One-time setup

### 1. Apple Developer Program

The Personal Team tier (free) only issues *Apple Development* certs, which can't be notarized. Distribution requires a **Developer ID Application** cert, which only exists on the paid Apple Developer Program ($99/year). Enrol at <https://developer.apple.com/programs/>.

### 2. Developer ID Application certificate

Once enrolled:

1. Xcode → Settings → Accounts → your Apple ID → Manage Certificates → **+** → *Developer ID Application*.
2. In Keychain Access, find the new cert + its private key, select both, right-click → *Export Items…* → save as `dictator-developerid.p12`. Set a strong password — you'll paste it into a secret.
3. Base64-encode the file: `base64 -i dictator-developerid.p12 | pbcopy`.

### 3. App-specific password for `notarytool`

1. <https://appleid.apple.com> → Sign-In and Security → *App-Specific Passwords* → generate one labelled "Dictator notarytool".
2. Copy the password somewhere safe before closing the dialog — it's only shown once.

### 4. Sparkle EdDSA keypair

Run once locally after the first `./gen` (which pulls Sparkle via SPM):

```bash
# Path varies slightly by Xcode version; find generate_keys under DerivedData:
find ~/Library/Developer/Xcode/DerivedData -name generate_keys -path '*/Sparkle*' 2>/dev/null

# Run it. By default it stores the private key in your Keychain and prints
# the public key to stdout. The -p flag also prints the private key — paste
# that into the SPARKLE_PRIVATE_KEY GitHub secret.
/path/to/generate_keys -p
```

Take the **public key** from the output and paste it into both places `SUPublicEDKey` appears:

- `project.yml` → `targets.Dictator.info.properties.SUPublicEDKey`
- `Sources/Dictator/Info.plist` → `<key>SUPublicEDKey</key>`

(Both exist because `xcodegen` regenerates the plist from `project.yml`; keeping the static plist in sync means a fresh clone builds without a pre-`./gen` step.)

Take the **private key** (the long base64 string after `-p`) and paste it into the `SPARKLE_PRIVATE_KEY` GitHub Actions secret in the next step.

### 5. GitHub Actions secrets

At <https://github.com/robgough/dictator/settings/secrets/actions>, add:

| Secret                      | Value                                                                   |
| --------------------------- | ----------------------------------------------------------------------- |
| `APPLE_TEAM_ID`             | 10-char team ID (Xcode → Settings → Accounts → your team)              |
| `APPLE_CERT_P12_BASE64`     | The base64 string from step 2                                           |
| `APPLE_CERT_P12_PASSWORD`   | The password you set when exporting the .p12 in step 2                  |
| `APPLE_NOTARY_USER`         | Your Apple ID email                                                     |
| `APPLE_NOTARY_PASSWORD`     | The app-specific password from step 3                                   |
| `SPARKLE_PRIVATE_KEY`       | The private key from step 4                                             |

Until `APPLE_NOTARY_PASSWORD` is set the workflow skips notarization and emits a warning — the DMG still builds and uploads, but users get Gatekeeper warnings on first launch.

### 6. DNS for `dictator.robgough.net`

At your DNS host for `robgough.net`, add a record:

| Type  | Name      | Value                |
| ----- | --------- | -------------------- |
| CNAME | `dictator`| `robgough.github.io` |

Then at <https://github.com/robgough/dictator/settings/pages>:

- **Source**: *Deploy from a branch* → branch `main`, folder `/docs`.
- **Custom domain**: `dictator.robgough.net`.
- Tick **Enforce HTTPS** once the cert finishes provisioning (a few minutes after DNS propagates).

The `docs/CNAME` file is committed so GitHub Pages remembers the custom domain across redeploys.

## Cutting a release

```bash
git tag v2026.5.1
git push origin v2026.5.1
```

That triggers `.github/workflows/release.yml`. The workflow will:

1. Import the Developer ID cert into a throwaway keychain.
2. `./gen` + Release-config build, signed with that cert.
3. Notarize the .app (if the notary secrets are set).
4. Package into a signed, notarized DMG.
5. EdDSA-sign the DMG for Sparkle.
6. Create the matching GitHub Release and upload the DMG.
7. Append the entry to `docs/appcast.xml` and push it to `main`.

End users running an older version see the update offer the next time Sparkle's scheduled check runs (or when they click *Check for Updates…* in the menu bar).

For a dry run without pushing a tag, use the *Run workflow* button on the Actions tab and pass the version manually.

## Cutting a Dictator Meetings release

```bash
git tag meetings-v2026.9.0
git push origin meetings-v2026.9.0
```

The `meetings-v*` prefix routes the push to the `release-meetings` job instead of `release` — everything else about the flow is the same shape, aimed at different files:

1. Builds scheme `DictatorMeetings` (product `Dictator Meetings.app`), signed with the same Developer ID cert.
2. Notarizes and staples it (same notary credentials).
3. Packages `Dictator-Meetings.dmg` (the stable, unversioned asset name the site and Sparkle enclosure link to — analogous to `Dictator.dmg`).
4. EdDSA-signs it with the same Sparkle private key (both apps' `SUPublicEDKey` are identical, so one keypair signs both).
5. Creates the GitHub Release tagged `meetings-v2026.9.0` and uploads the DMG.
6. Appends the entry to `docs/appcast-meetings.xml` and versions `CHANGELOG-Meetings.md`.
7. Updates the Dictator Meetings download anchor on the marketing site and pushes everything back to `main`.

For a dry run, use *Run workflow* on the Actions tab, pick **meetings** from the `app` dropdown, and pass the version manually.

## Version numbering

Calendar versioning: `YYYY.MONTH.PATCH`. MONTH bumps when you cut a release in a new calendar month; PATCH increments for bugfixes within the same month. `MARKETING_VERSION` is derived from the tag — push `v2026.5.1` and you get `2026.5.1`. `CURRENT_PROJECT_VERSION` (the build number) is the GitHub Actions run number, which monotonically increases — Sparkle uses this to compare which build is newer when two builds share a marketing version.
