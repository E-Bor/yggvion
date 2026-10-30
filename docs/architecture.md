# Architecture, storage and encryption

[Documentation](README.md) · [API contract](../api/openapi.yaml) · [Security policy](../SECURITY.md)

## Stack and repository layout

| Component | Implementation |
| --- | --- |
| Client | Flutter 3.38.8 / Dart 3.10.7, Riverpod |
| Local storage | Drift, SQLite in a background isolate, WAL, FTS5 |
| Calendar | Custom Flutter grid with mouse and touch interaction |
| Dates and recurrence | `timezone`, `rrule`, RFC 5545 / ICS |
| Markdown | Live Preview editor and `flutter_markdown_plus` rendering |
| Clipboard | `super_clipboard` for native files and images |
| Network | Dio, HTTPS JSON API, SSE change signals |
| Notifications | `flutter_local_notifications`, native tracking surfaces, optional Linux Go companion |
| Server | Go 1.26.10, `net/http`, SQLite through `modernc.org/sqlite`, file storage |
| Deployment | SSH installer and systemd; optional manual Docker Compose/Caddy deployment |
| UI | Adaptive native layouts, Inter, light/dark themes and a shared configurable accent |

| Path | Responsibility |
| --- | --- |
| `client/lib/data/` | Database, repositories, synchronization, backups and notifications |
| `client/lib/domain/` | Models, recurrence, imports and domain rules |
| `client/lib/ui/` | Application screens and widgets |
| `server/internal/` | Server domain, storage, HTTP and integrations |
| `api/openapi.yaml` | Client/server contract |
| `deploy/` | Deployment configuration and service templates |
| `tool/`, `tools/` | Build helpers, asset generation and checks |

Dependency resolutions are recorded in the relevant `pubspec.lock`, `go.mod`/`go.sum` and CocoaPods lockfiles. The current Dart implementation does not require generated model classes. See [Building](building.md) for platform tools and commands.

## Local and server storage

The local SQLite schema is **8**. User records, a synchronization outbox, search data and device metadata live in the client profile; attachment bytes use the local file cache. An edit and its outgoing operation are committed together.

| Local migration | Purpose |
| --- | --- |
| 4 | Removes experimental AI settings, proposal queue metadata and `semantic_vectors`. |
| 5 | Adds the `search_terms` dictionary and local `app_activity` with UTC microsecond timestamps. |
| 6 | Rebuilds the derived search index with separate title/body fields. |
| 7 | Rebuilds search titles for optional explicit titles and first-heading fallback. |
| 8 | Adds encrypted retry payloads and attachment identifier mappings. |

These migrations preserve tasks, notes, attachments, time entries and the synchronization queue. AI models, voice input and semantic search are no longer included. Startup cleanup targets only the old `local-ai/` and `ai-recordings/` service directories. A locked file is logged and retried next startup without blocking the workspace.

The server uses schema **9**, API **3.0** and synchronization protocol **6**. Schema 7–8 upgrades run transactionally, compact intermediate history/retry records and add original proposal intervals/public statuses while preserving personal data, authorization and existing links. Earlier encryption formats and unknown databases are rejected without automatic conversion or erasure.

Server `records` and `changes` contain encrypted envelopes. `encrypted_uploads` tracks workspace ownership of files. `guest_inbox` and `calendar_availability` hold the intentionally public sharing data. Personal content is validated and reconciled by clients after decryption; the server checks authorization, envelope shape, versions, quotas and transport integrity.

### Search index

FTS5 indexes title and body separately with prefixes of one to four characters. Updates affect the changed row rather than rebuilding the entire collection. Fuzzy matching uses the term dictionary and a compressed prefix trie in a persistent worker isolate, loaded lazily and updated when searchable text changes. Status-only edits do not rebuild it.

Queries are debounced by **80 ms**. Filtering and ranking happen against the database rather than copying tens of thousands of full documents into the UI. Ranking prioritizes notes over events, then title matches over body matches within each group. At most 100 results are returned. One-character input uses exact matching; longer fragments allow the configured zero, one or two errors without requiring a complete word.

See [Search benchmarking](testing.md#search-benchmark) for a reproducible large synthetic dataset.

### Working-day records and settings

Workdays synchronize as encrypted `workday` records with local IDs `workday-YYYY-MM-DD`. Their private payload includes `day`, `planned_start`, `planned_end`, and optional actual UTC `start`/`end` timestamps. They are included in both backup formats and excluded from public availability.

`settings.workday_end` stores minutes from the start of the workday's calendar date, including the following day: `1500` means 01:00 next day. `workday_history` contains ordered periods with an exclusive `until` date (`YYYY-MM-DD`), `start`/`end` minutes and weekday `days`. Before the first boundary, the earliest saved schedule applies; after the last boundary, current `workday_start`, `workday_end` and `workdays` apply. Restore validates dates, ordering, times and weekdays.

History is part of the encrypted settings record and does not need a separate table. Devices must support it for consistent statistics. Older servers that do not accept the `workday` kind must be updated before synchronization.

The persisted `task_color` field now represents the shared application accent, despite its historical name. Its ARGB default is `0xff9cb9ff` when absent/null; project and semantic status colors remain separate. Optional `search_typos` is an integer from 0 to 2; absent/null means 1. These field names remain part of the existing contract.

## Attachment catalog

File metadata synchronizes as an encrypted `attachment` record with local ID `attachment-<plaintext SHA-256>`. Its private fields include `file_id`, `title`, `size`, `content: attachment:<id>` and `added_at`. The addition date stays the same on another device; old entries without it appear in an earlier/undated group.

Original names and local identifiers stay inside ciphertext. The server sees the record kind and encrypted file identifiers in the authenticated `files` field. Catalog entries are created for existing local files and are included in backups. Older clients must be updated and synchronized before all metadata is available.

Deleting unused files considers references in all personal records, including recurring series, pinned notes and unresolved conflicts. References are checked again before deletion. Connected clients synchronize first; an unavailable server prevents cleanup. Offline-only workspaces clean up locally. Deleting a current attachment does not erase its bytes from existing backups.

The private API includes:

| Endpoint | Contract |
| --- | --- |
| `POST /api/v1/attachments/present` | Accepts `{"ids":["<ciphertext SHA-256>"]}` and returns existing IDs in the same shape; maximum 1,000 IDs. |
| `DELETE /api/v1/attachments/{ciphertext SHA-256}` | Accepts `{"record": <encrypted catalog tombstone>}` and returns the saved tombstone. Requires a device token and current generation. |

Deletion can return `409 attachment_in_use`, `409 attachment_changed` or `409 server_busy`. Reference checks, tombstone storage and file deletion are serialized with synchronization, uploads and backups. Retrying a successful deletion is safe. An offline device with an unsent reference checks file presence and reuploads available local bytes before sending the reference; the server will not accept it before the file exists.

These endpoints are absent from the public sharing listener. Update the server from the app before using catalog cleanup with a previously deployed version.

## Encryption

Before first synchronization or backup, the user creates an encryption password of **12–256 characters**. Argon2id derives a 256-bit key from that password and a random salt. There is no independently generated master key, wrapped-key hierarchy or Keychain dependency.

The password is saved in the local SQLite profile as `credential_password_<fingerprint>` for automatic reopening after restart. The derived key stays in memory. The server receives public derivation parameters, salt, a SHA-256 key fingerprint and ciphertext, never the password. Device-token authorization is separate from encryption.

### Password derivation

Argon2id uses fixed parameters: **19 MiB memory, 2 iterations, parallelism 1 and a random 16-byte salt**. Derivation runs in an isolate. Version 2 `password_config` contains only:

```text
v, key_id, kdf, memory, iterations, parallelism, salt
```

Clients reject unsupported parameters before attempting derivation. A newly paired client obtains these public parameters from `/state.password_config`, derives the key, checks its fingerprint and saves the password only in that device's profile. An SSH password, server token or bootstrap code alone cannot decrypt personal data.

### Record and attachment encryption

Records use AES-256-GCM with a fresh random 96-bit nonce and an HKDF-SHA256-derived key. Authenticated metadata includes the identifier, kind, deletion state and attachment list. The original ID is also inside ciphertext; the outer ID is HMAC-SHA256 so deterministic recurring-task UUIDs cannot directly reveal dates by enumeration. Intentionally public `guest_` proposal IDs are an exception.

Server versions and change cursors remain metadata. `encrypted_outbox` caches the exact ciphertext for retries after a lost response. A record's ciphertext plus authentication tag is limited to 2 MiB, with a 3 MiB limit on its base64 JSON envelope. Client batches are capped at 7 MiB against the server's 8 MiB limit.

Attachments up to **300 MiB** use 1 MiB encrypted chunks, a random 256-bit file salt and a separate derived file key. Key contexts distinguish attachments from local backups. File length, order, authentication and truncation are checked before decrypted output becomes available. The server addresses files by their **ciphertext** SHA-256 and uses `encrypted` instead of the original name. Original hashes and filenames remain inside encrypted records.

Encrypted transport allows **301 MiB** for overhead. Downloads enforce that limit while streaming, including responses without `Content-Length` and decoded HTTP gzip. An oversized response stops immediately and its temporary file is removed.

### Encryption formats

The attachment stream starts with `YGGFILE1`:

| Field | Size |
| --- | --- |
| Magic | 8 bytes |
| Random salt | 32 bytes |
| Original length | 8-byte unsigned big-endian integer |
| Key fingerprint | 64 ASCII bytes |
| Encrypted chunks | Ciphertext and a 16-byte GCM tag per chunk |

A chunk nonce consists of four zero bytes and its 64-bit index. Each chunk authenticates the full header. An empty file still has one authentication tag.

A local `.ygglocal` archive wraps its payload with `YGGPASS2`: eight magic bytes, a four-byte big-endian JSON parameter length, up to 4,096 bytes of public parameters, then a `YGGFILE1` stream. The file and its password are sufficient for recovery on another device. Passwords, tokens and other `credential_*` values are excluded from the payload.

Server snapshot format 3 contains `cursor`, `password_config`, `encryption_key_id`, encrypted records and encrypted files. It can be created without the password. The `.yggbackup` archive adds no second encryption layer or separate archive key. Restore returns the encryption parameters/password state of that snapshot. Old cryptographic formats and invitations carrying a master key are not automatically converted.

### Change a password or clear a device

**Settings → Encryption** is separate from Synchronization and Backups. Changing the password requires the current password and, when a VPS is configured, a working connection. The client reencrypts records and attachments; the server atomically replaces them only if generation and snapshot cursor still match. Versions, running timers and public links are preserved. Concurrent writes cause `409` and leave the old dataset intact.

The new password is saved locally before sending the replacement, allowing recovery if the success response is lost. Other devices ask for the new password once while retaining offline edits. Changing a password does not revoke devices; revoke their tokens separately.

**Clear storage** deletes only this device's working database, search index, tasks, notes, projects, time entries, attachments, internal local backups, saved password/tokens and connection settings. It requires typing the exact confirmation phrase displayed by the localized dialog. Background services stop and local notifications are canceled before opening an empty profile. If interrupted, an already-confirmed clear operation resumes before the database opens on next launch. It does not follow filesystem links, delete VPS data or erase copies exported outside the application.

### Boundaries of protection

- The working SQLite database, search index, attachment cache and notification text are plaintext on the device. The saved password and device tokens are also local plaintext. Device account and disk protection remain essential.
- The VPS can observe record kinds, sizes, versions, deletions, connected devices and network metadata. It can withhold service, delete data or replay old valid ciphertext. E2EE does not replace independent backups.
- Revocation stops future synchronization but cannot erase keys/data already held by a former device. There is no automatic key rotation or forward secrecy. Password changes do not protect old archives if their old password is compromised.
- Public KDF parameters and a key fingerprint permit offline password guesses. A strong passphrase still matters.
- Calendar sharing intentionally publishes a separate plaintext availability snapshot and receives plaintext guest proposals. Private event text and IDs are not included. See [Calendar sharing](synchronization.md#calendar-sharing) for its separate access model.

Search, notifications, recurring-event cancellation and timer reconciliation run locally after decryption. TLS, SSH verification and trusted application delivery remain necessary. Automated tests are not an independent cryptographic audit.

## Resource limits and synchronization history

Private API limits are checked before SQLite token lookup. Forwarded-IP headers are not trusted as the client's address.

| Resource | Limit |
| --- | --- |
| Requests from one source | Burst 120, then 30/second; IPv6 sources grouped by /64 |
| Aggregate private requests | Burst 480, then 120/second |
| Failed authorization | Further attempts temporarily blocked after 30 failures/minute per source |
| Concurrent token checks | 8 |
| Ordinary handlers | 24 total, 4 per device |
| File transfers | 4 |
| Heavy snapshot/password jobs | 1 |
| SSE connections | 2 per device, 16 total |
| Normal request deadline | 2 minutes |
| Attachment deadline | 15 minutes |
| Archive import/download deadline | 2 hours |
| SSE write deadline / connection renewal | 10 seconds / at least hourly |

Rate/concurrency limits return `429` with `Retry-After`; local changes stay queued. SSE retains token-revocation checks. These protect application resources, not the provider's network against volumetric DDoS. There is no general storage quota for all attachment bytes, and large full snapshots can still consume substantial memory.

`changes` retains only the latest version of each record, including tombstones. Cursors remain monotonic through compaction. A long-offline client can continue from its old cursor; a new client receives the current dataset with `after=0`. Each page has at most 500 records and approximately 8 MiB of JSON; `has_more` indicates continuation.

`operations` retains exact retry responses for up to seven days, within overall limits of 4,096 rows / 64 MiB. Cleanup runs in the write transaction. Once an exact response is evicted, optimistic version checks still prevent a retry from overwriting a newer record: it receives the current record or a conflict.

Tombstones are not expired by age, so disconnected devices cannot resurrect deleted data. Freed SQLite pages are reused without automatic blocking `VACUUM`. Backup-specific upload reservation, free-space checks and temporary-file cleanup are covered in [Backups](backups.md#disk-and-concurrency-safeguards).
