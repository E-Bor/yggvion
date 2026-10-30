<div align="center">
  <img src="client/assets/branding/app-icon.png" width="80" alt="Yggvion shield logo">

# Yggvion

**Your time, plans and ideas — in one place.**

A personal calendar, task planner, Markdown notebook and time tracker.<br>
Work locally. Sync across your devices with a server you control.

[Explore the features](docs/features.md) · [Build from source](docs/building.md) · [Documentation](docs/README.md)

</div>

![Yggvion: a weekly calendar with projects and Markdown notes](docs/images/desktop.png)

### Make room for what matters

- **Plan your days.** Shape your schedule in the calendar and move ideas into action with Kanban.
- **Keep your thoughts connected.** Write Markdown notes, link them together and keep files close to your work.
- **Understand your time.** Track what you do, compare it with your estimates and find a working rhythm.
- **Keep control of your data.** Work offline, make local backups and run synchronization on your own VPS.
- **End-to-end encryption (E2EE).** Personal records and attachments are encrypted on your devices before synchronization. Your encryption password stays on your devices. [How it works](docs/architecture.md#encryption).
- **Share your availability.** Send a temporary calendar link and review guests' meeting proposals in Planner.

**Android · iOS · macOS · Windows · Linux**<br>
Dark and light themes. Six languages. One personal workspace.

### Planner

Pick a task from your list, place it in the calendar and adjust its time and duration. Keep unscheduled ideas and your schedule in view together.

![Planner with an unscheduled task list beside a three-day calendar](docs/images/planner.png)

### Kanban

Move tasks through To do, In progress, Waiting and Done. Project colors keep different areas of your work easy to follow.

![Kanban board with tasks grouped by status and colored by project](docs/images/kanban.png)

### Notes

Write Markdown with live preview, organize notes in folders and connect them with `[[wiki links]]`. Keep checklists and attachments alongside your ideas.

![Notes library with folders, a formatted Markdown note and a linked-note preview](docs/images/notes.png)

### Calendar sharing

Send a link that expires in one hour. Guests see busy intervals without private event titles or descriptions, select a free slot and suggest a meeting. You can accept or reschedule it in Planner; the guest sees its updated status.

![Guest calendar with anonymous busy intervals, proposed and confirmed slots, and a meeting proposal form](docs/images/calendar-sharing.png)

[Explore calendar sharing](docs/synchronization.md#calendar-sharing).

### Statistics

Compare planned and tracked time, spot underestimation and overestimation, and see where your time goes by project. Follow workday trends, app usage and a year of activity in an accent-colored heatmap. Open **Settings → Statistics** to explore a week, a month or your full history.

![Statistics with time totals, a planned-versus-actual line chart and estimate accuracy metrics](docs/images/statistics.png)

[Explore the metrics](docs/features.md#statistics).

### Synchronization on your own VPS

Keep a local workspace on every device and sync changes when you reconnect. Set up an Ubuntu/Debian VPS with systemd on x86_64 or ARM64 directly from the app — no domain or manual shell setup needed.

1. Open **Settings → Synchronization → Set up VPS**. Enter the server IP, SSH port and a root or sudo account, using a password or SSH key.
2. Verify the SSH host fingerprint against your hosting provider's information. Choose a synchronization port and allow it in the provider's firewall.
3. Let Yggvion install the service and configure automatically renewed TLS certificates. Set your workspace encryption password; it stays on your devices.
4. Choose **Connect a device** to invite another device with a one-time link or QR code. Enter the same encryption password there to access your data.

[VPS setup and server management](docs/synchronization.md#install-on-a-vps) · [Include the installer when building from source](docs/building.md#client-with-the-vps-installer)

All screenshots use synthetic demo data.

---

Early development · Version 0.1 · Project license pending selection

[Contribute](CONTRIBUTING.md) · [Security](SECURITY.md) · [Third-party notices](THIRD_PARTY_NOTICES.md)
