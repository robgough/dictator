# Releasing Dictator

The release pipeline lives at `.github/workflows/release.yml`. It triggers on `v*` tag pushes (or via the *Run workflow* button) and produces a signed, notarized, Sparkle-signed DMG on the matching GitHub Release. This document is the one-time setup checklist that has to happen before that workflow can run end-to-end.

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
git tag v0.2.0
git push origin v0.2.0
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

## Version numbering

`MARKETING_VERSION` (e.g. `0.2.0`) is derived from the tag — push `v0.2.0` and you get `0.2.0`. `CURRENT_PROJECT_VERSION` (the build number) is the GitHub Actions run number, which monotonically increases — Sparkle uses this to compare which build is newer when two builds share a marketing version.
