import 'dart:convert';
import 'dart:io';

bool isPublishableSupabaseKey(String key) {
  if (RegExp(r'^sb_publishable_[A-Za-z0-9_-]+$').hasMatch(key)) return true;
  final parts = key.split('.');
  if (parts.length != 3 || !key.startsWith('eyJ')) return false;
  try {
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    return payload is Map && payload['role'] == 'anon';
  } on FormatException {
    return false;
  }
}

void main() {
  final env = Platform.environment;
  final url = env['SUPABASE_URL'] ?? '';
  final key = env['SUPABASE_KEY'] ?? '';
  if (!RegExp(r'^https://[a-z0-9]+\.supabase\.co$').hasMatch(url)) {
    stderr.writeln('Set SUPABASE_URL to the project HTTPS origin.');
    exitCode = 1;
  } else if (!isPublishableSupabaseKey(key)) {
    stderr.writeln(
      'SUPABASE_KEY must be a publishable key or a legacy anon key.',
    );
    exitCode = 1;
  }
}
