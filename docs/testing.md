# Testing and validation

[Documentation](README.md) · [Contributing](../CONTRIBUTING.md) · [Publication checklist](publication.md)

Contributor checks run manually; there is no CI on ordinary pushes or pull requests. Use synthetic data and isolated profiles; never point recovery or integration tests at a personal application database or VPS.

## Run the checks

[CONTRIBUTING.md](../CONTRIBUTING.md#manual-checks) contains the complete command sequence for Go tests/vet, building a local test server, Flutter formatting/analysis and the client test suite. Set `YGGVION_TEST_SERVER` to that binary to enable integration tests. Without it, server-dependent tests are explicitly skipped; this does not count as a successful synchronization check.

Use `go test -race ./...` for concurrency changes. Installer and public-page checks run from the repository root:

```sh
python3 tool/test_installer.py
node --test tool/test_calendar_localization.mjs
```

For dependency security checks, run `govulncheck ./...` from `server/` with the scanner installed. A previous scan is not evidence that current dependencies remain free of reachable vulnerabilities. Keep the documented Go toolchain and deployment image updated together.

## What the suites cover

| Area | Coverage |
| --- | --- |
| Synchronization | A real Go process on a random localhost port, independent temporary client databases, queues larger than 100 records, parent dependencies, bidirectional changes, retries and conflicting edits. |
| Tasks and recurrence | Unplanning, future-occurrence deletion, time zones/DST, colors, birthdays, completion and deletion. |
| Calendar and planner | Touch creation/move/resize, short-event controls, exact time markers, edge scroll/page changes, midnight transitions, mobile swipes and multi-interval manual tracking. |
| Notes and navigation | Live Preview editing, selection/focus, mobile keyboard exit, autosave, shortcuts after editing/dialogs/search, folders and project filters. |
| Settings and layout | Autosave validation, independent calendar views, resizing panels, sidebar collapse, light/dark themes and 1440/390-pixel layouts. |
| Clipboard and files | Mocked native representations plus real temporary files: multiple files, images/PDF/unknown extensions, read failures, cursor preservation and size limits. |
| Notifications | Mocked native notification channel: permissions, scheduling, movement/cancellation, removal of obsolete birthday reminders and retry after errors. |
| Server access | Authentication/revocation, invitation expiry and concurrent one-use consumption, generation checks, private TLS CA/IP rejection and renewal. |
| Backup validation | Damaged archives, bad checksums, path traversal, restore behavior and preservation of revoked devices. |
| Calendar sharing | Anonymous response content, expiry/revocation, concurrent limits, duplicate submissions, SQL/HTML input, proposal reservations/status privacy and the separate TLS handler. |

Attachment HTTP tests include unchanged arbitrary bytes, a file exactly 300 MiB, rejection one byte above the limit with and without `Content-Length`, SHA-256 verification and temporary-file cleanup. Client checks cover the same user-file boundary through file and clipboard input.

Installer tests replace operating-system commands and use temporary directories. They cover fresh installation, upgrades, an occupied port, damaged payloads, safety-snapshot failure and rollback after startup failures. They do not run real systemd or prove every VPS image works. SFTP tests use real local SSH/SFTP connections with matching and mismatching host keys.

### Encryption and recovery suites

| Client test | Focus |
| --- | --- |
| `encryption_test.dart` | Altered ciphertext/metadata, wrong keys, damaged/reordered/truncated file chunks. |
| `password_test.dart` | Repeatable derivation, wrong passwords, random salts and KDF parameter bounds. |
| `e2ee_sync_integration_test.dart` | Real server and separate profiles: pairing, password changes with a lost response, a third device, offline edits, files, retries, large queues, public snapshots and encrypted proposal acceptance. |
| `server_admin_integration_test.dart` | Private TLS and three clients, including first connection after restore; `snapshot_cursor` closes restored timers without closing newly started ones. |
| `local_backup_test.dart` | Recovery from only file/password and preservation of the current password when restoring older data. |
| `encryption_settings_test.dart` | Desktop/mobile errors and repeated-click protection. |
| `password_recovery_test.dart` | Reopening after restart without Keychain. |
| `calendar_sharing_integration_test.dart` | Real Go server and two clients exercising the sharing workflow. |

Go tests also exercise generation/cursor checks, atomic encrypted-dataset replacement and password parameters restored from snapshots. These are implementation checks, not an independent cryptographic audit.

## Visual checks

Existing UI references live in `client/test/goldens/`. Inspect affected screens before accepting a changed reference. The [README screenshot](images/desktop.png) is rendered from real application widgets with an isolated in-memory profile and synthetic English content; it is not a screenshot of a personal workspace.

For iOS automation, use an **iPhone simulator**. The owner's physical iPhone is reserved for manual UX checks; do not install diagnostic builds or run tests on it without an explicit request. Experimental entry points belong in a separate local copy so they do not change `FLUTTER_TARGET` in the working app.

## Search benchmark

From `client/`:

```sh
flutter test --no-pub tool/search_benchmark.dart --reporter expanded
```

The benchmark creates a temporary dataset of **50,000 synthetic notes/events** with roughly 150,000 distinct words, upgrades an old v5 index and measures complete local searches through the background SQLite connection. It does not open the user's database.

Previously recorded local macOS measurements were approximately 3–8 ms median for typical repeated queries, 28 ms for a four-letter/two-error stress query, 280 ms for the first fuzzy query including dictionary preparation, and 2.1 seconds for the index upgrade. The earlier implementation took around 230–260 ms for each typo query on that dataset.

Those are reference measurements, not a cross-device performance guarantee or a new result from every documentation update. They exclude the 80 ms input debounce and UI rendering. The benchmark prints median and 95th percentile, one-note update time and the first search after that update. Ordinary tests do not enforce hardware-dependent timing thresholds.

## What still requires a real environment

- Installation, rollback and firewall reachability on a disposable VPS.
- Actual Let's Encrypt IP certificate issuance/renewal and externally reachable sharing ports.
- Real Dropbox/S3/SFTP accounts, permissions and long-running backup transfers.
- Native OS permission dialogs, notifications, lock-screen controls and background restrictions.
- Complete signed release builds on each supported platform, including Windows/Linux hosts.

See the dated [clean-source verification record](publication.md#clean-source-verification-on-2026-10-30) for the checks performed during publication preparation and their limits. For a practical loss-and-restore exercise, follow [Test your recovery plan](backups.md#test-your-recovery-plan).
