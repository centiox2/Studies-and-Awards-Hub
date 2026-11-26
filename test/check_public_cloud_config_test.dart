import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../tool/check_public_cloud_config.dart';

void main() {
  String legacyKey(String role) {
    final header = base64Url.encode(utf8.encode('{"alg":"HS256"}'));
    final payload = base64Url.encode(utf8.encode(jsonEncode({'role': role})));
    return '$header.$payload.example-signature';
  }

  test('builds accept only Supabase client keys', () {
    expect(
      isPublishableSupabaseKey(
        'sb_publishable_'
        'example',
      ),
      isTrue,
    );
    expect(isPublishableSupabaseKey(legacyKey('anon')), isTrue);
    expect(isPublishableSupabaseKey(legacyKey('service_role')), isFalse);
    expect(isPublishableSupabaseKey(legacyKey('authenticated')), isFalse);
    expect(
      isPublishableSupabaseKey(
        'sb_secret_'
        'example',
      ),
      isFalse,
    );
    expect(isPublishableSupabaseKey('eyJ.not-a-jwt.example'), isFalse);
  });
}
