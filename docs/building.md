# Building from source

[Documentation](README.md) · [Project overview](../readme.md) · [Manual checks](../CONTRIBUTING.md)

Commands assume the repository root unless a `cd` is shown. Use a separate checkout/profile when testing backup restore or destructive actions.

## Toolchain

The currently used versions are Flutter **3.38.8**, Dart **3.10.7** (included with Flutter), and Go **1.26.10**. Python 3 builds the optional server payloads and runs installer tests; Node.js runs the public calendar page tests.

Install the native tools for your target: Xcode/CocoaPods for Apple platforms, Android SDK/JDK for Android, Visual Studio with Desktop development with C++ for Windows, or the Flutter Linux desktop build dependencies. Run `flutter doctor -v` to identify missing platform tools. Windows and Linux native builds need their respective hosts.

## Local application

```sh
cd client
flutter pub get
flutter run -d macos
```

Use `flutter devices` and `flutter run -d <device-id>` for another installed target. The application stores data locally without a VPS. This repository does not ship a server address, user profile or production database.

## Client with the VPS installer

Generate the payloads before building or packaging the client:

```sh
python3 tool/build_server_bundle.py
cd client
flutter pub get
flutter build macos --release
```

The script builds Linux `amd64` and `arm64` Go binaries with `CGO_ENABLED=0`, copies the installer/uninstaller, and writes a SHA-256 manifest under `client/assets/server/`. These generated files are ignored by Git. Regenerate them after server changes; do not package stale payloads. An app built without them can be used locally but cannot install/update a VPS.

## iOS signing

Simulator builds do not need an Apple Team:

```sh
cd client
flutter build ios --simulator --debug
```

For a physical device, copy `client/ios/Flutter/Signing.example.xcconfig` to `Signing.local.xcconfig` in the same directory and replace `YOURTEAMID` with your Apple Team ID. The optional local file applies to Runner and TrackingWidget for Debug, Release and Profile, and is excluded from Git. Select provisioning compatible with your account in Xcode. Never commit certificates, provisioning profiles or account credentials.

An independently distributed fork needs its own application identifiers and signing setup. Keep the TrackingWidget identifier consistent with its containing app, and review URL schemes/entitlements when renaming the application. `Signing.local.xcconfig` only supplies the team; it does not register bundle identifiers or provision a device.

Android's current release configuration uses the development/debug signing configuration; configure your own release keystore before distributing an Android build. The Windows MSIX configuration also requires your own signing arrangements for distribution. Local builds are not store-ready release artifacts.

## Dropbox OAuth

The bundled Dropbox app key is a **public OAuth client identifier**, not a password or access token. No Dropbox app secret belongs in the client. Official builds use the included registration; independently distributed forks should create their own Dropbox application and set its public key at build time:

```sh
cd client
flutter run -d macos --dart-define=DROPBOX_APP_KEY=YOUR_PUBLIC_APP_KEY
```

Use Scoped access → App folder, the scopes `files.metadata.read`, `files.content.read`, `files.content.write`, and both exact redirect URIs:

```text
yggvion://oauth/dropbox
http://127.0.0.1:43827/dropbox
```

If a fork changes the app's URI scheme, update both its native registration and the OAuth redirect configuration. Passing `--dart-define=DROPBOX_APP_KEY=` disables new Dropbox connections in that build. It does not erase an existing server backup destination.

## Server API development

This mode is for local API work and tests; the current client UI connects through VPS installation or an invitation rather than a manually entered pairing key.

```sh
cd server
export YGGVION_PAIRING_KEY="$(openssl rand -hex 32)"
export YGGVION_LISTEN=127.0.0.1:8080
export YGGVION_DATA_DIR=./data
go run ./cmd/yggvion
```

`GET http://127.0.0.1:8080/health` checks the process. Keep this development HTTP listener on loopback. Production installation from the app configures private TLS, systemd and persistent storage; see the [VPS guide](synchronization.md#install-on-a-vps). Docker/Caddy is a separate [manual deployment option](synchronization.md#manual-docker-deployment).

The bootstrap pairing key must contain at least 32 characters and is not printed by the server. Retain it across restarts or replace it for future pairings; already-issued device tokens remain valid until revoked. This environment-based mode is used without an installer-managed `server.json`.

| Variable | Default / requirement | Purpose |
| --- | --- | --- |
| `YGGVION_PAIRING_KEY` | Required for environment-based bootstrap | Owner secret for pairing |
| `YGGVION_LISTEN` | `127.0.0.1:8080` | HTTP API listener |
| `YGGVION_DATA_DIR` | `data` | SQLite and attachment storage |
| `YGGVION_DOMAIN` | Required for Compose/Caddy | Public DNS name |

Private API routes require a device Bearer token except the credential-based pairing flow. The server stores token SHA-256 hashes. Consult the [API contract](../api/openapi.yaml) for exact request formats and limits.

## Regenerate branding

The approved shield/tree vector is `client/assets/branding/yggvion.svg`. It uses filled shapes and transparent cutouts; masks let the interface apply its accent color. The ignored `local/` directory contains development concepts and is not needed for a build.

From the repository root on macOS:

```sh
swift tools/generate_branding.swift
```

The script reproduces logo PNG masks, native icon sizes, Android vectors and the Windows ICO from the SVG. Seven alternate iOS icon sets are listed in `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` for every Runner configuration. Adding another accent requires updating both the generator palette and that list. Review the generated asset diff before including it in a release.

## Verification

Run the commands in [CONTRIBUTING.md](../CONTRIBUTING.md). The [testing guide](testing.md) describes suite coverage and the search benchmark. For native UI checks, use a simulator/emulator or a dedicated test profile. Unit/widget tests do not verify real OS notification delivery, store signing, Dropbox production approval or a hosting provider's firewall. Linux users can optionally install the [local reminder companion](platforms.md#linux-reminder-companion).
