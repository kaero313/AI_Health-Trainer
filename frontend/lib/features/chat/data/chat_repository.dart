import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_error.dart';

class ChatRepositoryException implements Exception {
  final String message;
  final int? statusCode;
  final String? code;

  const ChatRepositoryException(this.message, {this.statusCode, this.code});

  @override
  String toString() => message;
}

class ChatRepository {
  final Dio dio;

  ChatRepository({required this.dio});

  Future<Map<String, dynamic>> sendMessage(
    String message,
    String contextType,
  ) async {
    try {
      final Response<dynamic> response = await dio.post<dynamic>(
        '/ai/chat',
        data: <String, dynamic>{
          'message': message,
          'context_type': contextType,
        },
        options: Options(receiveTimeout: kAiReceiveTimeout),
      );

      final dynamic rawResponse = response.data;
      if (rawResponse is! Map<String, dynamic>) {
        throw const ChatRepositoryException('서버 응답 형식이 올바르지 않습니다.');
      }
      if (rawResponse['status'] != 'success') {
        throw const ChatRepositoryException('AI 코칭 응답 조회에 실패했습니다.');
      }

      final dynamic rawData = rawResponse['data'];
      if (rawData is! Map<String, dynamic>) {
        throw const ChatRepositoryException('AI 코칭 응답 데이터가 비어 있습니다.');
      }

      return rawData;
    } on DioException catch (e) {
      final ApiErrorDetails error = parseDioApiError(
        e,
        fallbackMessage: 'AI 코칭 요청 중 오류가 발생했습니다.',
      );
      throw ChatRepositoryException(
        error.message,
        statusCode: error.statusCode,
        code: error.code,
      );
    }
  }
}

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  return ChatRepository(dio: ref.read(dioProvider));
});
