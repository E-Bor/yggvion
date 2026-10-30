# Backups and recovery

[Documentation](README.md) · [Synchronization](synchronization.md) · [Encryption](architecture.md#encryption)

Open **Settings → Backups** to configure local copies, a server schedule and a second copy outside the VPS. A local backup works without any server.

## Choose the right backup

| | Local backup | Server backup |
| --- | --- | --- |
| File | `.ygglocal` | `.yggbackup` |
| Source | This device's workspace and available attachments | Data and attachments already received by the VPS |
| Destination | Application Support `backups/`, with export/share available | VPS backup directory, optionally copied to Dropbox, S3 or SFTP |
| Create | Manually or every N days | Server schedule; safety copies are also created for protected operations |
| Restore | On a client from a file or its local list | Import to a VPS, then explicitly restore |
| Needed to read personal data | File and the encryption password used when it was created | Archive and the encryption password used for its contents |

The formats are different and cannot be used interchangeably. Unsynchronized edits are absent from a server backup. A backup password is never sent to the VPS.

## Local copies

Under **On this device**, create a copy, restore from a file or an existing copy, export/share an archive, or delete a selected local copy. Desktop platforms can open the backup folder; phones use the system share/save interface.

The archive contains notes, folders and ordering, tasks, projects, links, settings, activity statistics, conflicts and all available local attachments. It excludes server connection secrets, SSH/TLS keys, absolute machine paths and `credential_*` values. Missing required attachment data fails the operation rather than producing a backup that only looks complete.

Local archives use a password-protected ZIP payload with SHA-256 checks for the snapshot and files. The outer authenticated encryption also detects truncation and tampering. The public header contains the parameters needed to derive the key from the password. No separate recovery key or previous device is required. See [Encryption formats](architecture.md#encryption-formats) for the wire layout.

### Automatic local backups

Enable a schedule of **every 1–365 days**. The first copy is due immediately. Yggvion retains the **two most recent successful automatic copies**: current and previous. Manual copies and safety copies are outside this rotation and are removed explicitly.

Old automatic copies are removed only after the replacement has completed successfully. Errors remain visible and retry after five minutes. Due checks run at startup, on resume and every 30 seconds while the app is active. A closed or suspended application catches up next time it runs; this is not a guaranteed operating-system background job. Each device keeps its own schedule and backup files.

### Local restore behavior

Restore validates the complete archive before replacing the database and creates a safety backup of the current workspace. Records are replaced in a transaction, attachment caches are restored, and the search index is rebuilt. Running timers are closed at the snapshot time.

Restoring disconnects the old VPS connection; it does not modify that VPS or any other device. Review the recovered data before reconnecting. Restoring an archive made with an older password requires that password to read it, but an existing current local password remains in use for future backups.

## Scheduled server copies

Configure a schedule of every **6, 12 or 24 hours**, weekly, or disabled. Daily/weekly retention defaults to **7 / 4**. Manual, imported and safety copies are deleted only explicitly. The user-facing manual creation button is reserved for local device copies.

Background jobs show progress/state and errors. Downloads stream to the client; on a phone, save the exported file through the system menu. The 300 MiB per-attachment limit is not a limit on the complete archive. Imports and the combined unpacked attachment size are limited to **100 GiB**.

### Server archive contents and validation

`.yggbackup` is a gzip-compressed tar archive containing:

```text
snapshot.json          # Snapshot format 3
snapshot.sha256        # Snapshot integrity check
attachments/<SHA-256>  # Encrypted attachment bytes, addressed by ciphertext hash
```

Records and attachments are already encrypted end to end. There is no second archive-encryption layer, `recovery.key` or separate server archive password. Snapshot time, identifiers, sizes and public password-derivation parameters remain readable without the password.

The server reads records and metadata in one SQLite transaction, including WAL state. It does not execute SQL supplied by an archive. A referenced attachment that has not reached the server makes the copy incomplete.

Import checks snapshot/file SHA-256 values, references, sizes and complete gzip termination. It rejects trailing data or extra streams, unexpected paths, links, duplicate entries and unsupported versions. Hashes detect corruption; clients still verify authentication when decrypting personal data. Up to 512 MiB of snapshot JSON is processed in memory; binary attachments are streamed.

Only server snapshot format 3 with the required password-encryption parameters is supported. Earlier archives with outer `age` encryption are not converted. Updating the server does not delete existing archive files; create a supported copy from readable data before relying on the new format.

## A second copy outside the VPS

The external destination can be **Dropbox**, **S3 over HTTPS**, or **SFTP with a required SHA-256 host fingerprint**. After verification, new server archives are automatically copied there. A transfer error is visible and leaves the local archive intact.

Server retention does not delete external copies. Manage them in the destination, for example with an S3 lifecycle policy. The app can list remote copies and bring one back to the VPS, where structure and checksums are validated again.

Destination credentials are stored only on the server in a file with mode `0600`, are not returned by the API and are not included in backups. An encrypted SFTP private key is supported; its password field supplies the passphrase when needed.

### Dropbox connection

Choose **Connect Dropbox**, sign in in the browser and allow access to the app's folder. Ordinary users do not create a Dropbox application. The official client includes its public OAuth application key; independently distributed forks should configure their own registration as described in [Building from source](building.md#dropbox-oauth). Update the VPS from the current app before the first connection.

The implementation uses OAuth authorization code flow with PKCE S256 and offline access. Random verifier/state values remain in memory for up to five minutes. State is checked before the one-use code is passed to the authenticated VPS. OAuth endpoints are fixed, TLS is verified, and redirects during code exchange are disabled.

On iOS, Android and macOS, the browser returns through the application URL scheme. Windows and Linux temporarily listen on **127.0.0.1:43827** during sign-in; this listener is not exposed on external network interfaces. The refresh token stays on the VPS in `remote.json`, mode `0600`, and is neither returned to clients nor included in archives.

Access is limited to the app folder when that permission type was chosen in the Dropbox registration. Upload sessions send 8 MiB chunks, including archives larger than 150 MiB; remote listing is paginated. An OAuth or upload error preserves the previous working configuration and local copy. Disconnecting removes saved destination credentials, not the files already in Dropbox. Revoke the application grant in Dropbox settings if needed.

## Restore a server backup

An authorized client can upload a `.yggbackup` file to a new or existing VPS without decrypting it. Import verifies and stores the archive; restore is a separate explicit action.

Restore validates the archive fully, creates a safety copy of current data, blocks writes and atomically replaces personal records. Content-addressed attachment files are prepared before the database transaction; a failed transaction preserves the old files. Device authorization, revocations and TLS keys remain intact. Unfinished timers close at the snapshot time.

Each successful restore changes the storage `generation`. Clients check generation **before uploading their outbox**, and the server checks under its write lock as well. A missing or outdated generation returns HTTP `409`, including on first synchronization.

The client first downloads the complete restored snapshot. In one local transaction, it then preserves the previous records, outbox and conflicts in `recovery_snapshots` and replaces working tables. Interrupted downloads leave the old local workspace available. Previous local data can be exported from Backups. The old outbox is not automatically replayed over restored data, and local attachment files are retained.

### Recover after losing a VPS

1. Install a new server from the app.
2. Import a downloaded server archive, or configure the external destination and retrieve a copy.
3. Restore the imported archive. An empty new server does not need a newly initialized encryption password first.
4. Connect devices using invitations from the new server and enter the encryption password applicable to the recovered data.
5. Check notes, tasks, files and time entries before resuming normal work.

The new installation has a new TLS identity and new device tokens. A backup does not make the lost VPS's connection credentials valid on the replacement.

## Disk and concurrency safeguards

An import reserves the single heavy-operation slot **before reading the request body** and holds it through validation. Parallel heavy operations receive a busy response rather than writing multiple large temporary archives.

Imports allow up to 100 GiB and keep a 512 MiB free-space reserve, checked every 8 MiB; insufficient disk space returns HTTP `507`. Startup removes incomplete `.upload-*`, `.restore-*`, `.import-*`, `.remote-*`, `.backup-*`, `.write-*` files and unfinished attachment uploads, without treating completed backups as temporary files.

After a scheduled local server copy succeeds, retention runs **before** sending the copy to external storage. A prolonged Dropbox/S3/SFTP outage therefore does not disable local retention. Transfer failures remain visible for follow-up. These limits do not replace disk monitoring or a storage quota for the whole VPS.

## Test your recovery plan

Use a separate application profile, simulator or disposable machine. Do not erase the only working copy just to test a backup.

1. Create recognizable sample data: a note with a heading and checklist, an event with tracked time, a project, a folder, an image and a file.
2. Make a local backup and export it outside Application Support. Record which encryption password belongs to it.
3. In a separate empty profile, open **Settings → Backups → Restore from file** and select that `.ygglocal` file.
4. Enter the password, restore and verify note text/folders, dates, time entries, settings and attachment contents. Confirm search finds the restored records.
5. For server recovery, use a disposable VPS. Import a `.yggbackup`, restore it, then join from an isolated client with the corresponding password.
6. Verify that an already-connected test client adopts the restored generation and does not upload its pre-restore queue over the restored snapshot.

Keep at least one exported copy outside the device or VPS it protects. A checksum can confirm that a file was copied unchanged, but a successful restore is the practical test that both the archive and its password are usable. The isolated automated backup suites are listed in [Testing](testing.md).

## Operating-system backups

The working client database is not encrypted at rest and contains the locally saved password and device token. iOS excludes Application Support from system backup before opening SQLite, covering the database, WAL/SHM files, cache and local archives. Failure to apply that exclusion is not silently ignored.

Android disables application backup and supplies cloud/device-transfer exclusion rules. These settings do not remove copies made by older builds. Recover through explicitly exported encrypted archives or synchronization, rather than depending on automatic transfer of a plaintext working profile.
