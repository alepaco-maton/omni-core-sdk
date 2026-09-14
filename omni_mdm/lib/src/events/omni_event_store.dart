import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'omni_event.dart';

class OmniEventStore {
  OmniEventStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                storageNamespace: 'omni_mdm',
                migrateOnAlgorithmChange: false,
              ),
            );

  static const _key = 'omni_mdm_event_queue_v1';
  final FlutterSecureStorage _storage;

  Future<List<Map<String, dynamic>>> peekAll() async {
    final raw = await _storage.read(key: _key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      }
    } catch (_) {}
    return [];
  }

  Future<void> enqueue(OmniEvent event, String deviceId, {int maxQueue = 500}) async {
    final items = await peekAll();
    items.add(event.toJson(deviceId));
    final trimmed = items.length > maxQueue ? items.sublist(items.length - maxQueue) : items;
    await _storage.write(key: _key, value: jsonEncode(trimmed));
  }

  Future<List<Map<String, dynamic>>> take(int max) async {
    final items = await peekAll();
    if (items.isEmpty) return [];
    final batch = items.take(max).toList();
    final rest = items.skip(batch.length).toList();
    await _storage.write(key: _key, value: jsonEncode(rest));
    return batch;
  }

  Future<void> prepend(List<Map<String, dynamic>> items) async {
    if (items.isEmpty) return;
    final current = await peekAll();
    await _storage.write(key: _key, value: jsonEncode([...items, ...current]));
  }
}
