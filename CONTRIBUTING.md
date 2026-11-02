# Contributing to Yggvion

Bug reports, documentation improvements and focused fixes are welcome. For a larger feature or architectural change, first describe the problem and proposed behavior in an issue. English and Russian are both welcome.

## Development setup

Start with [building from source](docs/building.md). The client can run without a server. The synchronization tests use isolated temporary profiles and a server on localhost; do not point tests at a personal VPS or an existing application database.

Keep changes focused. Follow the existing Riverpod/repository structure, update translations when changing visible text, and preserve the API contract in `api/openapi.yaml`. Add regression tests for defects and meaningful new behavior. Do not edit generated model or plugin files by hand.

## Local agent instructions

[AGENTS.md.example](AGENTS.md.example) contains shared guidance for AI-assisted development. If you do not already have a local `AGENTS.md`, copy the template from the repository root:

```sh
cp AGENTS.md.example AGENTS.md
```

Customize `AGENTS.md` for your tools and environment. It is ignored by Git; contribute general improvements to the example instead. Agents do not automatically load the `.example` file.

## Manual checks

Run the following from the repository root on macOS/Linux. `mktemp` keeps the test server separate from an installed application.

```sh
export YGGVION_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yggvion-check.XXXXXX")"
cd server
go test ./...
go vet ./...
go build -o "$YGGVION_CHECK_DIR/yggvion-test-server" ./cmd/yggvion
cd ../client
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
YGGVION_TEST_SERVER="$YGGVION_CHECK_DIR/yggvion-test-server" flutter test --concurrency=4
```

Use `go test -race ./...` for changes involving concurrent server work. Format edited Go files with `gofmt` and edited Dart files with `dart format`. Do not run `go mod tidy` or upgrade dependencies as an unrelated cleanup.

Additional checks, from the repository root:

```sh
python3 tool/test_installer.py
node --test tool/test_calendar_localization.mjs
```

The installer tests use fake system commands and temporary directories. They do not install a service on your computer or prove compatibility with every VPS image. Flutter widget tests do not require a physical phone. Without `YGGVION_TEST_SERVER`, integration tests that need the Go server are skipped; a skipped test is not a successful synchronization check.

For a visual change, inspect the affected screen before updating a golden image. Include the target platform and the checks you actually ran in the pull request. For API changes, update the server, client, contract and relevant tests together.

## Data and credentials

Use synthetic names, tasks, addresses and files in tests and screenshots. Do not include real notes, application databases, backups, invitation links, access tokens, passwords, signing keys or server configuration. Review both `git diff` and `git diff --cached` before committing. Local Apple signing settings belong in the ignored `Signing.local.xcconfig` file.

Follow [SECURITY.md](SECURITY.md) for security reports. Do not test destructive operations, load attacks or recovery procedures against somebody else's server.

Project-authored code is licensed under [PolyForm Noncommercial 1.0.0](LICENSE). Contributions must be compatible with these terms. This is a source-available project with a noncommercial restriction, not an OSI open-source license. Dependencies and third-party files retain their existing license notices. See the [publication checklist](docs/publication.md) before publishing a fork or other distribution.
