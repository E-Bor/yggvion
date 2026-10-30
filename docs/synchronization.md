# Synchronization and calendar sharing

[Documentation](README.md) · [Data and encryption](architecture.md) · [Backups](backups.md)

Yggvion works locally without a server. A VPS adds synchronization between your devices, server backups and public calendar sharing. It hosts one personal workspace: every authorized device has owner-level access.

## Install on a VPS

Open **Settings → Synchronization → Set up VPS**. The installer supports Ubuntu/Debian with systemd on Linux x86_64 or ARM64.

1. Enter the server's IP address, SSH port and a root or sudo account. Authenticate with a password or private SSH key.
2. Compare the displayed SHA-256 SSH host fingerprint with the fingerprint provided by your hosting provider before continuing. The client remembers the fingerprint and warns if it changes.
3. Choose the synchronization port and run the installation. If another service occupies that port, installation stops before changing the server.
4. Complete encryption setup on the client. The encryption password stays on your device; SSH credentials are not retained.

The installer transfers the Go binary bundled with the app and verifies its SHA-256 at both ends. It creates a shell-less `yggvion` user, installs into `/opt/yggvion`, stores data in `/var/lib/yggvion` with mode `0700`, and configures a restricted systemd service with automatic startup and restart. Native installation does not require Docker. Sudo credentials are sent through standard input rather than command-line arguments.

The selected TCP port must be reachable from your devices. An active UFW receives a rule for it; configure the hosting provider's external firewall separately. The installer does not stop unrelated services. Accurate system time and sufficient free disk space are required.

The installer payload must be generated before packaging the client. See [Building from source](building.md#client-with-the-vps-installer).

### TLS without a domain

The VPS creates a private ECDSA P-256 certificate authority and a server certificate containing the IP address as a subject alternative name. The CA's private key stays on the VPS with mode `0600`. The client receives the public CA over verified SSH and trusts it only for this Yggvion connection; it does not modify the operating system's trust store.

Connections require TLS 1.3 or later and retain certificate chain, expiry and IP/name verification. The server certificate lasts 90 days, is checked every 12 hours and is renewed when fewer than 30 days remain. A fresh leaf certificate is issued after restart; trust remains anchored in the same CA. The CA lasts 20 years and requires an explicit identity change and device reconnection in its final year.

This private certificate serves device synchronization. Browser sharing uses a separate public certificate, described below.

## Connect another device

On a connected device, choose **Connect a device**. It creates a one-use QR code and a `yggvion://connect#…` invitation containing the server address, public CA and a code valid for ten minutes. The server consumes the code atomically and issues a separate, revocable device token. Only its hash is stored on the server.

Open the link on iOS, Android or macOS, scan its QR code on those platforms, or paste it into Synchronization on any supported platform. Enter the workspace encryption password once to open the existing data. The invitation grants server access; it does not contain the encryption password.

Each authorized device can invite other devices, manage backups and restore the workspace. There is no read-only device role. Revoking a device also invalidates its unused invitations. A revoked device may still possess data it downloaded earlier.

Installation and invitation entry are shown only when the device has no configured server. To switch VPS, first choose **Forget server**. This disconnects the current device while preserving its local data, the VPS and other devices' connections. Invitation handlers and the installer enforce this rule too; entering another link cannot silently replace an existing connection.

## Manage an existing server

**Synchronization → Server management** provides three distinct actions:

| Action | Effect |
| --- | --- |
| Update server component | Installs the server bundled with the current app over SSH, preserving supported data and server identity. |
| Clear server | Removes the native server installation and its data after SSH verification and confirmation using the current server IP. |
| Forget server | Disconnects this client only; keeps local and remote data. |

Updating stops the service and creates a safety snapshot of SQLite, including WAL state. A migration or startup failure restores the previous database, binary, configuration and systemd unit. The temporary snapshot is removed after a successful start.

The current server schema is **9**. Upgrades from schemas **7–8** preserve records, attachments, TLS identity, backup settings and device tokens. Schemas 1–6 and non-empty unversioned databases are rejected without automatic conversion or deletion; they need a separate migration decision or clean installation. Updating the app alone does not update a VPS.

**Clear server** removes the native systemd unit, binaries, database, attachments, TLS identity, configuration, local server backups and service user. It preserves external backup copies and client data. Shared firewall rules and provider firewall configuration are not removed. This action targets the standard native installation, not a separate Docker deployment.

### Connection and resource metrics

Opening Synchronization or explicitly refreshing it requests connection status, CPU use, process memory and disk usage/free space. Both client and server cache metrics for 30 seconds; the page does not continuously poll them. The private `/api/v1/metrics` endpoint requires a device token. Host CPU and disk figures describe the VPS as a whole, not an isolated application quota.

## Offline changes and reconciliation

A local edit and its outbox operation are saved in one transaction before the UI reports success. Synchronization sends parents before dependent records in batches of up to 100. Operation IDs make retries idempotent, while record versions and a server change cursor identify new data. SSE signals and periodic synchronization keep connected clients updated.

Deletion tombstones prevent an offline device from silently resurrecting a deleted record. Recurring-series deletion can carry an inclusive UTC `cancelled_from` boundary, so clients also remove future occurrences and sessions created offline. Splitting a series with an RRULE `UNTIL` is not itself a deletion command.

Conflicts preserve both versions instead of silently discarding one. Notes can be kept as separate copies; the editor does not use a collaborative CRDT. Timer start times are persisted, so a restart does not reset elapsed time. Independent offline actions still need reconciliation when connectivity returns.

View proportions, device language/scale, calendar zoom, the last selected timer task and local backup schedules remain device-specific. For storage versions, encrypted payloads and resource limits, see [Architecture](architecture.md).

## Calendar sharing

With synchronization configured, **Share calendar** is available in Today and Planner. Choose a 7-, 14- or 30-day availability window. The resulting link is copied to the clipboard automatically, lasts **one hour**, and can be revoked earlier from the dialog.

Guests see merged busy intervals without event names, descriptions, projects or private identifiers. Birthdays and historical time blocks are excluded. The grid states its time zone. Select a free interval with the mouse on desktop or a press/hold on a phone, then enter a title and optional description.

Guests cannot upload or read attachments. The server rejects internal `attachment:` links in proposal titles/descriptions, and clients neutralize such links received from older servers. A proposal is a request, not an accepted booking.

### Proposals and acceptance

Incoming tasks appear under **Proposed** in Planner. **Accept** schedules the requested time if it is still in the future and free. Clicking the card selects it for ordinary planning; the overflow menu opens the normal editor. The chosen interval determines the estimate. Declining deletes the proposal. Unscheduled proposals do not appear in Kanban.

The guest's interval appears as **Proposed** immediately after submission. The server reserves it atomically: an overlapping proposal through any active link receives HTTP `409`. Until the owner responds, the reservation lasts until link expiry or revocation. Importing the proposal into Planner does not release it.

After owner synchronization, an accepted original interval becomes green; a declined or rescheduled interval is released. An accepted event remains ordinary anonymous busy time after the link expires. A visible browser page refreshes every 15 seconds, with no overlapping requests and without interrupting an active selection. A submission nonce recovers a lost response without creating a duplicate.

### What a guest can learn

Each link reveals only its own proposal nonce, original start/end and status: `pending`, `accepted`, `declined` or `rescheduled`. Other links' proposals merge into anonymous busy intervals. Rescheduling does not associate the new time with the original proposal. Owner text, task IDs, record versions and other sharing-link identifiers are never included.

Anyone holding the same valid link sees the same statuses. Access ends with expiry or revocation. Status updates require an authorized device token and the current storage generation. The server validates proposal ownership, record version, the unchanged original interval and synchronization cursor. A stale snapshot returns `updated: false` without changing state. Clients do not publish unconfirmed local edits or conflicts.

An older server without `proposal_statuses` receives the earlier availability format; update it to enable proposal status changes. If the owner's devices are offline, the guest sees the last published availability snapshot. Incoming guest text remains plaintext on the VPS until an owner client imports and encrypts it, after which the plaintext inbox item is removed. Link expiry does not delete a proposal already imported into the owner's workspace.

### Public HTTPS and ports

Public sharing uses an HTTPS listener separate from private synchronization. On first use, the server requests a Let's Encrypt certificate for its public IP using the short-lived certificate profile; no domain is required.

| Port | Purpose |
| --- | --- |
| Selected synchronization port | Private TLS API for authorized devices. |
| TCP 80 | HTTP-01 certificate validation; listens only during validation and must be free and publicly reachable. |
| TCP 8443 | Public sharing page; uses 8444 instead if synchronization itself uses 8443. |

The installer adds rules to active UFW; the provider firewall still needs separate configuration. Occupied ports do not cause unrelated services to be stopped. Initial public certificate setup can take up to two minutes and requires a directly reachable public IP.

The certificate is verified against system roots and the IP address. Renewal is checked hourly and when creating a link, starting 48 hours before expiry. Failures back off for an hour and do not replace a working key/certificate. Public identity files live separately in `public-identity/`, with directory mode `0700` and private file mode `0600`.

An existing public reverse proxy can instead set `YGGVION_PUBLIC_URL=https://calendar.example.com` and manage public certificates itself. Forward only the required guest routes:

```text
/share
/share/calendar.css
/share/calendar.js
/share/logo.svg
/public/calendar
/public/proposals
```

### Security and limits

The link secret contains 256 random bits; the server stores its SHA-256. It travels in the fragment after `#`, then in the `Authorization` header, rather than in the HTTP URL. The page uses no external resources, rejects embedding, and sets CSP, `no-store`, `no-referrer` and `noindex`. User text is rendered with `textContent`; SQL queries are parameterized.

| Limit | Value |
| --- | --- |
| Request body | 16 KiB |
| Proposal title | 200 characters |
| Proposal description | 8,000 bytes |
| Proposed interval | 24 hours |
| Proposals per link | 10 |
| Active links | 20 |
| Public API requests | 60/minute per IP; 300/minute overall |

The public listener exposes only guest routes. Revoking the creator device or restoring the server database invalidates affected sharing links. These measures reduce guessing and application-level spam; they do not prevent network saturation or a recipient forwarding a working link. The public global quota can still affect unrelated guests under load. See [Security](../SECURITY.md) for the broader threat model.

## Manual Docker deployment

`deploy/compose.yaml` and Caddy provide an alternative for operators who manage their own public domain and HTTPS. Configure `YGGVION_DOMAIN` and a strong `YGGVION_PAIRING_KEY` in your environment, then run from the repository root:

```sh
docker compose -f deploy/compose.yaml config --quiet
docker compose -f deploy/compose.yaml up -d --build
```

Caddy requires reachable TCP 80/443. The app runs as a non-root container user; `app_data` holds application data, while `caddy_data` and `caddy_config` hold proxy state. This is a manual server/API deployment, not the app's guided installer or a restored manual-address connection screen. See the [API contract](../api/openapi.yaml) for pairing and invitations.

Use the application backup format or a consistent database-and-attachments snapshot. Copying a live SQLite file alone can omit WAL contents. The native installer and its removal/update actions do not manage Docker volumes.
