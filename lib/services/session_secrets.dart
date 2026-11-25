import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Native credentials are loaded before Riverpod restores the session.
/// Browser credentials remain in this instance for the lifetime of the tab.
class SessionSecrets {
  SessionSecrets([this._storage]);

  final FlutterSecureStorage? _storage;
  final _values = <String, String>{};
  Future<void> _writes = Future.value();

  static Future<SessionSecrets> load() async {
    final storage = kIsWeb ? null : const FlutterSecureStorage();
    final secrets = SessionSecrets(storage);
    if (storage != null) {
      try {
        final saved = await storage.readAll();
        for (final entry in saved.entries) {
          if (entry.key.startsWith('sa_hub_session:')) {
            secrets._values[entry.key] = entry.value;
          }
        }
      } catch (_) {
        // A credential-vault failure requires a fresh sign-in.
      }
    }
    return secrets;
  }

  String? get(String key) => _values['sa_hub_session:$key'];

  void set(String key, String? value) {
    final storageKey = 'sa_hub_session:$key';
    if (value == null) {
      _values.remove(storageKey);
    } else {
      _values[storageKey] = value;
    }
    final storage = _storage;
    if (storage == null) return;
    _writes = _writes
        .then((_) async {
          if (value == null) {
            await storage.delete(key: storageKey);
          } else {
            await storage.write(key: storageKey, value: value);
          }
        })
        .catchError((Object _) {
          // Never fall back to a plaintext store when the vault is unavailable.
        });
  }

  static const legacyProfileKeys = [
    'cloud_admin_token',
    'cloud_team_token',
    'cloud_director_token',
    'cloud_viewer_token',
  ];
}
