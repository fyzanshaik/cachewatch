# Releasing Cachewatch

Cachewatch supports two release modes. Without Apple credentials, the tag
workflow publishes an ad-hoc signed release and the installation instructions
disclose the required one-time Gatekeeper approval. If all Apple credentials are
configured, the workflow instead signs the native app with a Developer ID
Application certificate, submits it to Apple's notary service, staples the
ticket, and verifies the result with Gatekeeper before publication. Both modes
publish the GitHub release and open the Homebrew tap update pull request.

## One-time Apple setup

Notarized releases are optional. Enabling them requires an active Apple
Developer Program membership. If the project does not maintain a membership,
leave all five Apple secrets unset; partially configuring them fails the release
to prevent an ambiguous signing state.

1. In Xcode, open **Settings > Accounts**, add the release Apple ID, and select
   the Developer Program team.
2. Choose **Manage Certificates**, then create a **Developer ID Application**
   certificate. This is different from an Apple Development certificate.
3. In Keychain Access, export that certificate together with its private key as
   a password-protected `.p12` file.
4. Create an app-specific password for the release Apple ID at
   [account.apple.com](https://account.apple.com/).

Keep the `.p12` file and its password out of the repository.

## GitHub Actions secrets

Configure these repository Actions secrets:

| Secret | Value |
|---|---|
| `DEVELOPER_ID_APPLICATION_P12_BASE64` | Base64-encoded contents of the exported `.p12` file |
| `DEVELOPER_ID_APPLICATION_P12_PASSWORD` | Password used when exporting the `.p12` file |
| `APPLE_ID` | Apple ID used for notarization |
| `APPLE_TEAM_ID` | Ten-character Developer Program team identifier |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for the Apple ID |
| `TAP_GITHUB_TOKEN` | Fine-grained token with contents and pull-request access to `fyzanshaik/homebrew-tap` |

The workflow imports the certificate into a temporary keychain on the GitHub
runner. The runner is discarded after the job.

## Validate the workflow

Run the workflow manually before relying on tag publication:

```sh
gh workflow run Release --field version=0.0.0
gh run watch
```

A manual run builds and verifies the app and CLI archives, checks their
checksums, and renders the Homebrew definitions. It always uses ad-hoc signing
and never publishes a GitHub release, contacts Apple's notary service, or opens
a pull request in the tap repository.

## Publish

Run the normal test and local ad-hoc packaging checks before creating a tag:

```sh
swift test
scripts/package-release.sh 0.2.1 .build/release-dist
scripts/test-release-package.sh \
  .build/release-dist/Cachewatch-0.2.1-macos-arm64.zip \
  0.2.1
```

Then push an annotated `vX.Y.Z` tag. The release workflow is the only supported
publication path. After it completes, install the public cask on a clean Mac:

```sh
brew install --cask fyzanshaik/tap/cachewatch
open -a Cachewatch
```

For a notarized release, confirm that Gatekeeper accepts it without an override:

```sh
spctl --assess --type execute --verbose=4 /Applications/Cachewatch.app
```

For an ad-hoc signed release, confirm that Homebrew prints the disclaimer and
that the **Privacy & Security > Open Anyway** instructions work. Do not close a
Gatekeeper release issue as fixed unless a notarized public cask passes the
first check.
