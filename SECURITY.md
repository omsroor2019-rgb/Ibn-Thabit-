# Security model and operational guidance

## Protections implemented in source

- SQLCipher encrypts the local SQLite database. A random 256-bit database password is stored using `flutter_secure_storage` backed by Android Keystore.
- Android `allowBackup=false` avoids restoring app preferences containing Keystore-dependent secrets without their original device key.
- PIN verifier uses PBKDF2-HMAC-SHA256 with a per-install random salt. The raw PIN is not stored. Five invalid attempts trigger a 60-second lockout.
- PIN accepts 6–8 digits and rejects common repeated/sequential values. Biometric authentication is on-device and is an alternative to PIN when enrolled.
- App-wide privacy overlay locks all open routes when the app is backgrounded/hidden; the owner can also lock it manually.
- Android `FLAG_SECURE` prevents screenshots, screen recordings, and recent-app previews of account screens. This is a platform privacy control, not a defense against a rooted/compromised device.
- Android cleartext network traffic is disabled. The app has no server-side account sync in this release.
- AES-256-GCM protects portable backup files. PBKDF2-HMAC-SHA256 derives a backup key from a user passphrase (12–128 characters). Authentication tags are checked before restore.
- Local scheduled backups use AES-256-GCM with a random key held in secure storage. They are app-private and retained as the latest seven files.
- Restore validates SQLite integrity, foreign keys, schema, account ranges, transaction kinds, currencies, counters, and ledger non-negative balances. A secure-storage journal and rollback file support interrupted restore recovery.
- SQL constraints and triggers reinforce account number ranges, currency and operation types, and prevent payments or transaction edits from making account balances negative.
- Text input sizes are bounded; SQL queries use bound parameters; transaction writes and audit log writes share database transactions.

## Important limitations

- App-private weekly backups are removed on uninstall or app-data wipe. Recovery after uninstall/device loss requires exporting a `.bthbackup` file to an external location. Keep the passphrase separately.
- Google Drive is not directly integrated as a scheduled cloud target. The user may select Drive or WhatsApp from Android's share sheet when exporting a portable backup.
- Background work timing is controlled by Android and may be delayed by battery optimization/doze policies.
- No app can promise zero vulnerabilities. Rooted devices, malware with device-level privileges, compromised Android/Keystore, coercion, and weak user backup passwords are outside the app's complete control.
- Native SQLCipher, biometric flows, Android share URI access, WorkManager scheduling, and device-level recovery need actual Android CI/device tests. The local schema verification script uses system SQLite and is not a substitute for SQLCipher integration testing.

## Before production use

1. Run GitHub Actions to completion; require `flutter analyze`, `flutter test`, and release APK build to pass.
2. Test backup/export, WhatsApp/Drive share, restore, wrong password, corrupted backup, interrupted restore, and reinstall recovery on a real Android device.
3. Store exported backup files and their passwords separately; never send both through the same channel.
4. Keep an additional copy of the backup outside the phone (PC or trusted cloud storage).
