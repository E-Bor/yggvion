# Yggvion Privacy Policy

Last updated: November 3, 2026

Yggvion is a personal planning, notes and time-tracking application. Its developer does not operate a central service that receives your workspace. You can use the application locally without an account or a synchronization server. The application does not send your notes, tasks, attachments, encryption password or usage statistics to the developer. It includes no advertising or developer-operated analytics or tracking service.

This policy describes the official application and the optional server software. A separately operated server, modified build or external service may have its own policies.

## Data on your devices

Yggvion stores the information needed for its features on your devices: notes, events, projects, attachments, time records, activity statistics, settings and connection information. Usage statistics shown in the application are for your own use, not developer analytics.

End-to-end encryption protects private data synchronized to your server. It does not encrypt the application's entire working database on your device. The local profile, attachment cache and saved encryption password or device credentials rely on the device's application sandbox and operating-system protections. Do not share your application data directory with someone you do not trust.

## Optional synchronization

Synchronization is disabled until you connect to a server. You choose and control that server and its hosting provider. The application communicates with that server directly; it does not route your workspace through the developer.

Private synchronized content and attachments are encrypted on your device before upload. Your encryption password is not sent to the synchronization server or the developer. Your server still processes operational information such as device identifiers, synchronization timestamps and network requests. Encryption does not conceal all metadata from your server or hosting provider.

If you install or manage a server from the application, the SSH connection goes to the server you specify. Its administrator and hosting provider are responsible for their infrastructure, access controls and any server logs.

## Optional backups

You can create encrypted local backups and configure server backups. Local backup archives are protected with your encryption password. Server archives retain the encryption of private synchronized content but can include readable operational metadata and public-sharing information.

If you enable an additional copy in Dropbox, S3-compatible storage or SFTP storage, archives are sent to the destination you select. These providers process account, connection and stored-file information under their own policies. Dropbox authorization uses Dropbox's browser sign-in; Yggvion does not ask for your Dropbox password. Backup access credentials are used by your configured server, not sent to the developer.

## Calendar sharing

Sharing is optional. Creating a sharing link publishes a temporary snapshot of busy time intervals on your server. The snapshot does not contain the titles or descriptions of your private events, but the intervals are intentionally readable to people who have the link. Anyone who receives or forwards the link can access it while it is valid.

A guest can submit a proposed event, including its title, description and selected time. These submissions are delivered to the calendar owner's server and are not end-to-end encrypted while held as guest proposals. The calendar owner can read them. Do not include information you do not want that owner or their server administrator to receive. The sharing page also makes network requests to the owner's server, which may expose the visitor's IP address to that server and its hosting provider.

Sharing links expire after one hour. Expiry prevents further use of the link; it does not recall information already viewed, remove a proposal already received by the owner, or delete copies in existing backups.

## Permissions and external services

Camera access is used to scan device-invitation QR codes. Files or images you choose to attach become part of your workspace and can be synchronized or backed up if you enable those features. Notifications and lock-screen timer activities may show task information on your device; you control their visibility through the application and system settings.

Opening an external link, loading externally hosted content, authorizing a storage provider, or using the system share sheet can send information to the selected website, provider or application. Their privacy policies apply. Apple and other platform providers may separately process store, purchase, diagnostic or device information according to your settings and their policies; this is separate from Yggvion's workspace synchronization.

## Retention, deletion and your choices

You control your local workspace, connected server and backup destinations. Use the application's storage controls to remove local data, disconnect a server, revoke sharing access or manage backups as appropriate. Forgetting a server only disconnects the device; it does not delete that server's data.

Deletion on one device does not necessarily remove files you exported, archives in other locations or copies held by other people. Delete those copies from the corresponding server or storage provider as well. Backup retention depends on the schedule and destination you configure. The developer cannot retrieve or delete data held only on your devices or your chosen server, or recover a forgotten encryption password.

## Contact and updates

For questions about this policy, contact the maintainer through the [Yggvion project](https://github.com/E-Bor/yggvion) or the support contact on the app's store listing. If you submit a support request, the maintainer receives the information you choose to send and uses it to respond. Public issues are visible to other people; do not post passwords, private notes, server credentials or backup archives there. Use the [security reporting instructions](SECURITY.md) for vulnerabilities.

This policy may be updated when the application's behavior changes. The revision date above identifies the current text.
