import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/app_database.dart';
import 'security_service.dart';

class BackupService {
  BackupService._();
  static final BackupService instance = BackupService._();
  static const String backupExtension = 'bthbackup';
  final _aes = AesGcm.with256bits();
  final _kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 250000, bits: 256);
  static const int _maxBackupBytes = 64 * 1024 * 1024;
  bool _restoreInProgress = false;

  Future<Uint8List> createPortableBackup(String password) async {
    if (password.length < 12 || password.length > 128) {
      throw ArgumentError('استخدم عبارة مرور من 12 إلى 128 حرفًا');
    }
    final dbBytes = await AppDatabase.instance.createConsistentSnapshot();
    if (dbBytes.length > _maxBackupBytes) throw StateError('حجم قاعدة البيانات تجاوز الحد المسموح للنسخة');
    final dbPassword = await SecurityService.instance.getOrCreateDatabasePassword();
    final prefs = await SharedPreferences.getInstance();
    final profile = <String, String>{};
    for (final key in ['store_name', 'store_phone', 'store_address', 'store_activity', 'theme_mode']) {
      final value = prefs.getString(key);
      if (value != null) profile[key] = value;
    }
    final clearBundle = utf8.encode(jsonEncode({
      'databasePassword': dbPassword,
      'databaseBytes': base64Encode(dbBytes),
      'profile': profile,
    }));
    final salt = _randomBytes(16);
    final nonce = _randomBytes(12);
    final key = await _kdf.deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
    final box = await _aes.encrypt(clearBundle, secretKey: key, nonce: nonce);
    final envelope = {
      'format': 'bin-thabit-backup',
      'version': 1,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'kdf': 'PBKDF2-HMAC-SHA256-250000',
      'cipher': 'AES-256-GCM',
      'database': 'SQLCipher',
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
      'mac': base64Encode(box.mac.bytes),
      'data': base64Encode(box.cipherText),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
  }

  Future<void> sharePortableBackup(String password) async {
    final data = await createPortableBackup(password);
    final temp = await getTemporaryDirectory();
    final file = File(p.join(temp.path, 'bin_thabit_${DateTime.now().millisecondsSinceEpoch}.$backupExtension'));
    await file.writeAsBytes(data, flush: true);
    // Keep the content URI's source file available after the Android chooser
    // returns; the receiving app may read it asynchronously. Clean old exports
    // on the next share instead of deleting this file immediately.
    await _cleanupOldSharedBackups(temp);
    await SharePlus.instance.share(ShareParams(
      title: 'نسخة احتياطية - بن ثابت',
      text: 'نسخة مشفرة لتطبيق بن ثابت. احتفظ بكلمة المرور لاستعادتها.',
      files: [XFile(file.path, mimeType: 'application/octet-stream')],
    ));
  }

  Future<void> _cleanupOldSharedBackups(Directory temp) async {
    if (!await temp.exists()) return;
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    await for (final entity in temp.list()) {
      if (entity is! File || !p.basename(entity.path).startsWith('bin_thabit_') ||
          !entity.path.endsWith('.$backupExtension')) continue;
      try {
        if ((await entity.lastModified()).isBefore(cutoff)) await entity.delete();
      } catch (_) {
        // Cleanup is best-effort and must not block a requested backup.
      }
    }
  }

  Future<bool> restoreFromPicker(String password) async {
    if (_restoreInProgress) throw StateError('هناك عملية استعادة قيد التنفيذ');
    _restoreInProgress = true;
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: [backupExtension],
      );
      if (picked == null) return false;
      final pickedLength = picked.lengthSync() ?? await picked.length();
      if (pickedLength == null || pickedLength <= 0 || pickedLength > _maxBackupBytes * 2) {
        throw const FormatException('ملف النسخة فارغ أو أكبر من الحد المسموح');
      }
      final bytes = await picked.readAsBytes();
      if (bytes.isEmpty) throw StateError('تعذر قراءة ملف النسخة');
      if (bytes.length > _maxBackupBytes * 2) {
        throw const FormatException('ملف النسخة أكبر من الحد المسموح');
      }
      final bundleBytes = await _decryptPortableEnvelope(bytes, password);
      final decoded = jsonDecode(utf8.decode(bundleBytes));
      if (decoded is! Map<String, dynamic>) throw const FormatException('بنية النسخة غير صالحة');
      final dbBytes = base64Decode(decoded['databaseBytes'] as String);
      final newDbPassword = decoded['databasePassword'] as String;
      final profile = _safeProfile(decoded['profile']);
      if (dbBytes.isEmpty || dbBytes.length > _maxBackupBytes || newDbPassword.isEmpty) {
        throw const FormatException('محتوى النسخة غير مكتمل أو يتجاوز الحجم المسموح');
      }
      final keyBytes = base64Decode(newDbPassword);
      if (keyBytes.length != 32) throw const FormatException('مفتاح قاعدة البيانات غير صالح');
      await _validateDatabaseSnapshot(dbBytes, newDbPassword);
      await _replaceDatabase(dbBytes, newDbPassword, profile);
      return true;
    } on SecretBoxAuthenticationError {
      throw const FormatException('كلمة المرور غير صحيحة أو الملف تعرض للتعديل');
    } finally {
      _restoreInProgress = false;
    }
  }

  Future<void> restoreLatestLocalBackup() async {
    if (_restoreInProgress) throw StateError('هناك عملية استعادة قيد التنفيذ');
    _restoreInProgress = true;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final folder = Directory(p.join(docs.path, 'weekly_backups'));
      if (!await folder.exists()) throw const FormatException('لا توجد نسخة أسبوعية على هذا الجهاز');
      final backups = folder.listSync().whereType<File>().where((f) => f.path.endsWith('.bthlocal')).toList()
        ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
      if (backups.isEmpty) throw const FormatException('لا توجد نسخة أسبوعية على هذا الجهاز');
      final backupFile = backups.first;
      if (await backupFile.length() > _maxBackupBytes * 2) {
        throw const FormatException('ملف النسخة المحلية أكبر من الحد المسموح');
      }
      final decodedEnvelope = jsonDecode(await backupFile.readAsString());
      if (decodedEnvelope is! Map<String, dynamic>) throw const FormatException('ملف النسخة المحلية غير صالح');
      final envelope = decodedEnvelope;
      if (envelope['format'] != 'bin-thabit-local-backup' || envelope['version'] != 1) {
        throw const FormatException('إصدار النسخة المحلية غير مدعوم');
      }
      final autoKey = await SecurityService.instance.readAutoBackupKey();
      if (autoKey == null || autoKey.length != 32) throw const FormatException('مفتاح النسخة المحلية غير موجود أو غير صالح');
      final nonce = base64Decode(envelope['nonce'] as String);
      final mac = base64Decode(envelope['mac'] as String);
      final cipherText = base64Decode(envelope['data'] as String);
      if (nonce.length != 12 || mac.length != 16 || cipherText.isEmpty || cipherText.length > _maxBackupBytes * 2) {
        throw const FormatException('حقول النسخة المحلية غير صالحة');
      }
      final clear = await _aes.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(autoKey),
      );
      if (clear.length > _maxBackupBytes * 2) throw const FormatException('محتوى النسخة المحلية أكبر من الحد المسموح');
      final decodedBundle = jsonDecode(utf8.decode(clear));
      if (decodedBundle is! Map<String, dynamic>) throw const FormatException('محتوى النسخة المحلية غير صالح');
      final bundle = decodedBundle;
      final dbBytes = base64Decode(bundle['databaseBytes'] as String);
      final dbPassword = bundle['databasePassword'] as String;
      if (dbBytes.isEmpty || dbPassword.isEmpty) throw const FormatException('محتوى النسخة المحلية غير مكتمل');
      final profile = _safeProfile(bundle['profile']);
      if (dbBytes.length > _maxBackupBytes) throw const FormatException('حجم النسخة أكبر من الحد المسموح');
      final keyBytes = base64Decode(dbPassword);
      if (keyBytes.length != 32) throw const FormatException('مفتاح قاعدة البيانات غير صالح');
      await _validateDatabaseSnapshot(dbBytes, dbPassword);
      await _replaceDatabase(dbBytes, dbPassword, profile);
    } on SecretBoxAuthenticationError {
      throw const FormatException('تعذر فك تشفير النسخة المحلية أو أنها تعرضت للتلف');
    } on FormatException {
      rethrow;
    } finally {
      _restoreInProgress = false;
    }
  }

  Map<String, dynamic> _safeProfile(Object? value) {
    if (value is! Map) return <String, dynamic>{};
    const allowed = {'store_name', 'store_phone', 'store_address', 'store_activity', 'theme_mode'};
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      if (entry.key is String && allowed.contains(entry.key) && entry.value is String) {
        final text = (entry.value as String);
        if (text.length <= 500) result[entry.key as String] = text;
      }
    }
    return result;
  }

  Future<void> _validateDatabaseSnapshot(List<int> bytes, String password) async {
    final tempDir = await getTemporaryDirectory();
    final path = p.join(tempDir.path, 'bt_validate_${DateTime.now().microsecondsSinceEpoch}.db');
    final file = File(path);
    Database? candidate;
    try {
      await file.writeAsBytes(bytes, flush: true);
      candidate = await openDatabase(path, password: password, singleInstance: false);
      final integrity = await candidate.rawQuery('PRAGMA integrity_check');
      final status = integrity.isEmpty ? '' : integrity.first.values.first.toString().toLowerCase();
      if (status != 'ok') throw const FormatException('قاعدة البيانات داخل النسخة غير سليمة');
      final foreignKeyErrors = await candidate.rawQuery('PRAGMA foreign_key_check');
      if (foreignKeyErrors.isNotEmpty) throw const FormatException('النسخة تحتوي على علاقات حسابات غير سليمة');
      final tables = await candidate.rawQuery("""
        SELECT name FROM sqlite_master WHERE type = 'table'
      """);
      final names = tables.map((row) => row['name'] as String).toSet();
      const required = {'parties', 'transactions', 'audit_logs', 'app_meta'};
      if (!names.containsAll(required)) throw const FormatException('النسخة لا تحتوي على جداول بن ثابت المطلوبة');
      final partyColumns = await candidate.rawQuery('PRAGMA table_info(parties)');
      final transactionColumns = await candidate.rawQuery('PRAGMA table_info(transactions)');
      final auditColumns = await candidate.rawQuery('PRAGMA table_info(audit_logs)');
      final metaColumns = await candidate.rawQuery('PRAGMA table_info(app_meta)');
      final partyNames = partyColumns.map((row) => row['name'] as String).toSet();
      final transactionNames = transactionColumns.map((row) => row['name'] as String).toSet();
      final auditNames = auditColumns.map((row) => row['name'] as String).toSet();
      final metaNames = metaColumns.map((row) => row['name'] as String).toSet();
      if (!partyNames.containsAll({'id', 'account_no', 'kind', 'name'}) ||
          !transactionNames.containsAll({'id', 'party_id', 'type', 'amount_minor', 'currency', 'deleted_at'}) ||
          !auditNames.containsAll({'id', 'entity_type', 'entity_id', 'action', 'created_at'}) ||
          !metaNames.containsAll({'key', 'value'})) {
        throw const FormatException('بنية قاعدة البيانات داخل النسخة غير متوافقة');
      }
      final invalidLinks = await candidate.rawQuery('''
        SELECT COUNT(*) AS total FROM transactions
        WHERE (party_id IS NULL AND type NOT IN ('expense','income'))
           OR (party_id IS NOT NULL AND type NOT IN ('charge','payment'))
           OR amount_minor <= 0 OR currency NOT IN ('SAR','YER')
      ''');
      if ((invalidLinks.first['total'] as int? ?? 0) != 0) {
        throw const FormatException('النسخة تحتوي على حركات مالية غير متوافقة');
      }
      final duplicateAccounts = await candidate.rawQuery('''
        SELECT account_no FROM parties GROUP BY account_no HAVING COUNT(*) > 1 LIMIT 1
      ''');
      if (duplicateAccounts.isNotEmpty) throw const FormatException('النسخة تحتوي على أرقام حسابات مكررة');
      final invalidAccounts = await candidate.rawQuery('''
        SELECT COUNT(*) AS total FROM parties
        WHERE (kind = 'customer' AND (account_no < 100001 OR account_no >= 200000))
           OR (kind = 'supplier' AND account_no < 200001)
           OR kind NOT IN ('customer','supplier')
      ''');
      if ((invalidAccounts.first['total'] as int? ?? 0) != 0) {
        throw const FormatException('النسخة تحتوي على أرقام حسابات أو أنواع غير صحيحة');
      }
      final counters = await candidate.query('app_meta', where: 'key IN (?, ?)', whereArgs: ['next_customer_no', 'next_supplier_no']);
      final counterMap = {for (final row in counters) row['key'] as String: int.tryParse(row['value'] as String? ?? '')};
      final maxCustomer = await candidate.rawQuery("SELECT COALESCE(MAX(account_no), 100000) AS value FROM parties WHERE kind = 'customer'");
      final maxSupplier = await candidate.rawQuery("SELECT COALESCE(MAX(account_no), 200000) AS value FROM parties WHERE kind = 'supplier'");
      final nextCustomer = counterMap['next_customer_no'] ?? 0;
      final nextSupplier = counterMap['next_supplier_no'] ?? 0;
      if (nextCustomer < 100001 || nextCustomer > 200000 || nextSupplier < 200001 ||
          nextCustomer <= (maxCustomer.first['value'] as int? ?? 100000) ||
          nextSupplier <= (maxSupplier.first['value'] as int? ?? 200000)) {
        throw const FormatException('عداد أرقام الحسابات غير صالح أو قد يكرر رقمًا سابقًا');
      }
      final negativeBalances = await candidate.rawQuery('''
        SELECT party_id, currency FROM transactions
        WHERE deleted_at IS NULL AND party_id IS NOT NULL
        GROUP BY party_id, currency
        HAVING SUM(CASE WHEN type = 'charge' THEN amount_minor ELSE -amount_minor END) < 0
        LIMIT 1
      ''');
      if (negativeBalances.isNotEmpty) {
        throw const FormatException('النسخة تحتوي على رصيد حساب سالب؛ يلزم مراجعة الكشف');
      }
    } on DatabaseException {
      throw const FormatException('تعذر فتح قاعدة البيانات؛ تحقق من النسخة وكلمة المرور');
    } finally {
      await candidate?.close();
      for (final suffix in ['', '-wal', '-shm']) {
        final sidecar = File('$path$suffix');
        if (await sidecar.exists()) await sidecar.delete();
      }
    }
  }

  Future<void> _replaceDatabase(List<int> dbBytes, String newDbPassword, Map<String, dynamic> profile) async {
    final path = await AppDatabase.instance.databasePath;
    final target = File(path);
    final temp = File('$path.restore');
    final rollback = File('$path.rollback');
    final rollbackWal = File('$path.rollback-wal');
    final rollbackShm = File('$path.rollback-shm');
    final wal = File('$path-wal');
    final shm = File('$path-shm');
    final oldDbPassword = await SecurityService.instance.getOrCreateDatabasePassword();
    final prefs = await SharedPreferences.getInstance();
    const profileKeys = ['store_name', 'store_phone', 'store_address', 'store_activity', 'theme_mode'];
    final oldProfile = <String, String>{};
    for (final key in profileKeys) {
      final value = prefs.getString(key);
      if (value != null) oldProfile[key] = value;
    }

    var hadTarget = false;
    var hadWal = false;
    var backupsReady = false;
    var replacementStarted = false;
    var completed = false;
    var rollbackCompleted = false;
    var operationLockCreated = false;
    var restoreSwapMarked = false;
    final operationLock = File('$path.operation.lock');

    // Backups and restores share one cross-isolate lock. Never replace a DB
    // while a background snapshot is being produced.
    try {
      if (await operationLock.exists()) {
        final age = DateTime.now().difference((await operationLock.stat()).modified);
        if (age > const Duration(minutes: 30)) {
          try { await operationLock.delete(); } catch (_) { /* another operation may own it */ }
        }
      }
      await operationLock.create(exclusive: true);
      operationLockCreated = true;
      final checkpointed = await AppDatabase.instance.checkpoint();
      if (!checkpointed) throw StateError('هناك عملية مالية نشطة؛ تعذر الاستعادة بأمان. أعد المحاولة.');
      AppDatabase.instance.beginRestoreSwap();
      restoreSwapMarked = true;
    } on FileSystemException {
      throw StateError('هناك عملية نسخ أو استعادة أخرى؛ حاول بعد انتهائها');
    } catch (_) {
      if (operationLockCreated && await operationLock.exists()) {
        try { await operationLock.delete(); } catch (_) { /* stale lock recovery is available */ }
      }
      rethrow;
    }

    // Preserve the original DB and every SQLite sidecar before changing any file.
    try {
      await AppDatabase.instance.close();

      hadTarget = await target.exists();
      hadWal = await wal.exists();

      for (final file in [temp, rollback, rollbackWal, rollbackShm]) {
        if (await file.exists()) await file.delete();
      }
      await temp.writeAsBytes(dbBytes, flush: true);
      if (hadTarget) await target.copy(rollback.path);
      if (hadWal) await wal.copy(rollbackWal.path);
      // Do not preserve -shm: it is transient shared-memory state and must be rebuilt.
      backupsReady = hadTarget;
      if (!backupsReady) throw StateError('تعذر إنشاء نسخة رجوع من قاعدة البيانات الحالية');
      await SecurityService.instance.beginDatabaseRestore(oldDbPassword, newDbPassword);

      // The encrypted journal lets startup choose the old or new DB key after
      // a process kill at any point in the file replacement sequence.
      replacementStarted = true;
      if (hadWal && await wal.exists()) await wal.delete();
      if (await shm.exists()) await shm.delete();
      if (hadTarget && await target.exists()) await target.delete();
      await temp.rename(path);

      await SecurityService.instance.replaceDatabasePassword(newDbPassword);
      await AppDatabase.instance.reopen();
      final db = await AppDatabase.instance.database;
      final integrity = await db.rawQuery('PRAGMA integrity_check');
      final integrityStatus = integrity.isEmpty ? '' : integrity.first.values.first.toString().toLowerCase();
      if (integrityStatus != 'ok') throw StateError('قاعدة البيانات المستعادة لم تجتز فحص السلامة');
      await db.rawQuery('SELECT COUNT(*) FROM parties');

      for (final key in profileKeys) {
        if (profile.containsKey(key)) {
          await prefs.setString(key, profile[key]!);
        } else {
          await prefs.remove(key);
        }
      }
      await SecurityService.instance.finishDatabaseRestore();
      completed = true;
    } catch (error, stackTrace) {
      try {
        await AppDatabase.instance.close();
        if (replacementStarted && backupsReady) {
          // Restore the original encrypted database and its SQLite sidecars.
          for (final file in [target, wal, shm]) {
            if (await file.exists()) await file.delete();
          }
          await rollback.copy(path);
          if (hadWal && await rollbackWal.exists()) await rollbackWal.copy('$path-wal');
          // SQLite recreates the shared-memory file from the main DB/WAL.
        }
        await SecurityService.instance.replaceDatabasePassword(oldDbPassword);
        await AppDatabase.instance.reopen();
        for (final key in profileKeys) {
          if (oldProfile.containsKey(key)) {
            await prefs.setString(key, oldProfile[key]!);
          } else {
            await prefs.remove(key);
          }
        }
        await SecurityService.instance.finishDatabaseRestore();
        rollbackCompleted = true;
      } catch (_) {
        // Keep the secure recovery journal and rollback copy. The next launch
        // will validate both keys and recover the only usable database set.
        throw StateError('تعذر إكمال الاستعادة؛ احتفظ بملف النسخة ولا تحذف بيانات التطبيق. سيحاول التطبيق استعادة قاعدة البيانات عند التشغيل التالي.');
      }
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      try { if (await temp.exists()) await temp.delete(); } catch (_) { /* leftover temp file is not the active database */ }
      if (restoreSwapMarked) AppDatabase.instance.endRestoreSwap();
      if (operationLockCreated && await operationLock.exists()) {
        try { await operationLock.delete(); } catch (_) { /* stale lock recovery is available */ }
      }
      if (completed || rollbackCompleted) {
        for (final file in [rollback, rollbackWal, rollbackShm]) {
          try { if (await file.exists()) await file.delete(); } catch (_) { /* stale rollback files are safe to remove later */ }
        }
      }
    }
  }

  Future<Uint8List> decryptPortableBackup(List<int> payload, String password) => _decryptPortableEnvelope(payload, password);

  Future<Uint8List> _decryptPortableEnvelope(List<int> payload, String password) async {
    if (payload.isEmpty || payload.length > _maxBackupBytes * 2) {
      throw const FormatException('ملف النسخة فارغ أو أكبر من الحد المسموح');
    }
    final Map<String, dynamic> json;
    try { json = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>; }
    catch (_) { throw const FormatException('ملف النسخة غير صالح'); }
    if (json['format'] != 'bin-thabit-backup' || json['version'] != 1) {
      throw const FormatException('إصدار النسخة غير مدعوم');
    }
    if (json['kdf'] != 'PBKDF2-HMAC-SHA256-250000' ||
        json['cipher'] != 'AES-256-GCM' || json['database'] != 'SQLCipher') {
      throw const FormatException('خوارزميات ملف النسخة غير معروفة');
    }
    try {
      if (password.length < 12 || password.length > 128) {
        throw const FormatException('كلمة المرور غير صحيحة');
      }
      final salt = base64Decode(json['salt'] as String);
      final nonce = base64Decode(json['nonce'] as String);
      final macBytes = base64Decode(json['mac'] as String);
      final cipherText = base64Decode(json['data'] as String);
      if (salt.length != 16 || nonce.length != 12 || macBytes.length != 16 ||
          cipherText.isEmpty || cipherText.length > _maxBackupBytes * 2) {
        throw const FormatException('حقول ملف النسخة غير صالحة');
      }
      final key = await _kdf.deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
      final clear = await _aes.decrypt(SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes)), secretKey: key);
      if (clear.length > _maxBackupBytes * 2) throw const FormatException('محتوى النسخة أكبر من الحد المسموح');
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw const FormatException('كلمة المرور غير صحيحة أو الملف تعرض للتعديل');
    } catch (e) {
      if (e is FormatException) rethrow;
      throw const FormatException('تعذر فك تشفير النسخة الاحتياطية');
    }
  }

  Future<void> createScheduledLocalBackup() async {
    final dbBytes = await AppDatabase.instance.createConsistentSnapshot();
    if (dbBytes.length > _maxBackupBytes) throw StateError('حجم قاعدة البيانات تجاوز الحد المسموح للنسخة');
    final databasePassword = await SecurityService.instance.getOrCreateDatabasePassword();
    final autoKey = await SecurityService.instance.getOrCreateAutoBackupKey();
    final nonce = _randomBytes(12);
    final prefs = await SharedPreferences.getInstance();
    final profile = <String, String>{};
    for (final key in ['store_name', 'store_phone', 'store_address', 'store_activity', 'theme_mode']) {
      final value = prefs.getString(key);
      if (value != null) profile[key] = value;
    }
    final clear = utf8.encode(jsonEncode({'databasePassword': databasePassword, 'databaseBytes': base64Encode(dbBytes), 'profile': profile}));
    final box = await _aes.encrypt(clear, secretKey: SecretKey(autoKey), nonce: nonce);
    final envelope = jsonEncode({
      'format': 'bin-thabit-local-backup', 'version': 1,
      'nonce': base64Encode(nonce), 'mac': base64Encode(box.mac.bytes),
      'data': base64Encode(box.cipherText),
    });
    final docs = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(docs.path, 'weekly_backups'));
    await folder.create(recursive: true);
    final file = File(p.join(folder.path, 'auto_${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}.bthlocal'));
    final partial = File('${file.path}.partial');
    try {
      await partial.writeAsString(envelope, flush: true);
      await partial.rename(file.path);
    } finally {
      if (await partial.exists()) {
        try { await partial.delete(); } catch (_) { /* incomplete backups are ignored on next cleanup */ }
      }
    }
    final backups = folder.listSync().whereType<File>().where((f) => f.path.endsWith('.bthlocal')).toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    for (final old in backups.skip(7)) { await old.delete(); }
  }

  List<int> _randomBytes(int count) {
    final random = Random.secure();
    return List<int>.generate(count, (_) => random.nextInt(256));
  }
}
