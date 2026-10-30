# Security

## Reporting a vulnerability

Use **Security → Report a vulnerability** in this repository when GitHub private vulnerability reporting is enabled. Include the affected commit/version, platform, prerequisites, impact and a minimal reproduction with synthetic data.

Do not put exploits, live credentials, backup files, personal notes, invitation links or real calendar-sharing links in a public issue. If private reporting is unavailable, open an issue requesting a private contact channel without disclosing the vulnerability. Maintainers must enable a private reporting channel before public release; this repository does not currently declare a public security email address.

The project is pre-1.0. Security fixes target the current main branch; there is no long-term support commitment for older builds and no guaranteed response time.

## Security model

- The application works locally without an account. The optional VPS synchronizes a personal workspace; every authorized device has owner-level access, including invitations, backups and restore. Invitations are credentials, not read-only sharing links.
- Personal synchronized records and attachments use end-to-end encryption with a key derived from the user's encryption password. The server receives ciphertext and public encryption parameters, not the password. It can still see metadata, refuse service, remove data or replay previously valid ciphertext.
- The working client database, search index and attachment cache are local plaintext. The encryption password and device token are saved in the local SQLite profile. This design depends on the device's account and disk protection; it does not protect against compromise of an unlocked client. System-backup exclusions do not make the local profile encrypted.
- TLS protects transport separately from end-to-end encryption. SSH host verification is part of initial installation; the application's private CA is scoped to its server connection. Do not bypass certificate or host-key checks.
- Public calendar sharing intentionally publishes a separate plaintext snapshot of busy intervals. Existing event names and descriptions are excluded. Guest proposals are plaintext until the owner's client imports and encrypts them. Anyone holding a valid sharing link can use it until expiration or revocation.
- Backups require the encryption password applicable to their contents. Keep independent copies and test recovery with synthetic data before relying on a backup policy. Hash checks detect damage; they are not a substitute for encryption authentication or a trusted release channel.
- Rate, size and concurrency limits reduce application-level abuse. They do not provide protection against an attack that saturates the VPS network or the hosting provider's resources.

This description is not an independent security certification. See the [API contract](api/openapi.yaml), implementation, [encryption and resource limits](docs/architecture.md) and [calendar sharing](docs/synchronization.md#calendar-sharing) for exact behavior.

## Maintainer responsibilities

Keep server dependencies and base images updated, preserve security tests, and avoid logging private payloads or authorization headers. Review the [publication checklist](docs/publication.md) when producing a release. If a real credential was committed, revoke/rotate it first; removing it from the latest revision or adding it to `.gitignore` does not remove it from history.
