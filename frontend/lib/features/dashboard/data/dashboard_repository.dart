import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';

class DashboardRepositoryException implements Exception {
  final String message;
  final int? statusCode;

  const DashboardRepositoryException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

class DashboardRepository {
  final Dio dio;

  DashboardRepository({required this.dio});

  Future<Map<String, dynamic>> getToday() async {
    try {
      final Response<dynamic> response = await dio.get<dynamic>(
        '/dashboard/today',
      );
      return _parseDashboardResponse(response.data);
    } on DioException catch (e) {
      throw DashboardRepositoryException(
        _extractDioErrorMessage(e),
        statusCode: e.response?.statusCode,
      );
    }
  }

  Future<Map<String, dynamic>> getWeekly() async {
    try {
      final Response<dynamic> response = await dio.get<dynamic>(
        '/dashboard/weekly',
      );
      return _parseDashboardResponse(response.data);
    } on DioException catch (e) {
      throw DashboardRepositoryException(
        _extractDioErrorMessage(e),
        statusCode: e.response?.statusCode,
      );
    }
  }

  Future<Map<String, dynamic>> getMonthly({int? year, int? month}) async {
    try {
      final Map<String, dynamic> queryParameters = <String, dynamic>{};
      if (year != null) {
        queryParameters['year'] = year;
      }
      if (month != null) {
        queryParameters['month'] = month;
      }

      final Response<dynamic> response = await dio.get<dynamic>(
        '/dashboard/monthly',
        queryParameters: queryParameters.isEmpty ? null : queryParameters,
      );
      return _parseDashboardResponse(response.data);
    } on DioException catch (e) {
      throw DashboardRepositoryException(
        _extractDioErrorMessage(e),
        statusCode: e.response?.statusCode,
      );
    }
  }

  Future<List<Map<String, dynamic>>> getWeightHistory({int months = 3}) async {
    try {
      final Response<dynamic> response = await dio.get<dynamic>(
        '/profile/weight-history',
        queryParameters: <String, dynamic>{'months': months},
      );
      return _parseDashboardListResponse(response.data);
    } on DioException catch (e) {
      throw DashboardRepositoryException(
        _extractDioErrorMessage(e),
        statusCode: e.response?.statusCode,
      );
    }
  }

  Map<String, dynamic> _parseDashboardResponse(dynamic rawResponse) {
    if (rawResponse is! Map<String, dynamic>) {
      throw const DashboardRepositoryException('서버 응답 형식이 올바르지 않습니다.');
    }

    if (rawResponse['status'] != 'success') {
      throw const DashboardRepositoryException('대시보드 요청에 실패했습니다.');
    }

    final dynamic rawData = rawResponse['data'];
    if (rawData is! Map<String, dynamic>) {
      throw const DashboardRepositoryException('대시보드 데이터가 누락되었습니다.');
    }

    return rawData;
  }

  List<Map<String, dynamic>> _parseDashboardListResponse(dynamic rawResponse) {
    if (rawResponse is! Map<String, dynamic>) {
      throw const DashboardRepositoryException('서버 응답 형식이 올바르지 않습니다.');
    }

    if (rawResponse['status'] != 'success') {
      throw const DashboardRepositoryException('대시보드 요청이 실패했습니다.');
    }

    final dynamic rawData = rawResponse['data'];
    if (rawData is! List<dynamic>) {
      throw const DashboardRepositoryException('대시보드 데이터가 비어 있습니다.');
    }

    return rawData.map((dynamic item) {
      if (item is! Map<dynamic, dynamic>) {
        throw const DashboardRepositoryException('대시보드 데이터가 비어 있습니다.');
      }

      return item.map<String, dynamic>(
        (dynamic key, dynamic value) =>
            MapEntry<String, dynamic>(key.toString(), value),
      );
    }).toList();
  }

  String _extractDioErrorMessage(DioException e) {
    final dynamic body = e.response?.data;
    if (body is Map<String, dynamic>) {
      final dynamic detail = body['detail'];
      if (detail is String && detail.isNotEmpty) {
        return detail;
      }
      if (detail is Map<String, dynamic>) {
        final dynamic detailMessage = detail['message'];
        if (detailMessage is String && detailMessage.isNotEmpty) {
          return detailMessage;
        }
      }

      final dynamic error = body['error'];
      if (error is Map<String, dynamic>) {
        final dynamic errorMessage = error['message'];
        if (errorMessage is String && errorMessage.isNotEmpty) {
          return errorMessage;
        }
      }

      final dynamic message = body['message'];
      if (message is String && message.isNotEmpty) {
        return message;
      }
    }

    if (e.message != null && e.message!.isNotEmpty) {
      return e.message!;
    }
    return '요청 처리 중 오류가 발생했습니다.';
  }
}

final dashboardRepositoryProvider = Provider<DashboardRepository>((ref) {
  return DashboardRepository(dio: ref.read(dioProvider));
});
