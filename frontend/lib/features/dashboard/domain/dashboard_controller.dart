import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/dashboard_repository.dart';

final todayDashboardProvider = FutureProvider.autoDispose<Map<String, dynamic>>(
  (Ref ref) {
    return ref.read(dashboardRepositoryProvider).getToday();
  },
);

final weeklyDashboardProvider =
    FutureProvider.autoDispose<Map<String, dynamic>>((Ref ref) {
      return ref.read(dashboardRepositoryProvider).getWeekly();
    });

final monthlyDashboardProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>((Ref ref, String monthKey) {
      final ({int year, int month}) resolvedMonth = _parseMonthKey(monthKey);
      return ref
          .read(dashboardRepositoryProvider)
          .getMonthly(year: resolvedMonth.year, month: resolvedMonth.month);
    });

final weightHistoryProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((Ref ref, String monthKey) {
      final ({int year, int month}) resolvedMonth = _parseMonthKey(monthKey);
      final int months = _resolveWeightHistoryMonths(
        DateTime.now(),
        resolvedMonth.year,
        resolvedMonth.month,
      );
      return ref
          .read(dashboardRepositoryProvider)
          .getWeightHistory(months: months);
    });

void refreshDashboard(WidgetRef ref) {
  ref.invalidate(todayDashboardProvider);
  ref.invalidate(weeklyDashboardProvider);
}

({int year, int month}) _parseMonthKey(String monthKey) {
  final List<String> segments = monthKey.split('-');
  if (segments.length != 2) {
    throw const DashboardRepositoryException('월간 리포트 키 형식이 올바르지 않습니다.');
  }

  final int? year = int.tryParse(segments[0]);
  final int? month = int.tryParse(segments[1]);
  if (year == null || month == null || month < 1 || month > 12) {
    throw const DashboardRepositoryException('월간 리포트 키 형식이 올바르지 않습니다.');
  }

  return (year: year, month: month);
}

int _resolveWeightHistoryMonths(DateTime currentDate, int year, int month) {
  final int currentMonthIndex = currentDate.year * 12 + currentDate.month;
  final int targetMonthIndex = year * 12 + month;
  if (targetMonthIndex >= currentMonthIndex) {
    return 1;
  }

  return currentMonthIndex - targetMonthIndex + 1;
}
