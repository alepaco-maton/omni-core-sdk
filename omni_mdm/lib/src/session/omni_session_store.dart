import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'omni_session.dart';

/// Persiste credenciales de instancia en secure storage (Keystore/Keychain).
class OmniSessionStore {
  OmniSessionStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                storageNamespace: 'omni_mdm',
                migrateOnAlgorithmChange: false,
              ),
            );

  static const _kInstanceId = 'omni_instance_id';
  static const _kBusinessId = 'omni_business_id';
  static const _kInstanceToken = 'omni_instance_token';
  static const _kHardwareRole = 'omni_hardware_role';
  static const _kFingerprint = 'omni_hw_fingerprint';
  static const _kTokenExpiresAt = 'omni_token_expires_at';

  final FlutterSecureStorage _storage;

  Future<void> save(OmniSession session) async {
    if (session.instanceId != null) {
      await _storage.write(key: _kInstanceId, value: session.instanceId);
    }
    if (session.businessId != null) {
      await _storage.write(key: _kBusinessId, value: session.businessId);
    }
    if (session.instanceToken != null) {
      await _storage.write(key: _kInstanceToken, value: session.instanceToken);
    }
    if (session.hardwareRole != null) {
      await _storage.write(key: _kHardwareRole, value: session.hardwareRole);
    }
    if (session.hardwareFingerprint != null) {
      await _storage.write(key: _kFingerprint, value: session.hardwareFingerprint);
    }
    if (session.tokenExpiresAt != null) {
      await _storage.write(
        key: _kTokenExpiresAt,
        value: session.tokenExpiresAt!.toUtc().toIso8601String(),
      );
    }
  }

  Future<void> loadInto(OmniSession session) async {
    session.instanceId = await _storage.read(key: _kInstanceId);
    session.businessId = await _storage.read(key: _kBusinessId);
    session.instanceToken = await _storage.read(key: _kInstanceToken);
    session.hardwareRole = await _storage.read(key: _kHardwareRole);
    session.hardwareFingerprint = await _storage.read(key: _kFingerprint);
    final expRaw = await _storage.read(key: _kTokenExpiresAt);
    session.tokenExpiresAt =
        expRaw != null ? DateTime.tryParse(expRaw)?.toUtc() : null;
  }

  Future<void> clear() async {
    await _storage.delete(key: _kInstanceId);
    await _storage.delete(key: _kBusinessId);
    await _storage.delete(key: _kInstanceToken);
    await _storage.delete(key: _kHardwareRole);
    await _storage.delete(key: _kFingerprint);
    await _storage.delete(key: _kTokenExpiresAt);
  }
}
