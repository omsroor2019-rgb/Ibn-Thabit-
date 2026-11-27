import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../services/security_service.dart';

String _normalizeSearch(String input) {
  var value = input.trim()
      .replaceAll('٬', ',')
      .replaceAll('٫', '.')
      .replaceAll('٠', '0').replaceAll('١', '1').replaceAll('٢', '2')
      .replaceAll('٣', '3').replaceAll('٤', '4').replaceAll('٥', '5')
      .replaceAll('٦', '6').replaceAll('٧', '7').replaceAll('٨', '8')
      .replaceAll('٩', '9')
      .replaceAll('۰', '0').replaceAll('۱', '1').replaceAll('۲', '2')
      .replaceAll('۳', '3').replaceAll('۴', '4').replaceAll('۵', '5')
      .replaceAll('۶', '6').replaceAll('۷', '7').replaceAll('۸', '8')
      .replaceAll('۹', '9');
  if (RegExp(r'^[0-9,]+(?:\.[0-9]{1,2})?$').hasMatch(value)) {
    value = value.replaceAll(',', '');
  }
  return value;
}

class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  Database? _database;
  Future<Database>? _opening;
  bool _snapshotInProgress = false;
  bool _restoreSwapInProgress = false;

  Future<Database> get database async {
    // Read requests wait briefly while a same-isolate snapshot closes and
    // reopens the SQLCipher connection; they should not surface as UI errors.
    while (_snapshotInProgress || _restoreSwapInProgress) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    return _openSingleFlight();
  }

  Future<Database> _openSingleFlight() async {
    final opened = _database;
    if (opened != null) return opened;

    final pending = _opening;
    if (pending != null) return pending;

    final opening = _open();
    _opening = opening;
    try {
      final db = await opening;
      _database = db;
      return db;
    } finally {
      if (identical(_opening, opening)) _opening = null;
    }
  }

  Future<String> get databasePath async {
    final root = await getDatabasesPath();
    return p.join(root, 'bin_thabit.db');
  }

  Future<void> _assertWritable() async {
    if (_snapshotInProgress) {
      throw StateError('يتم تجهيز نسخة احتياطية؛ انتظر انتهاء العملية');
    }
    final path = await databasePath;
    final lock = File('$path.operation.lock');
    if (await lock.exists()) {
      // Recover from an abandoned lock left by a process killed during backup.
      final age = DateTime.now().difference((await lock.stat()).modified);
      if (age > const Duration(minutes: 30)) {
        try { await lock.delete(); } catch (_) { /* another isolate may own it */ }
      }
      if (await lock.exists()) {
        throw StateError('يتم تجهيز نسخة احتياطية؛ حاول مرة أخرى بعد لحظات');
      }
    }
  }

  Future<Database> _open() async {
    final filePath = await databasePath;
    if (!_restoreSwapInProgress) await _recoverInterruptedRestore(filePath);

    // Ensure the Android app-private database directory exists and is writable
    // before invoking the native SQLCipher open call.
    final parent = Directory(p.dirname(filePath));
    await parent.create(recursive: true);
    final probe = File(p.join(parent.path, '.bin_thabit_db_write_probe'));
    try {
      await probe.writeAsBytes(const [0x42], flush: true);
    } finally {
      if (await probe.exists()) await probe.delete();
    }

    // Any artifact of the DB set means this is not a clean first launch.
    // A zero-byte main file can be left by an interrupted native open, and a
    // WAL/journal can carry data even if the main file is absent. In all such
    // cases require the original key or explicit recovery; never mint a key.
    final databaseExists = await File(filePath).exists() ||
        await File('$filePath-wal').exists() ||
        await File('$filePath-shm').exists() ||
        await File('$filePath-journal').exists();
    final password = await SecurityService.instance.getOrCreateDatabasePassword(
      databaseExists: databaseExists,
    );

    try {
      return await openDatabase(
        filePath,
        password: password,
        version: 2,
        onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
        // Use SQLite's rollback journal instead of WAL. The bundled SQLCipher
        // release uses an SQLite baseline older than the fix for the rare
        // multi-connection WAL-reset corruption race. DELETE mode keeps the
        // existing WorkManager backup and foreground access on normal locking.
        final journalModeRows = await db.rawQuery('PRAGMA journal_mode = DELETE');
        final journalMode = journalModeRows.isEmpty
            ? ''
            : journalModeRows.first.values.first.toString().toLowerCase();
        if (journalMode != 'delete') {
          throw StateError('تعذر إيقاف وضع WAL بأمان؛ لم نتابع فتح قاعدة البيانات');
        }
        await db.execute('PRAGMA synchronous = FULL');
        // Android treats this PRAGMA as a row-producing statement; rawQuery is required.
        await db.rawQuery('PRAGMA secure_delete = ON');
        await db.execute('PRAGMA temp_store = MEMORY');
          // SQLCipher may also return a row for this PRAGMA on Android.
        await db.rawQuery('PRAGMA cipher_memory_security = ON');
        },
        onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE parties (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            account_no INTEGER NOT NULL UNIQUE CHECK (
              (account_no BETWEEN 100001 AND 199999) OR account_no >= 200001
            ),
            kind TEXT NOT NULL CHECK(kind IN ('customer','supplier')),
            name TEXT NOT NULL,
            phone TEXT NOT NULL DEFAULT '',
            address TEXT NOT NULL DEFAULT '',
            notes TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL,
            archived_at TEXT,
            CHECK ((kind = 'customer' AND account_no BETWEEN 100001 AND 199999) OR
                   (kind = 'supplier' AND account_no >= 200001))
          )
        ''');
        await db.execute('''
          CREATE TABLE transactions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            party_id INTEGER,
            type TEXT NOT NULL CHECK(type IN ('charge','payment','expense','income')),
            amount_minor INTEGER NOT NULL CHECK(amount_minor > 0),
            currency TEXT NOT NULL CHECK(currency IN ('SAR','YER')),
            note TEXT NOT NULL DEFAULT '',
            occurred_at TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT,
            deleted_at TEXT,
            CHECK ((party_id IS NULL AND type IN ('expense','income')) OR (party_id IS NOT NULL AND type IN ('charge','payment'))),
            FOREIGN KEY(party_id) REFERENCES parties(id)
          )
        ''');
        await db.execute('''
          CREATE TABLE audit_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            entity_type TEXT NOT NULL,
            entity_id INTEGER NOT NULL,
            action TEXT NOT NULL,
            details TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL
          )
        ''');
        // Create indexes only after every referenced table exists.
        await db.execute('CREATE INDEX idx_parties_kind_name ON parties(kind, name)');
        await db.execute('CREATE INDEX idx_transactions_party_date ON transactions(party_id, occurred_at)');
        await db.execute('CREATE INDEX idx_transactions_currency_type ON transactions(currency, type)');
        await db.execute('CREATE INDEX idx_transactions_active_date ON transactions(deleted_at, occurred_at DESC, id DESC)');
        await db.execute('CREATE INDEX idx_audit_entity_date ON audit_logs(entity_type, entity_id, created_at DESC)');
        await db.execute('''
          CREATE TRIGGER prevent_overpayment_insert
          BEFORE INSERT ON transactions
          WHEN NEW.party_id IS NOT NULL AND NEW.type = 'payment'
          BEGIN
            SELECT CASE WHEN NEW.amount_minor > COALESCE((
              SELECT SUM(CASE WHEN type = 'charge' THEN amount_minor ELSE -amount_minor END)
              FROM transactions
              WHERE party_id = NEW.party_id AND currency = NEW.currency AND deleted_at IS NULL
            ), 0) THEN RAISE(ABORT, 'payment exceeds outstanding balance') END;
          END
        ''');
        await db.execute('''
          CREATE TRIGGER prevent_negative_balance_update
          BEFORE UPDATE OF party_id, type, amount_minor, currency, deleted_at ON transactions
          WHEN (OLD.party_id IS NOT NULL AND OLD.deleted_at IS NULL) OR
               (NEW.party_id IS NOT NULL AND NEW.deleted_at IS NULL)
          BEGIN
            SELECT CASE WHEN OLD.party_id IS NOT NULL AND OLD.deleted_at IS NULL AND (
              NEW.party_id IS NULL OR NEW.deleted_at IS NOT NULL OR
              NEW.party_id != OLD.party_id OR NEW.currency != OLD.currency
            ) AND COALESCE((
              SELECT SUM(CASE WHEN type = 'charge' THEN amount_minor ELSE -amount_minor END)
              FROM transactions
              WHERE party_id = OLD.party_id AND currency = OLD.currency
                AND deleted_at IS NULL AND id != OLD.id
            ), 0) < 0 THEN
              RAISE(ABORT, 'operation would make the previous balance negative') END;

            SELECT CASE WHEN NEW.party_id IS NOT NULL AND NEW.deleted_at IS NULL AND (
              COALESCE((
                SELECT SUM(CASE WHEN type = 'charge' THEN amount_minor ELSE -amount_minor END)
                FROM transactions
                WHERE party_id = NEW.party_id AND currency = NEW.currency
                  AND deleted_at IS NULL AND id != OLD.id
              ), 0) + CASE WHEN NEW.type = 'charge' THEN NEW.amount_minor ELSE -NEW.amount_minor END
            ) < 0 THEN RAISE(ABORT, 'operation would make the balance negative') END;
          END
        ''');
        await db.execute('''
          CREATE TABLE app_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
        await db.insert('app_meta', {'key': 'next_customer_no', 'value': '100001'});
        await db.insert('app_meta', {'key': 'next_supplier_no', 'value': '200001'});
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // Version 2 adds account-number counters and the audit table to
        // installations created by earlier builds. Keep existing account data.
        if (oldVersion < 2) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS audit_logs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              entity_type TEXT NOT NULL,
              entity_id INTEGER NOT NULL,
              action TEXT NOT NULL,
              details TEXT NOT NULL DEFAULT '',
              created_at TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE IF NOT EXISTS app_meta (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )
          ''');
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_audit_entity_date ON audit_logs(entity_type, entity_id, created_at DESC)',
          );

          final customerRows = await db.rawQuery(
            "SELECT COALESCE(MAX(account_no), 100000) AS max_no FROM parties WHERE kind = 'customer'",
          );
          final supplierRows = await db.rawQuery(
            "SELECT COALESCE(MAX(account_no), 200000) AS max_no FROM parties WHERE kind = 'supplier'",
          );
          final customerMax = (customerRows.first['max_no'] as int?) ?? 100000;
          final supplierMax = (supplierRows.first['max_no'] as int?) ?? 200000;

          final customerCounterRows = await db.query(
            'app_meta', where: 'key = ?', whereArgs: ['next_customer_no'], limit: 1,
          );
          final supplierCounterRows = await db.query(
            'app_meta', where: 'key = ?', whereArgs: ['next_supplier_no'], limit: 1,
          );
          final oldCustomerCounter = customerCounterRows.isEmpty
              ? 100001
              : (int.tryParse(customerCounterRows.first['value'] as String? ?? '') ?? 100001);
          final oldSupplierCounter = supplierCounterRows.isEmpty
              ? 200001
              : (int.tryParse(supplierCounterRows.first['value'] as String? ?? '') ?? 200001);
          final nextCustomer = [100001, customerMax + 1, oldCustomerCounter].reduce((a, b) => a > b ? a : b);
          final nextSupplier = [200001, supplierMax + 1, oldSupplierCounter].reduce((a, b) => a > b ? a : b);

          await db.execute(
            'INSERT OR REPLACE INTO app_meta(key, value) VALUES(?, ?)',
            ['next_customer_no', '$nextCustomer'],
          );
          await db.execute(
            'INSERT OR REPLACE INTO app_meta(key, value) VALUES(?, ?)',
            ['next_supplier_no', '$nextSupplier'],
          );
        }
      },
      );
    } catch (error, stackTrace) {
      final dbExists = await databaseFile.exists();
      final dbLength = dbExists ? await databaseFile.length() : 0;
      final walFile = File('$filePath-wal');
      final shmFile = File('$filePath-shm');
      final journalFile = File('$filePath-journal');
      final walLength = await walFile.exists() ? await walFile.length() : 0;
      final shmLength = await shmFile.exists() ? await shmFile.length() : 0;
      final journalLength = await journalFile.exists() ? await journalFile.length() : 0;
      final diagnostic = 'DATABASE_OPEN_FAILED; exists=$dbExists; bytes=$dbLength; '
          'walBytes=$walLength; shmBytes=$shmLength; journalBytes=$journalLength; '
          'path=$filePath; cause=$error';
      Error.throwWithStackTrace(StateError(diagnostic), stackTrace);
    }
  }

  Future<bool> _isUsableDatabaseSet(String sourcePath, String password) async {
    final source = File(sourcePath);
    if (!await source.exists() || await source.length() < 100) return false;
    final checkPath = '$sourcePath.check-${DateTime.now().microsecondsSinceEpoch}';
    Database? candidate;
    try {
      await source.copy(checkPath);
      // WAL may contain committed data not yet folded into the main file.
      // The -shm file is transient and is always rebuilt by SQLite.
      for (final suffix in ['-wal', '-journal']) {
        final sourceSidecar = File('$sourcePath$suffix');
        if (await sourceSidecar.exists()) {
          await sourceSidecar.copy('$checkPath$suffix');
        }
      }
      candidate = await openDatabase(checkPath, password: password, singleInstance: false);
      final integrity = await candidate.rawQuery('PRAGMA integrity_check');
      final status = integrity.isEmpty ? '' : integrity.first.values.first.toString().toLowerCase();
      if (status != 'ok') return false;
      final tables = await candidate.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'");
      final names = tables.map((row) => row['name'] as String).toSet();
      if (!names.containsAll({'parties', 'transactions', 'audit_logs', 'app_meta'})) return false;
      await candidate.rawQuery('SELECT COUNT(*) FROM parties');
      final foreignKeyErrors = await candidate.rawQuery('PRAGMA foreign_key_check');
      if (foreignKeyErrors.isNotEmpty) return false;
      return true;
    } catch (_) {
      return false;
    } finally {
      await candidate?.close();
      for (final suffix in ['', '-wal', '-shm', '-journal']) {
        final temp = File('$checkPath$suffix');
        if (await temp.exists()) {
          try { await temp.delete(); } catch (_) { /* best-effort recovery cleanup */ }
        }
      }
    }
  }

  Future<void> _restoreRollbackSet(String path) async {
    final target = File(path);
    final wal = File('$path-wal');
    final shm = File('$path-shm');
    final journal = File('$path-journal');
    final rollback = File('$path.rollback');
    final rollbackWal = File('$path.rollback-wal');
    final rollbackJournal = File('$path.rollback-journal');
    for (final file in [target, wal, shm, journal]) {
      if (await file.exists()) await file.delete();
    }
    if (!await rollback.exists()) throw StateError('ملف الاستعادة الأصلي غير موجود');
    await rollback.copy(path);
    if (await rollbackWal.exists()) await rollbackWal.copy('$path-wal');
    if (await rollbackJournal.exists()) await rollbackJournal.copy('$path-journal');
  }

  Future<void> _preserveDatabaseSetWithoutKey(String path) async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      final source = File('$path$suffix');
      if (await source.exists()) {
        final preserved = File('$path.locked-$stamp$suffix');
        await source.copy(preserved.path);
      }
    }
  }

  Future<void> _recoverInterruptedRestore(String path) async {
    final journal = await SecurityService.instance.readDatabaseRestoreJournal();
    if (journal == null) return;
    final newPassword = journal['newPassword']!;
    final target = File(path);

    // Complete a user-confirmed fresh-ledger reset after an interrupted file
    // archive. The prior encrypted database is copied and verified before any
    // active file is removed; the archive is never opened with a guessed key.
    if (journal['mode'] == 'empty_database_reset') {
      final archiveSuffix = journal['archiveSuffix']!;
      final suffixes = ['', '-wal', '-shm', '-journal'];
      final pairs = <(File, File)>[];
      for (final suffix in suffixes) {
        final source = File('$path$suffix');
        final archived = File('$path.$archiveSuffix$suffix');
        if (await source.exists()) {
          if (!await archived.exists()) {
            await source.copy(archived.path);
          }
          final sourceLength = await source.length();
          final archiveLength = await archived.length();
          if (sourceLength != archiveLength) {
            throw StateError('تعذر التحقق من أرشيف قاعدة البيانات القديمة؛ لم نحذف الملف الأصلي');
          }
          pairs.add((source, archived));
        }
      }
      for (final pair in pairs) {
        if (await pair.$1.exists()) await pair.$1.delete();
      }
      await SecurityService.instance.replaceDatabasePassword(newPassword);
      await SecurityService.instance.finishDatabaseRestore();
      final resetLock = File('$path.operation.lock');
      if (await resetLock.exists()) {
        try { await resetLock.delete(); } catch (_) { /* stale lock cleanup can be retried */ }
      }
      return;
    }

    // A separately authenticated backup can be restored even when the old
    // SQLCipher key is gone. Keep the old encrypted bytes as a locked copy.
    if (journal['mode'] == 'without_old_password') {
      final restore = File('$path.restore');
      if (!await _isUsableDatabaseSet(path, newPassword)) {
        if (!await _isUsableDatabaseSet(restore.path, newPassword)) {
          throw StateError(
            'استعادة النسخة لم تكتمل، ولا توجد قاعدة صالحة بالمفتاح الجديد. '
            'لم نحذف قاعدة البيانات القديمة أو ملف النسخة؛ أعد اختيار النسخة الاحتياطية.',
          );
        }
        await _preserveDatabaseSetWithoutKey(path);
        for (final suffix in ['', '-wal', '-shm', '-journal']) {
          final active = File('$path$suffix');
          if (await active.exists()) await active.delete();
        }
        await restore.rename(path);
      }
      if (!await _isUsableDatabaseSet(path, newPassword)) {
        throw StateError('تعذر التحقق من قاعدة البيانات المستعادة؛ احتفظ بالنسخة ولا تحذف الملفات.');
      }
      await SecurityService.instance.replaceDatabasePassword(newPassword);
      await SecurityService.instance.finishDatabaseRestore();
      if (await restore.exists()) {
        try { await restore.delete(); } catch (_) { /* stale temp is safe to clean later */ }
      }
      if (!await target.exists()) throw StateError('قاعدة البيانات غير موجودة بعد الاستعادة');
      return;
    }

    final oldPassword = journal['oldPassword']!;
    final rollback = File('$path.rollback');

    // Test copies only, so trying the wrong SQLCipher key never alters the
    // active database or its WAL/SHM files.
    var activePassword = '';
    if (await _isUsableDatabaseSet(path, newPassword)) {
      activePassword = newPassword;
    } else if (await _isUsableDatabaseSet(path, oldPassword)) {
      activePassword = oldPassword;
    } else if (await _isUsableDatabaseSet(rollback.path, oldPassword)) {
      await _restoreRollbackSet(path);
      if (!await _isUsableDatabaseSet(path, oldPassword)) {
        throw StateError('تعذر التحقق من النسخة الأصلية؛ لم نكمل الاستعادة');
      }
      activePassword = oldPassword;
    } else {
      throw StateError('توقفت استعادة قاعدة البيانات بشكل غير مكتمل. لم نحذف ملفات الاستعادة؛ يلزم دعم فني قبل المتابعة.');
    }

    await SecurityService.instance.replaceDatabasePassword(activePassword);
    await SecurityService.instance.finishDatabaseRestore();
    // The active database has been validated. Leftover rollback files are now
    // stale and may be removed safely.
    for (final suffix in ['.rollback', '.rollback-wal', '.rollback-shm', '.restore']) {
      final stale = File('$path$suffix');
      if (await stale.exists()) {
        try { await stale.delete(); } catch (_) { /* cleanup can be retried */ }
      }
    }
    if (!await target.exists()) throw StateError('قاعدة البيانات غير موجودة بعد استعادة الحالة السابقة');
  }

  /// Archives an inaccessible encrypted DB and initializes a new empty DB.
  /// This method is reachable only from an explicit confirmation screen.
  Future<void> startFreshDatabaseAfterMissingKey() async {
    await close();
    final path = await databasePath;
    final operationLock = File('$path.operation.lock');
    if (await operationLock.exists()) {
      final age = DateTime.now().difference((await operationLock.stat()).modified);
      if (age > const Duration(minutes: 30)) {
        try { await operationLock.delete(); } catch (_) { /* another worker may own it */ }
      }
      if (await operationLock.exists()) {
        throw StateError('هناك عملية نسخ أو استعادة جارية؛ لا يمكن بدء دفتر جديد الآن');
      }
    }
    if (await SecurityService.instance.hasValidDatabasePassword()) {
      throw StateError('مفتاح التشفير موجود بالفعل؛ أوقفنا إعادة التهيئة لحماية البيانات');
    }
    if (await SecurityService.instance.readDatabaseRestoreJournal() != null) {
      throw StateError('توجد عملية استعادة غير مكتملة؛ أكمل الاستعادة قبل بدء دفتر جديد');
    }

    try {
      await operationLock.create(exclusive: true);
    } on FileSystemException {
      throw StateError('بدأت عملية نسخ أو استعادة أخرى؛ حاول مرة أخرى');
    }
    try {
      final newPassword = SecurityService.instance.generateDatabasePasswordForReset();
      final archiveSuffix = 'locked-${DateTime.now().microsecondsSinceEpoch}';
      await SecurityService.instance.beginEmptyDatabaseReset(newPassword, archiveSuffix);
      // Uses the same recovery path as app startup, so a process interruption
      // cannot leave a new key paired with the previous encrypted file.
      await _recoverInterruptedRestore(path);
      await database;
    } finally {
      if (await operationLock.exists()) {
        try { await operationLock.delete(); } catch (_) { /* recover stale lock on next startup */ }
      }
    }
  }

  void beginRestoreSwap() => _restoreSwapInProgress = true;
  void endRestoreSwap() => _restoreSwapInProgress = false;

  Future<int> createParty({
    required String kind,
    required String name,
    String phone = '',
    String address = '',
    String notes = '',
  }) async {
    final cleanedName = name.trim();
    final cleanedPhone = phone.trim();
    final cleanedAddress = address.trim();
    final cleanedNotes = notes.trim();

    if (cleanedName.isEmpty) throw ArgumentError('الاسم مطلوب');
    if (cleanedName.length > 120 || cleanedPhone.length > 32 ||
        cleanedAddress.length > 240 || cleanedNotes.length > 1000) {
      throw ArgumentError('بعض بيانات الحساب أطول من الحد المسموح');
    }
    if (kind != 'customer' && kind != 'supplier') {
      throw ArgumentError('نوع الحساب غير صحيح');
    }

    final db = await database;
    return db.transaction((txn) async {
      await _assertWritable();

      // Repair auxiliary tables when this installation carries an older
      // database file. These statements are idempotent and do not erase data.
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS app_meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      ''');
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS audit_logs (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          entity_type TEXT NOT NULL,
          entity_id INTEGER NOT NULL,
          action TEXT NOT NULL,
          details TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL
        )
      ''');

      // The persisted parties table is the source of truth. Deriving the next
      // number from MAX(account_no) prevents stale/missing counters from
      // blocking customer or supplier creation after an upgrade/restore.
      final base = kind == 'customer' ? 100001 : 200001;
      final rows = await txn.rawQuery(
        'SELECT COALESCE(MAX(account_no), ?) AS max_no FROM parties WHERE kind = ?',
        [base - 1, kind],
      );
      final maxNo = (rows.first['max_no'] as int?) ?? (base - 1);
      if (maxNo < base - 1 || maxNo >= 0x7fffffffffffffff) {
        throw StateError('تعذر توليد رقم حساب آمن؛ تواصل مع الدعم');
      }
      final accountNo = maxNo + 1;
      if (kind == 'customer' && accountNo > 199999) {
        throw StateError('اكتمل نطاق أرقام العملاء المحجوز؛ تواصل مع الدعم قبل إضافة حساب جديد');
      }

      final now = DateTime.now().toUtc().toIso8601String();
      final id = await txn.insert('parties', {
        'account_no': accountNo,
        'kind': kind,
        'name': cleanedName,
        'phone': cleanedPhone,
        'address': cleanedAddress,
        'notes': cleanedNotes,
        'created_at': now,
      });

      final key = kind == 'customer' ? 'next_customer_no' : 'next_supplier_no';
      await txn.insert(
        'app_meta',
        {'key': key, 'value': '${accountNo + 1}'},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.insert('audit_logs', {
        'entity_type': 'party',
        'entity_id': id,
        'action': 'create',
        'details': 'account_no=$accountNo;kind=$kind',
        'created_at': now,
      });
      return id;
    });
  }

  Future<void> updateParty({
    required int id,
    required String name,
    String phone = '',
    String address = '',
    String notes = '',
  }) async {
    final cleanedName = name.trim();
    if (cleanedName.isEmpty) throw ArgumentError('الاسم مطلوب');
    if (cleanedName.length > 120 || phone.trim().length > 32 ||
        address.trim().length > 240 || notes.trim().length > 1000) {
      throw ArgumentError('بعض بيانات الحساب أطول من الحد المسموح');
    }
    final db = await database;
    await db.transaction((txn) async {
      await _assertWritable();
      final existing = await txn.query(
        'parties', columns: ['id'],
        where: 'id = ? AND archived_at IS NULL', whereArgs: [id], limit: 1,
      );
      if (existing.isEmpty) throw StateError('الحساب غير موجود أو مؤرشف');
      final changed = await txn.update('parties', {
        'name': cleanedName,
        'phone': phone.trim(),
        'address': address.trim(),
        'notes': notes.trim(),
      }, where: 'id = ? AND archived_at IS NULL', whereArgs: [id]);
      if (changed != 1) throw StateError('تعذر تحديث بيانات الحساب');
      await txn.insert('audit_logs', {
        'entity_type': 'party', 'entity_id': id, 'action': 'update_profile',
        'details': 'profile_updated=true',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
  }

  Future<List<Map<String, Object?>>> getParties(String kind, {String search = ''}) async {
    if (kind != 'customer' && kind != 'supplier') throw ArgumentError('نوع الحساب غير صحيح');
    final db = await database;
    final q = _normalizeSearch(search);
    return db.rawQuery('''
      SELECT p.*,
        COALESCE(SUM(CASE WHEN t.currency = 'SAR' AND t.type = 'charge' THEN t.amount_minor
                          WHEN t.currency = 'SAR' AND t.type = 'payment' THEN -t.amount_minor ELSE 0 END), 0) AS balance_sar,
        COALESCE(SUM(CASE WHEN t.currency = 'YER' AND t.type = 'charge' THEN t.amount_minor
                          WHEN t.currency = 'YER' AND t.type = 'payment' THEN -t.amount_minor ELSE 0 END), 0) AS balance_yer
      FROM parties p
      LEFT JOIN transactions t ON t.party_id = p.id AND t.deleted_at IS NULL
      WHERE p.kind = ? AND p.archived_at IS NULL
        AND (? = '' OR p.name LIKE ? OR p.phone LIKE ? OR CAST(p.account_no AS TEXT) LIKE ?)
      GROUP BY p.id
      ORDER BY p.name COLLATE NOCASE ASC
    ''', [kind, q, '%$q%', '%$q%', '%$q%']);
  }

  Future<Map<String, Object?>?> getParty(int id) async {
    final db = await database;
    final rows = await db.query('parties', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, int>> getBalances(int partyId) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT currency,
        COALESCE(SUM(CASE WHEN type = 'charge' THEN amount_minor
                          WHEN type = 'payment' THEN -amount_minor ELSE 0 END), 0) AS balance
      FROM transactions
      WHERE party_id = ? AND type IN ('charge','payment') AND deleted_at IS NULL
      GROUP BY currency
    ''', [partyId]);
    final result = <String, int>{'SAR': 0, 'YER': 0};
    for (final row in rows) {
      result[row['currency'] as String] = (row['balance'] as int?) ?? 0;
    }
    return result;
  }

  Future<List<Map<String, Object?>>> getPartyTransactions(int partyId) async {
    final db = await database;
    return db.rawQuery('''
      SELECT t.*, p.name AS party_name, p.account_no AS account_no, p.kind AS party_kind
      FROM transactions t
      JOIN parties p ON p.id = t.party_id
      WHERE t.party_id = ? AND t.deleted_at IS NULL
      ORDER BY t.occurred_at DESC, t.id DESC
    ''', [partyId]);
  }

  Future<int> countParties(String kind) async {
    if (kind != 'customer' && kind != 'supplier') throw ArgumentError('نوع الحساب غير صحيح');
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS total FROM parties WHERE kind = ? AND archived_at IS NULL',
      [kind],
    );
    return (rows.first['total'] as int?) ?? 0;
  }

  Future<void> addPartyTransaction({
    required int partyId,
    required String type,
    required int amountMinor,
    required String currency,
    required DateTime occurredAt,
    String note = '',
  }) async {
    if (amountMinor <= 0 || amountMinor > 0x7fffffffffffffff) throw ArgumentError('أدخل مبلغًا صحيحًا ضمن الحد المسموح');
    if (note.trim().length > 1000) throw ArgumentError('ملاحظات العملية أطول من الحد المسموح');
    if (!['charge', 'payment'].contains(type)) throw ArgumentError('نوع العملية غير صحيح');
    if (!['SAR', 'YER'].contains(currency)) throw ArgumentError('العملة غير مدعومة');
    final db = await database;
    await db.transaction((txn) async {
      await _assertWritable();
      final party = await txn.query('parties', where: 'id = ?', whereArgs: [partyId], limit: 1);
      if (party.isEmpty) throw StateError('الحساب غير موجود');
      final archived = party.first['archived_at'] != null;
      if (archived && type != 'payment') {
        throw StateError('الحساب مؤرشف؛ يمكن تسجيل سداد الرصيد المتبقي فقط');
      }
      if (type == 'payment') {
        final rows = await txn.rawQuery('''
          SELECT COALESCE(SUM(CASE WHEN type = 'charge' THEN amount_minor ELSE -amount_minor END), 0) AS balance
          FROM transactions WHERE party_id = ? AND currency = ? AND deleted_at IS NULL
        ''', [partyId, currency]);
        final balance = (rows.first['balance'] as int?) ?? 0;
        if (amountMinor > balance) throw StateError('المبلغ أكبر من الرصيد المتبقي بهذه العملة');
      }
      final now = DateTime.now().toUtc().toIso8601String();
      final txId = await txn.insert('transactions', {
        'party_id': partyId,
        'type': type,
        'amount_minor': amountMinor,
        'currency': currency,
        'note': note.trim(),
        'occurred_at': occurredAt.toUtc().toIso8601String(),
        'created_at': now,
      });
      await txn.insert('audit_logs', {
        'entity_type': 'transaction', 'entity_id': txId, 'action': 'create',
        'details': 'party_id=$partyId;type=$type;amount_minor=$amountMinor;currency=$currency',
        'created_at': now,
      });
    });
  }

  Future<void> updatePartyTransaction({
    required int transactionId,
    required int partyId,
    required String type,
    required int amountMinor,
    required String currency,
    required DateTime occurredAt,
    String note = '',
  }) async {
    if (amountMinor <= 0 || amountMinor > 0x7fffffffffffffff) throw ArgumentError('أدخل مبلغًا صحيحًا ضمن الحد المسموح');
    if (note.trim().length > 1000) throw ArgumentError('ملاحظات العملية أطول من الحد المسموح');
    if (!['charge', 'payment'].contains(type)) throw ArgumentError('نوع العملية غير صحيح');
    if (!['SAR', 'YER'].contains(currency)) throw ArgumentError('العملة غير مدعومة');

    final db = await database;
    await db.transaction((txn) async {
      await _assertWritable();
      final oldRows = await txn.query(
        'transactions',
        where: 'id = ? AND party_id = ? AND deleted_at IS NULL',
        whereArgs: [transactionId, partyId],
        limit: 1,
      );
      if (oldRows.isEmpty) throw StateError('العملية غير موجودة أو تم حذفها');
      final partyRows = await txn.query(
        'parties', columns: ['id'],
        where: 'id = ? AND archived_at IS NULL',
        whereArgs: [partyId], limit: 1,
      );
      if (partyRows.isEmpty) throw StateError('لا يمكن تعديل عملية حساب مؤرشف');

      final old = oldRows.first;
      final oldCurrency = old['currency'] as String;
      final oldType = old['type'] as String;
      if (oldType == 'charge' && (oldCurrency != currency || type != 'charge')) {
        final sourceRows = await txn.rawQuery("""
          SELECT COALESCE(SUM(CASE WHEN type = 'charge' THEN amount_minor ELSE -amount_minor END), 0) AS balance
          FROM transactions
          WHERE party_id = ? AND currency = ? AND deleted_at IS NULL AND id != ?
        """, [partyId, oldCurrency, transactionId]);
        final remainingSourceBalance = (sourceRows.first['balance'] as int?) ?? 0;
        if (remainingSourceBalance < 0) {
          throw StateError('لا يمكن نقل الدين إلى عملة أخرى لأنه مرتبط بمدفوعات في العملة الأصلية');
        }
      }

      final rows = await txn.rawQuery("""
        SELECT COALESCE(SUM(CASE WHEN type = 'charge' THEN amount_minor ELSE -amount_minor END), 0) AS balance
        FROM transactions
        WHERE party_id = ? AND currency = ? AND deleted_at IS NULL AND id != ?
      """, [partyId, currency, transactionId]);
      final available = (rows.first['balance'] as int?) ?? 0;
      final projectedBalance = available + (type == 'charge' ? amountMinor : -amountMinor);
      if (projectedBalance < 0) {
        throw StateError('لا يمكن أن يتجاوز إجمالي السداد إجمالي الديون المسجلة');
      }

      final now = DateTime.now().toUtc().toIso8601String();
      await txn.update('transactions', {
        'type': type, 'amount_minor': amountMinor, 'currency': currency,
        'note': note.trim(), 'occurred_at': occurredAt.toUtc().toIso8601String(),
        'updated_at': now,
      }, where: 'id = ?', whereArgs: [transactionId]);
      await txn.insert('audit_logs', {
        'entity_type': 'transaction', 'entity_id': transactionId, 'action': 'update',
        'details': 'old_type=${old['type']};old_amount=${old['amount_minor']};old_currency=${old['currency']};new_type=$type;new_amount=$amountMinor;new_currency=$currency',
        'created_at': now,
      });
    });
  }

  Future<void> addGeneralTransaction({
    required String type,
    required int amountMinor,
    required String currency,
    required DateTime occurredAt,
    String note = '',
  }) async {
    if (!['expense', 'income'].contains(type) || amountMinor <= 0 || amountMinor > 0x7fffffffffffffff ||
        note.trim().length > 1000 || !['SAR', 'YER'].contains(currency)) {
      throw ArgumentError('بيانات العملية غير صحيحة');
    }
    final db = await database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((txn) async {
      await _assertWritable();
      final id = await txn.insert('transactions', {
        'party_id': null, 'type': type, 'amount_minor': amountMinor, 'currency': currency,
        'note': note.trim(), 'occurred_at': occurredAt.toUtc().toIso8601String(), 'created_at': now,
      });
      await txn.insert('audit_logs', {
        'entity_type': 'transaction', 'entity_id': id, 'action': 'create',
        'details': 'type=$type;amount_minor=$amountMinor;currency=$currency', 'created_at': now,
      });
    });
  }

  Future<void> updateGeneralTransaction({
    required int transactionId,
    required String type,
    required int amountMinor,
    required String currency,
    required DateTime occurredAt,
    String note = '',
  }) async {
    if (!['expense', 'income'].contains(type) || amountMinor <= 0 || amountMinor > 0x7fffffffffffffff ||
        note.trim().length > 1000 || !['SAR', 'YER'].contains(currency)) {
      throw ArgumentError('بيانات العملية غير صحيحة');
    }
    final db = await database;
    await db.transaction((txn) async {
      await _assertWritable();
      final rows = await txn.query(
        'transactions',
        where: "id = ? AND party_id IS NULL AND deleted_at IS NULL AND type IN ('expense', 'income')",
        whereArgs: [transactionId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('العملية العامة غير موجودة أو محذوفة');
      final old = rows.first;
      final now = DateTime.now().toUtc().toIso8601String();
      await txn.update('transactions', {
        'type': type,
        'amount_minor': amountMinor,
        'currency': currency,
        'note': note.trim(),
        'occurred_at': occurredAt.toUtc().toIso8601String(),
        'updated_at': now,
      }, where: 'id = ?', whereArgs: [transactionId]);
      await txn.insert('audit_logs', {
        'entity_type': 'transaction',
        'entity_id': transactionId,
        'action': 'update',
        'details': 'old_type=${old['type']};old_amount=${old['amount_minor']};old_currency=${old['currency']};new_type=$type;new_amount=$amountMinor;new_currency=$currency',
        'created_at': now,
      });
    });
  }

  Future<void> softDeleteTransaction(int id) async {
    final db = await database;
    await db.transaction((txn) async {
      await _assertWritable();
      final rows = await txn.query('transactions',
          where: 'id = ? AND deleted_at IS NULL', whereArgs: [id], limit: 1);
      if (rows.isEmpty) return;
      final row = rows.first;
      final partyId = row['party_id'] as int?;
      final currency = row['currency'] as String;
      final amount = row['amount_minor'] as int;

      // Do not let deleting a debt leave recorded payments above the remaining debt.
      if (partyId != null && row['type'] == 'charge') {
        final balances = await txn.rawQuery("""
          SELECT COALESCE(SUM(CASE WHEN type = 'charge' THEN amount_minor ELSE -amount_minor END), 0) AS balance
          FROM transactions
          WHERE party_id = ? AND currency = ? AND deleted_at IS NULL
        """, [partyId, currency]);
        final currentBalance = (balances.first['balance'] as int?) ?? 0;
        if (currentBalance < amount) {
          throw StateError('لا يمكن حذف هذا الدين لأنه مرتبط بمدفوعات مسجلة؛ راجع كشف الحساب أولًا');
        }
      }

      final now = DateTime.now().toUtc().toIso8601String();
      await txn.update('transactions', {'deleted_at': now}, where: 'id = ?', whereArgs: [id]);
      await txn.insert('audit_logs', {
        'entity_type': 'transaction', 'entity_id': id, 'action': 'soft_delete',
        'details': 'amount_minor=$amount;currency=$currency;party_id=${partyId ?? ''}',
        'created_at': now,
      });
    });
  }

  Future<void> archiveParty(int id) async {
    final db = await database;
    await db.transaction((txn) async {
      await _assertWritable();
      final now = DateTime.now().toUtc().toIso8601String();
      await txn.update('parties', {'archived_at': now}, where: 'id = ? AND archived_at IS NULL', whereArgs: [id]);
      await txn.insert('audit_logs', {
        'entity_type': 'party', 'entity_id': id, 'action': 'archive', 'details': 'preserve_history=true', 'created_at': now,
      });
    });
  }

  Future<void> restoreParty(int id) async {
    final db = await database;
    await db.transaction((txn) async {
      await _assertWritable();
      final now = DateTime.now().toUtc().toIso8601String();
      final changed = await txn.update('parties', {'archived_at': null}, where: 'id = ? AND archived_at IS NOT NULL', whereArgs: [id]);
      if (changed > 0) {
        await txn.insert('audit_logs', {
          'entity_type': 'party', 'entity_id': id, 'action': 'restore',
          'details': 'account_reopened=true', 'created_at': now,
        });
      }
    });
  }

  Future<List<Map<String, Object?>>> getArchivedParties(String kind) async {
    final db = await database;
    return db.query('parties', where: 'kind = ? AND archived_at IS NOT NULL', whereArgs: [kind], orderBy: 'archived_at DESC');
  }

  Future<Map<String, int>> getDashboardTotals(String kind) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT t.currency,
        COALESCE(SUM(CASE WHEN t.type = 'charge' THEN t.amount_minor ELSE -t.amount_minor END), 0) AS balance
      FROM parties p JOIN transactions t ON t.party_id = p.id
      WHERE p.kind = ? AND t.deleted_at IS NULL
      GROUP BY t.currency
    ''', [kind]);
    final result = <String, int>{'SAR': 0, 'YER': 0};
    for (final row in rows) {
      result[row['currency'] as String] = (row['balance'] as int?) ?? 0;
    }
    return result;
  }

  Future<List<Map<String, Object?>>> getRecentTransactions({int limit = 12}) async {
    final db = await database;
    return db.rawQuery('''
      SELECT t.*, p.name AS party_name, p.account_no AS account_no, p.kind AS party_kind, p.archived_at AS party_archived_at
      FROM transactions t LEFT JOIN parties p ON p.id = t.party_id
      WHERE t.deleted_at IS NULL
      ORDER BY t.occurred_at DESC, t.id DESC LIMIT ?
    ''', [limit]);
  }

  Future<Map<String, int>> getGeneralTotals(String currency) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT type, COALESCE(SUM(amount_minor),0) AS total
      FROM transactions
      WHERE currency = ? AND party_id IS NULL AND deleted_at IS NULL
      GROUP BY type
    ''', [currency]);
    final result = <String, int>{'expense': 0, 'income': 0};
    for (final row in rows) {
      result[row['type'] as String] = (row['total'] as int?) ?? 0;
    }
    return result;
  }

  Future<List<Map<String, Object?>>> getAllTransactions({
    String search = '',
    String? currency,
    DateTime? fromInclusive,
    DateTime? toExclusive,
  }) async {
    if (currency != null && !['SAR', 'YER'].contains(currency)) {
      throw ArgumentError('العملة غير مدعومة');
    }
    final db = await database;
    final q = _normalizeSearch(search);
    final from = fromInclusive?.toUtc().toIso8601String();
    final to = toExclusive?.toUtc().toIso8601String();
    return db.rawQuery('''
      SELECT t.*, p.name AS party_name, p.account_no AS account_no, p.kind AS party_kind, p.archived_at AS party_archived_at
      FROM transactions t LEFT JOIN parties p ON p.id = t.party_id
      WHERE t.deleted_at IS NULL
        AND (? = '' OR COALESCE(p.name,'') LIKE ? OR COALESCE(p.phone,'') LIKE ? OR
          COALESCE(t.note,'') LIKE ? OR CAST(t.amount_minor AS TEXT) LIKE ? OR
          (CAST(t.amount_minor / 100 AS TEXT) || '.' || printf('%02d', t.amount_minor % 100)) LIKE ? OR
          t.occurred_at LIKE ? OR t.currency LIKE ? OR CAST(COALESCE(p.account_no,0) AS TEXT) LIKE ?)
        AND (? IS NULL OR t.currency = ?)
        AND (? IS NULL OR t.occurred_at >= ?)
        AND (? IS NULL OR t.occurred_at < ?)
      ORDER BY t.occurred_at DESC, t.id DESC
    ''', [
      q, '%$q%', '%$q%', '%$q%', '%$q%', '%$q%', '%$q%', '%$q%', '%$q%',
      currency, currency, from, from, to, to,
    ]);
  }

  /// Creates a consistent SQLCipher snapshot. The exclusive operation lock
  /// serializes this with restores and prevents writes from other isolates.
  Future<Uint8List> createConsistentSnapshot() async {
    if (_snapshotInProgress) throw StateError('هناك عملية نسخ احتياطي قيد التنفيذ');
    final path = await databasePath;
    _snapshotInProgress = true;
    final lockFile = File('$path.operation.lock');
    var lockCreated = false;
    var connectionClosed = false;
    try {
      if (await lockFile.exists()) {
        final age = DateTime.now().difference((await lockFile.stat()).modified);
        if (age > const Duration(minutes: 30)) {
          try { await lockFile.delete(); } catch (_) { /* another operation may own it */ }
        }
      }
      try {
        await lockFile.create(exclusive: true);
        lockCreated = true;
      } on FileSystemException {
        throw StateError('هناك عملية نسخ أو استعادة أخرى؛ حاول لاحقًا');
      }
      final active = await _openSingleFlight();
      // In DELETE journal mode committed transactions are already in the main
      // database file; closing the sole foreground connection makes the file
      // safe to snapshot. Do not manually operate on WAL sidecars.
      await active.close();
      _database = null;
      connectionClosed = true;
      final file = File(path);
      if (!await file.exists()) throw StateError('قاعدة البيانات غير موجودة');
      return Uint8List.fromList(await file.readAsBytes());
    } finally {
      try {
        if (lockCreated && connectionClosed) _database ??= await _open();
      } finally {
        if (lockCreated && await lockFile.exists()) {
          try { await lockFile.delete(); } catch (_) { /* recover stale lock after process restart */ }
        }
        _snapshotInProgress = false;
      }
    }
  }

  Future<bool> checkpoint() async {
    final db = await database;
    final modeRows = await db.rawQuery('PRAGMA journal_mode');
    final mode = modeRows.isEmpty
        ? 'delete'
        : modeRows.first.values.first.toString().toLowerCase();
    if (mode != 'wal') return true;
    final result = await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    return result.isEmpty || (result.first['busy'] as int? ?? 0) == 0;
  }

  Future<void> close() async {
    final pending = _opening;
    if (pending != null) {
      try { await pending; } catch (_) { /* open errors are reported by the caller */ }
    }
    final current = _database;
    _database = null;
    await current?.close();
  }

  Future<void> reopen() async {
    await close();
    await _openSingleFlight();
  }
}
