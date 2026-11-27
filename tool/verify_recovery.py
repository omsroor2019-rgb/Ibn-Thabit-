#!/usr/bin/env python3
"""Static guardrails for SQLCipher key-loss recovery paths."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SECURITY = (ROOT / 'lib/services/security_service.dart').read_text(encoding='utf-8')
DATABASE = (ROOT / 'lib/data/app_database.dart').read_text(encoding='utf-8')
BACKUP = (ROOT / 'lib/services/backup_service.dart').read_text(encoding='utf-8')
APP = (ROOT / 'lib/ui/app.dart').read_text(encoding='utf-8')


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require('class DatabaseKeyMissingException implements Exception' in SECURITY,
        'Missing database key must have a typed exception')
require('hasValidDatabasePassword()' in SECURITY and
        'throw const DatabaseKeyMissingException(' in SECURITY,
        'Missing and malformed stored keys must route to explicit recovery')
require('getOrCreateDatabasePassword({required bool databaseExists})' in SECURITY,
        'Callers must explicitly declare whether an encrypted DB already exists')
require("final databaseExists = await File(filePath).exists() ||" in DATABASE and
        "await File('$filePath-wal').exists()" in DATABASE and
        "await File('$filePath-journal').exists()" in DATABASE,
        'Zero-byte DB files and SQLite sidecars must block automatic key regeneration')
require("if (databaseExists)" in SECURITY and 'DatabaseKeyMissingException' in SECURITY,
        'Do not generate a replacement key for an existing encrypted database')
require("'mode': 'empty_database_reset'" in SECURITY and "'version': 3" in SECURITY,
        'Explicit empty-ledger reset must be journaled in secure storage')
require("journal['mode'] == 'empty_database_reset'" in DATABASE,
        'App startup must recover an interrupted empty-ledger reset')

require("final suffixes = ['', '-wal', '-shm', '-journal'];" in DATABASE,
        'Reset must preserve main DB, WAL, shared-memory and rollback journal sidecars')
archive_copy = DATABASE.find('await source.copy(archived.path)')
archive_verify = DATABASE.find('sourceLength != archiveLength')
archive_delete = DATABASE.find('await pair.$1.delete()')
require(archive_copy >= 0 and archive_verify > archive_copy and archive_delete > archive_verify,
        'Old encrypted DB files must be copied and verified before active files are deleted')
require('startFreshDatabaseAfterMissingKey()' in DATABASE,
        'The user-confirmed reset operation is missing')
require('class DatabaseStartupGate extends StatefulWidget' in APP and
        'class DatabaseRecoveryPage extends StatefulWidget' in APP,
        'The app must handle DB key recovery before displaying the ledger')
require('restoreFromPicker(_backupPassword.text)' in APP,
        'The startup recovery screen must allow importing an encrypted backup')
require('getOrCreateDatabasePassword(databaseExists: true)' in BACKUP,
        'Backup creation must not silently create a key when an existing DB key is missing')

print('PASS: missing SQLCipher key is distinguished from ordinary open errors')
print('PASS: normal key creation is blocked for existing encrypted database files')
print('PASS: explicit reset journals recovery and archives old database files before removal')
print('PASS: interrupted reset can be completed on next app launch')
print('PASS: startup gate offers encrypted backup restore or confirmed fresh ledger')

PREPARE_ANDROID = (ROOT / 'tool/prepare_android.sh').read_text(encoding='utf-8')
BACKUP_RULES = (ROOT / 'tool/android/backup_rules.xml').read_text(encoding='utf-8')
EXTRACTION_RULES = (ROOT / 'tool/android/data_extraction_rules.xml').read_text(encoding='utf-8')
require('android:allowBackup' in PREPARE_ANDROID and 'android:dataExtractionRules' in PREPARE_ANDROID and
        'android:fullBackupContent' in PREPARE_ANDROID,
        'Android manifest must point to both legacy and modern backup exclusion rules')
for rules in (BACKUP_RULES, EXTRACTION_RULES):
    require('domain=\"database\"' in rules and 'domain=\"sharedpref\"' in rules,
            'Android backup rules must exclude database files and Keystore-backed preferences')
require('<device-transfer>' in EXTRACTION_RULES and '<cloud-backup>' in EXTRACTION_RULES,
        'Android 12+ cloud and device-to-device data transfer must both be explicitly excluded')
print('PASS: Android cloud and device-to-device backup rules exclude SQLCipher DBs and secure-storage preferences')
