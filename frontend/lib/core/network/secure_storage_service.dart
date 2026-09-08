import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'constants.dart';

class SecureStorageService {
  final FlutterSecureStorage _storage;

  SecureStorageService({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  Future<String?> getAccessToken() {
    return _storage.read(key: kAccessTokenKey);
  }

  Future<String?> getRefreshToken() {
    return _storage.read(key: kRefreshTokenKey);
  }

  Future<void> saveAccessToken(String token) {
    return _storage.write(key: kAccessTokenKey, value: token);
  }

  Future<void> saveTokens({
    required String access,
    required String refresh,
  }) async {
    await _storage.write(key: kAccessTokenKey, value: access);
    await _storage.write(key: kRefreshTokenKey, value: refresh);
  }

  Future<void> clearTokens() async {
    await _storage.delete(key: kAccessTokenKey);
    await _storage.delete(key: kRefreshTokenKey);
  }
}

final secureStorageServiceProvider = Provider<SecureStorageService>(
  (ref) => SecureStorageService(),
);
