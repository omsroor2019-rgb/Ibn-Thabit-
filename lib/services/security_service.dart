import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

class SecurityService {
  SecurityService._();
  static final SecurityService instance = SecurityService._();
  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _pinRecordKey = 'bt_pin_record_v2';
  static const String _legacyPinHashKey = 'bt_pin_hash_v1';
  static const String _legacyPinSaltKey = 'bt_pin_salt_v1';
  static const String _autoBackupKeyKey = 'bt_auto_backup_key_v1';
  static const String _databasePasswordKey = 'bt_database_password_v1';
  static const String _databaseRestoreJournalKey = 'bt_database_restore_journal_v1';
  static const String _failedPinAttemptsKey = 'bt_failed_pin_attempts_v1';
  static const String _pinLockUntilKey = 'bt_pin_lock_until_v1';
  final LocalAuthentication _auth = LocalAuthentication();

  Future<bool> hasPin() async =>
      (await _storage.read(key: _pinRecordKey)) != null ||
      (await _storage.read(key: _legacyPinHashKey)) != null;

  Future<void> setPin(String pin) async {
    if (!RegExp(r'^\d{6,8}$').hasMatch(pin)) {
      throw ArgumentError('رمز القفل يجب أن يكون من 6 إلى 8 أرقام');
    }
    final firstDigit = int.parse(pin[0]);
    final ascendingSequence = List<int>.generate(pin.length, (index) => (firstDigit + index) % 10).join() == pin;
    final descendingSequence = List<int>.generate(pin.length, (index) => (firstDigit - index + 10) % 10).join() == pin;
    final repeatedPair = RegExp(r'^(\d{2})\1{2,3}$').hasMatch(pin);
    if (RegExp(r'^(\d)\1+$').hasMatch(pin) || ascendingSequence || descendingSequence || repeatedPair ||
        const {'123456', '1234567', '12345678', '654321', '111111', '000000', '121212', '112233'}.contains(pin)) {
      throw ArgumentError('اختر رمزًا غير متوقع؛ تجنب الأرقام المتكررة والمتسلسلة');
    }
    final salt = _randomBytes(16);
    final hash = await _derivePin(pin, salt);
    // Salt and verifier are stored together so a PIN change is a single secure write.
    await _storage.write(key: _pinRecordKey, value: jsonEncode({
      'version': 2,
      'salt': base64Encode(salt),
      'hash': base64Encode(hash),
    }));
    await _storage.delete(key: _legacyPinSaltKey);
    await _storage.delete(key: _legacyPinHashKey);
  }

  Future<bool> verifyPin(String pin) async {
    final lockUntilText = await _storage.read(key: _pinLockUntilKey);
    final lockUntil = int.tryParse(lockUntilText ?? '0') ?? 0;
    if (DateTime.now().millisecondsSinceEpoch < lockUntil) return false;
    String? saltText;
    String? hashText;
    final recordText = await _storage.read(key: _pinRecordKey);
    if (recordText != null) {
      final record = jsonDecode(recordText);
      if (record is! Map<String, dynamic> || record['version'] != 2 ||
          record['salt'] is! String || record['hash'] is! String) return false;
      saltText = record['salt'] as String;
      hashText = record['hash'] as String;
    } else {
      // Read the previous two-key record once for backward compatibility.
      saltText = await _storage.read(key: _legacyPinSaltKey);
      hashText = await _storage.read(key: _legacyPinHashKey);
    }
    if (saltText == null || hashText == null) return false;
    final salt = base64Decode(saltText);
    final expected = base64Decode(hashText);
    if (salt.length != 16 || expected.length != 32) return false;
    final actual = await _derivePin(pin, salt);
    if (actual.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < actual.length; i++) {
      diff |= actual[i] ^ expected[i];
    }
    final valid = diff == 0;
    if (valid) {
      await _storage.delete(key: _failedPinAttemptsKey);
      await _storage.delete(key: _pinLockUntilKey);
      return true;
    }
    final attempts = (int.tryParse(await _storage.read(key: _failedPinAttemptsKey) ?? '0') ?? 0) + 1;
    if (attempts >= 5) {
      final until = DateTime.now().add(const Duration(seconds: 60)).millisecondsSinceEpoch;
      await _storage.write(key: _pinLockUntilKey, value: '$until');
      await _storage.write(key: _failedPinAttemptsKey, value: '0');
    } else {
      await _storage.write(key: _failedPinAttemptsKey, value: '$attempts');
    }
    return false;
  }

  Future<List<int>> _derivePin(String pin, List<int> salt) async {
    final kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 180000, bits: 256);
    final key = await kdf.deriveKey(secretKey: SecretKey(utf8.encode(pin)), nonce: salt);
    return key.extractBytes();
  }

  Future<bool> canUseBiometrics() async {
    try {
      final hardware = await _auth.canCheckBiometrics;
      final supported = await _auth.isDeviceSupported();
      final enrolled = await _auth.getAvailableBiometrics();
      return hardware && supported && enrolled.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> authenticateBiometric() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'أكد هويتك لفتح حسابات بن ثابت',
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }

  Future<String?> readDatabasePassword() async {
    final stored = await _storage.read(key: _databasePasswordKey);
    if (stored == null) return null;
    try {
      if (base64Decode(stored).length != 32) {
        throw const FormatException('invalid database key length');
      }
    } catch (_) {
      throw StateError('مفتاح تشفير قاعدة البيانات المحفوظ غير صالح. لم نغيّره حفاظًا على البيانات.');
    }
    return stored;
  }

  Future<String> getOrCreateDatabasePassword({bool databaseExists = false}) async {
    final stored = await readDatabasePassword();
    if (stored != null) return stored;

    // Never invent a new key for an existing encrypted DB. Doing so would
    // make the old file permanently unreadable with the newly generated key.
    if (databaseExists) {
      throw StateError(
        'ملف قاعدة البيانات موجود لكن مفتاح التشفير غير موجود في التخزين الآمن. '
        'أوقفنا إنشاء مفتاح بديل لحماية بياناتك. لا تحذف التطبيق أو ملف قاعدة البيانات؛ '
        'يلزم استرجاع المفتاح الأصلي أو استعادة نسخة احتياطية مشفرة.',
      );
    }

    final value = base64Encode(_randomBytes(32));
    await _storage.write(key: _databasePasswordKey, value: value);
    final confirmed = await readDatabasePassword();
    if (confirmed != value) {
      throw StateError('تعذر حفظ مفتاح تشفير قاعدة البيانات في التخزين الآمن.');
    }
    return value;
  }

  Future<void> replaceDatabasePassword(String value) async {
    try {
      if (base64Decode(value).length != 32) {
        throw const FormatException('invalid database key length');
      }
    } catch (_) {
      throw ArgumentError('مفتاح قاعدة البيانات غير صالح');
    }
    await _storage.write(key: _databasePasswordKey, value: value);
    final confirmed = await readDatabasePassword();
    if (confirmed != value) {
      throw StateError('تعذر التحقق من حفظ مفتاح قاعدة البيانات الجديد.');
    }
  }


  Future<void> beginDatabaseRestore(String oldPassword, String newPassword) async {
    final oldBytes = base64Decode(oldPassword);
    final newBytes = base64Decode(newPassword);
    if (oldBytes.length != 32 || newBytes.length != 32) {
      throw ArgumentError('مفاتيح قاعدة البيانات غير صالحة');
    }
    // A single secure-storage record makes startup recovery possible if the
    // process is killed while replacing the encrypted database file.
    await _storage.write(
      key: _databaseRestoreJournalKey,
      value: jsonEncode({
        'version': 1,
        'oldPassword': oldPassword,
        'newPassword': newPassword,
      }),
    );
  }

  /// Starts a recovery restore when the previous database key is missing.
  /// This is allowed only after an external backup has been decrypted and its
  /// SQLCipher database has passed integrity checks.
  Future<void> beginDatabaseRestoreWithoutOldPassword(String newPassword) async {
    if (base64Decode(newPassword).length != 32) {
      throw ArgumentError('مفتاح قاعدة البيانات الجديدة غير صالح');
    }
    await _storage.write(
      key: _databaseRestoreJournalKey,
      value: jsonEncode({
        'version': 2,
        'mode': 'restore_without_old_password',
        'newPassword': newPassword,
      }),
    );
  }

  Future<Map<String, String>?> readDatabaseRestoreJournal() async {
    final raw = await _storage.read(key: _databaseRestoreJournalKey);
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic>) throw const FormatException();

      if (value['version'] == 2 &&
          value['mode'] == 'restore_without_old_password' &&
          value['newPassword'] is String) {
        final newPassword = value['newPassword'] as String;
        if (base64Decode(newPassword).length != 32) throw const FormatException();
        return {'mode': 'without_old_password', 'newPassword': newPassword};
      }

      if (value['version'] != 1 || value['oldPassword'] is! String ||
          value['newPassword'] is! String) {
        throw const FormatException();
      }
      final oldPassword = value['oldPassword'] as String;
      final newPassword = value['newPassword'] as String;
      if (base64Decode(oldPassword).length != 32 || base64Decode(newPassword).length != 32) {
        throw const FormatException();
      }
      return {'mode': 'with_old_password', 'oldPassword': oldPassword, 'newPassword': newPassword};
    } catch (_) {
      throw StateError('سجل استعادة قاعدة البيانات تالف؛ أوقفنا الفتح لحماية البيانات');
    }
  }

  Future<void> finishDatabaseRestore() async {
    await _storage.delete(key: _databaseRestoreJournalKey);
  }

  Future<List<int>?> readAutoBackupKey() async {
    final stored = await _storage.read(key: _autoBackupKeyKey);
    return stored == null ? null : base64Decode(stored);
  }

  Future<List<int>> getOrCreateAutoBackupKey() async {
    final stored = await _storage.read(key: _autoBackupKeyKey);
    if (stored != null) return base64Decode(stored);
    final key = _randomBytes(32);
    await _storage.write(key: _autoBackupKeyKey, value: base64Encode(key));
    return key;
  }

  List<int> _randomBytes(int count) {
    final random = Random.secure();
    return List<int>.generate(count, (_) => random.nextInt(256));
  }
}
