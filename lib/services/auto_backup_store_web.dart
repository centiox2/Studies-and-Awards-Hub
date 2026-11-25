import 'package:shared_preferences/shared_preferences.dart';

import 'auto_backup_types.dart';

/// Existing copies remain recoverable. New browser backups are downloads.
AutoBackupStore createAutoBackupStore({
  required String databaseFile,
  String? folder,
}) => const _BrowserStore();

Future<String?> pickBackupFolder() async => null;

class _BrowserStore extends AutoBackupStore {
  const _BrowserStore();

  static const _prefix = 'auto_backup:';

  @override
  String get location => 'this browser';

  @override
  int get keep => 0;

  @override
  bool get enabled => false;

  @override
  Future<List<AutoBackupEntry>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final out = <AutoBackupEntry>[];
    for (final key in prefs.getKeys().where((k) => k.startsWith(_prefix))) {
      final at = DateTime.tryParse(key.substring(_prefix.length));
      final value = prefs.getString(key);
      if (at == null || value == null) continue;
      out.add(AutoBackupEntry(id: key, savedAt: at, bytes: value.length));
    }
    out.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return out;
  }

  @override
  Future<void> save(String name, String json) async {}

  @override
  Future<String?> read(String id) async {
    if (!id.startsWith(_prefix)) return null;
    return (await SharedPreferences.getInstance()).getString(id);
  }
}
