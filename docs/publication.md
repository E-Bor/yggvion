# Publication checklist

[Documentation](README.md) · [Contributing](../CONTRIBUTING.md)

This is a maintainer checklist for the first public source release. Preparing these files does not publish a repository, create a release or change hosting/account settings.

## Before making the repository public

- Choose a project license and add its unmodified standard text as `LICENSE`, with the correct copyright holder. Update the license sections in the README and contribution guide. Do not label the repository open source while this is unresolved.
- Confirm that project-authored code and artwork may be distributed, and preserve the notices in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).
- Review the **complete Git history**, including tags and branches, for credentials and private data. Inspect commit author names/emails as well as file contents. `.gitignore` affects future additions, not old commits.
- Rotate any real leaked credential before considering a history rewrite. Do not rewrite existing history or force-push without a separate decision. A fresh public repository without private development history is another option.
- Enable GitHub private vulnerability reporting (or provide a working private security contact), then confirm that [SECURITY.md](../SECURITY.md) points to a channel users can actually use.
- Inspect screenshots, fixtures and release assets for personal notes, real server addresses, invitation links and profile data. The README screenshot is rendered from real application widgets with synthetic English content and an isolated in-memory profile.
- Run the documented setup and checks in a clean checkout. The repository should not depend on local ignored files, an Apple Team or previously generated server assets to start in local/simulator mode.

## Current preparation review

At baseline commit `c73f68f`, a local pattern scan inspected **51 reachable commits / 1,061 text blobs** across all local refs. It looked for private-key headers, common provider tokens, credential URLs, secret assignments and absolute home-directory paths. The matches were confined to test files and README commands that generate a random pairing key. No matches for private-key headers or the provider-token patterns were found.

Tracked database, backup, private-key and signing-container paths were also checked. The Apple Team identifier was moved from tracked Xcode settings to an ignored local configuration. The Dropbox client identifier is intentionally public and is not an access token.

This was a targeted local review, not a guarantee that the repository contains no secrets. It does not inspect unpublished refs on a remote host, private hosting settings, arbitrary image contents, or credential formats outside those patterns. Re-run a dedicated secret scanner before publication and review its findings rather than suppressing all matches in tests. No history was rewritten.

The license choice and the repository's private vulnerability-reporting setting remain maintainer decisions. CI is intentionally absent; use the manual checks in [CONTRIBUTING.md](../CONTRIBUTING.md).

### Clean-source verification on 2026-10-30

The prepared source was copied to a separate temporary directory without ignored files, local signing settings, dependency caches or generated installer payloads. Dependencies were resolved from the machine's existing package caches.

- Flutter dependency resolution and analysis passed; all **449 client tests** passed with a separately built local Go server.
- `go test ./...` (with package concurrency limited to 4) and `go vet ./...` passed.
- All **11 installer fixture tests** and **7 public-calendar JavaScript tests** passed.
- Both Linux server payloads and their SHA-256 manifest were generated successfully from the clean source.
- iOS simulator configuration and CocoaPods setup succeeded. Xcode build settings for Runner and TrackingWidget were checked in Debug, Release and Profile: the clean copy had no Apple Team; the working checkout retained its team through the ignored local file.

This check did not compile a complete native release or run on a physical phone, real VPS or external backup account. It does not enable repository hosting settings or select a license.

## Before distributing binaries

- Build from a reviewed commit with the documented toolchain and lockfiles.
- Regenerate the Linux server payloads from that same source revision before building the Flutter app.
- Configure platform signing, application identifiers and OAuth registration for the publisher. Do not distribute Android releases with debug signing.
- Include complete third-party license notices for the bundled client, native components, fonts and Go payloads. Preserve source availability where required by dependency licenses.
- Test backup restoration with disposable data, invitations/sync between isolated profiles, installer rollback on a test VPS, and native notifications on supported platforms.
- Publish versioned artifacts with checksums and clear platform support notes. A checksum alone does not authenticate a release if its download page is compromised.
- Configure repository access, branch protection and release permissions for the actual maintainers. Do not give contributors production server or signing credentials.
