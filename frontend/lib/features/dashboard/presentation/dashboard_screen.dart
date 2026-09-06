import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/neo_widgets.dart';
import '../../profile/data/profile_repository.dart';
import '../../profile/domain/profile_controller.dart';
import '../data/dashboard_repository.dart';
import '../domain/dashboard_controller.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String monthKey = _monthKey(DateTime.now());
    final AsyncValue<Map<String, dynamic>> profileAsync = ref.watch(
      profileControllerProvider,
    );
    final AsyncValue<Map<String, dynamic>> todayAsync = ref.watch(
      todayDashboardProvider,
    );
    final AsyncValue<Map<String, dynamic>> weeklyAsync = ref.watch(
      weeklyDashboardProvider,
    );
    final AsyncValue<List<Map<String, dynamic>>> weightAsync = ref.watch(
      weightHistoryProvider(monthKey),
    );

    final Object? profileError = profileAsync.asError?.error;
    final Object? todayError = todayAsync.asError?.error;
    final Object? weeklyError = weeklyAsync.asError?.error;
    final bool needsProfileSetup =
        _isProfileNotFound(profileError) ||
        _isDashboardNotFound(todayError) ||
        _isDashboardNotFound(weeklyError);
    final bool isLoading =
        profileAsync.isLoading || todayAsync.isLoading || weeklyAsync.isLoading;
    final Object? firstError = profileError ?? todayError ?? weeklyError;

    if (needsProfileSetup) {
      return NeoPage(
        children: [
          NeoStateCard(
            icon: Icons.person_add_alt_1,
            title: '프로필 설정이 필요합니다',
            message: 'AI 코칭과 개인 목표 계산을 위해 기본 신체 정보를 먼저 입력해 주세요.',
            actionLabel: '프로필 설정하기',
            onAction: () => context.push('/profile/edit'),
          ),
        ],
      );
    }

    if (isLoading) {
      return const _DashboardLoadingView();
    }

    if (firstError != null) {
      return NeoPage(
        children: [
          NeoStateCard(
            icon: Icons.error_outline,
            title: '대시보드를 불러오지 못했습니다',
            message: _extractErrorMessage(firstError),
            actionLabel: '다시 시도',
            onAction: () => refreshDashboard(ref),
          ),
        ],
      );
    }

    final Map<String, dynamic> profile = profileAsync.valueOrNull ?? {};
    final Map<String, dynamic> today = todayAsync.valueOrNull ?? {};
    final Map<String, dynamic> weekly = weeklyAsync.valueOrNull ?? {};

    return NeoPage(
      onRefresh: () async {
        refreshDashboard(ref);
        ref.invalidate(profileControllerProvider);
        ref.invalidate(weightHistoryProvider(monthKey));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      },
      children: [
        const _Greeting(),
        const SizedBox(height: AppSpacing.lg),
        _DailyProgressCard(today: today),
        const SizedBox(height: AppSpacing.md),
        _WeightCard(profile: profile, weightAsync: weightAsync),
        const SizedBox(height: AppSpacing.md),
        _NutritionCard(today: today, onTap: () => context.go('/diet')),
        const SizedBox(height: AppSpacing.md),
        _WorkoutCard(today: today, onTap: () => context.go('/exercise')),
        const SizedBox(height: AppSpacing.md),
        _WeeklyConsistencyCard(weekly: weekly),
        const SizedBox(height: AppSpacing.md),
        _AiCoachCard(onTap: () => context.push('/ai/chat')),
        const SizedBox(height: AppSpacing.md),
        NeoOutlineButton(
          label: '월간 리포트 보기',
          icon: Icons.analytics_outlined,
          onPressed: () => context.push('/dashboard/monthly'),
        ),
      ],
    );
  }

  static bool _isProfileNotFound(Object? error) {
    return error is ProfileRepositoryException && error.statusCode == 404;
  }

  static bool _isDashboardNotFound(Object? error) {
    return error is DashboardRepositoryException && error.statusCode == 404;
  }

  static String _extractErrorMessage(Object error) {
    if (error is DashboardRepositoryException) {
      return error.message;
    }
    if (error is ProfileRepositoryException) {
      return error.message;
    }
    return error.toString();
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('좋은 하루예요', style: AppTypography.h1),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '오늘의 식단과 운동 기록을 한눈에 확인하세요.',
          style: AppTypography.body2.copyWith(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _DailyProgressCard extends StatelessWidget {
  final Map<String, dynamic> today;

  const _DailyProgressCard({required this.today});

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> nutrition = _map(today['nutrition']);
    final Map<String, dynamic> exercise = _map(today['exercise']);
    final Map<String, dynamic> streak = _map(today['streak']);
    final Map<String, dynamic> progress = _map(nutrition['progress_percent']);
    final bool hasTarget = nutrition['target'] is Map;
    final double calorieProgress = _toDouble(progress['calories']);
    final int calories = _toRoundedInt(_map(nutrition['consumed'])['calories']);
    final int sets = _toRoundedInt(exercise['total_sets']);
    final int exercises = _toRoundedInt(exercise['exercises_count']);
    final int exerciseStreak = _toRoundedInt(streak['exercise_days']);
    final int dietStreak = _toRoundedInt(streak['diet_logging_days']);

    return NeoGlassCard(
      highlighted: true,
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Text('오늘의 진행', style: AppTypography.h2),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: _ProgressStat(
                  icon: Icons.bolt,
                  label: '섭취 열량',
                  value: calories > 0 ? '$calories kcal' : '기록 없음',
                  color: AppColors.primary,
                ),
              ),
              Container(width: 1, height: 54, color: AppColors.divider),
              Expanded(
                child: _ProgressStat(
                  icon: Icons.fitness_center,
                  label: '운동 기록',
                  value: exercises > 0 ? '$exercises개 · $sets세트' : '기록 없음',
                  color: AppColors.secondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          NeoRing(
            value: hasTarget ? calorieProgress / 100 : 0,
            centerText: hasTarget ? '${calorieProgress.round()}%' : '--',
            label: hasTarget ? '열량 목표' : '목표 정보 없음',
            color: AppColors.primary,
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              NeoInfoChip(
                label: '운동 연속 $exerciseStreak일',
                color: AppColors.primary,
              ),
              NeoInfoChip(
                label: '식단 연속 $dietStreak일',
                color: AppColors.secondary,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProgressStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _ProgressStat({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(height: AppSpacing.xs),
        Text(label, style: AppTypography.caption, textAlign: TextAlign.center),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: AppTypography.label.copyWith(color: color),
        ),
      ],
    );
  }
}

class _WeightCard extends StatelessWidget {
  final Map<String, dynamic> profile;
  final AsyncValue<List<Map<String, dynamic>>> weightAsync;

  const _WeightCard({required this.profile, required this.weightAsync});

  @override
  Widget build(BuildContext context) {
    final double? weight = _toNullableDouble(profile['weight_kg']);
    final List<double> history = _weightValues(weightAsync.valueOrNull ?? []);
    final double? delta =
        history.length > 1 ? history.last - history.first : null;

    return NeoGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('체중', style: AppTypography.h2)),
              if (delta != null)
                NeoInfoChip(
                  label:
                      '${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(1)} kg',
                  color: AppColors.primary,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: weight == null ? '--' : weight.toStringAsFixed(1),
                  style: AppTypography.display,
                ),
                TextSpan(
                  text: ' kg',
                  style: AppTypography.body1.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (weightAsync.isLoading)
            const _InlineState(label: '체중 기록을 불러오는 중')
          else if (weightAsync.hasError)
            const _InlineState(label: '체중 추이를 불러오지 못했습니다')
          else if (history.length < 2)
            _InlineState(label: history.isEmpty ? '체중 기록 없음' : '체중 기록 1건')
          else
            NeoLineChart(values: history, height: 94),
        ],
      ),
    );
  }
}

class _NutritionCard extends StatelessWidget {
  final Map<String, dynamic> today;
  final VoidCallback onTap;

  const _NutritionCard({required this.today, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> nutrition = _map(today['nutrition']);
    final Map<String, dynamic> consumed = _map(nutrition['consumed']);
    final Map<String, dynamic> target = _map(nutrition['target']);
    final int calories = _toRoundedInt(consumed['calories']);
    final int targetCalories = _toRoundedInt(target['calories']);
    final double progress =
        targetCalories <= 0
            ? 0
            : (calories / targetCalories).clamp(0, 1).toDouble();

    return NeoGlassCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('영양', style: AppTypography.h2)),
              const Icon(Icons.restaurant, color: AppColors.textSecondary),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          RichText(
            text: TextSpan(
              children: [
                TextSpan(text: '$calories', style: AppTypography.numberSmall),
                TextSpan(
                  text:
                      ' / ${targetCalories == 0 ? '--' : targetCalories} kcal',
                  style: AppTypography.body2.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          NeoProgressBar(value: progress),
          const SizedBox(height: AppSpacing.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _Macro(
                label: '단백질',
                value: '${_toRoundedInt(consumed['protein_g'])}g',
                color: AppColors.primary,
              ),
              _Macro(
                label: '탄수화물',
                value: '${_toRoundedInt(consumed['carbs_g'])}g',
                color: AppColors.textPrimary,
              ),
              _Macro(
                label: '지방',
                value: '${_toRoundedInt(consumed['fat_g'])}g',
                color: AppColors.tertiary,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Macro extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _Macro({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: AppTypography.caption),
        const SizedBox(height: AppSpacing.xs),
        Text(value, style: AppTypography.label.copyWith(color: color)),
      ],
    );
  }
}

class _WorkoutCard extends StatelessWidget {
  final Map<String, dynamic> today;
  final VoidCallback onTap;

  const _WorkoutCard({required this.today, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> exercise = _map(today['exercise']);
    final int exerciseCount = _toRoundedInt(exercise['exercises_count']);
    final int totalSets = _toRoundedInt(exercise['total_sets']);
    final List<String> muscleGroups =
        _stringList(
          exercise['muscle_groups_trained'],
        ).map(_muscleGroupLabel).toList();
    final bool hasExercise = exerciseCount > 0;

    return NeoGlassCard(
      onTap: onTap,
      padding: EdgeInsets.zero,
      child: Stack(
        children: [
          const NeoAssetImage(
            path: 'assets/stitch/dashboard_gym.jpg',
            height: 178,
            width: double.infinity,
            borderRadius: BorderRadius.all(Radius.circular(AppRadius.md)),
          ),
          Container(
            height: 178,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.md),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.14),
                  Colors.black.withValues(alpha: 0.9),
                ],
              ),
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 18,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        hasExercise ? '오늘 운동 기록' : '오늘 기록 없음',
                        style: AppTypography.caption.copyWith(
                          color: AppColors.primary,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        hasExercise
                            ? (muscleGroups.isEmpty
                                ? '운동 완료'
                                : muscleGroups.join(' · '))
                            : '운동을 기록해 보세요',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.h2,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        hasExercise
                            ? '$exerciseCount개 운동 · $totalSets세트'
                            : '직접 기록하거나 추천 루틴을 확인하세요.',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.body2.copyWith(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                SizedBox(
                  width: 96,
                  child: NeoPrimaryButton(
                    label: hasExercise ? '보기' : '기록',
                    onPressed: onTap,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WeeklyConsistencyCard extends StatelessWidget {
  final Map<String, dynamic> weekly;

  const _WeeklyConsistencyCard({required this.weekly});

  @override
  Widget build(BuildContext context) {
    final List<Map<String, dynamic>> days = _mapList(weekly['daily_breakdown']);
    final Map<String, dynamic> exerciseSummary = _map(
      weekly['exercise_summary'],
    );
    final int exerciseDays = _toRoundedInt(exerciseSummary['total_days']);
    final int dietDays =
        days.where((day) => _toDouble(day['calories']) > 0).length;

    return NeoGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('주간 일관성', style: AppTypography.h2),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              NeoInfoChip(label: '운동 $exerciseDays일', color: AppColors.primary),
              NeoInfoChip(label: '식단 $dietDays일', color: AppColors.secondary),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          if (days.isEmpty)
            const _InlineState(label: '이번 주 기록 없음')
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List<Widget>.generate(days.length, (int index) {
                final Map<String, dynamic> day = days[index];
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: _ConsistencyBar(
                      exercised: day['exercised'] == true,
                      dietLogged: _toDouble(day['calories']) > 0,
                      label: _weekdayLabel(day['date'], index),
                    ),
                  ),
                );
              }),
            ),
        ],
      ),
    );
  }
}

class _ConsistencyBar extends StatelessWidget {
  final bool exercised;
  final bool dietLogged;
  final String label;

  const _ConsistencyBar({
    required this.exercised,
    required this.dietLogged,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 72,
          alignment: Alignment.bottomCenter,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            height: exercised ? 72 : 10,
            decoration: BoxDecoration(
              color:
                  exercised
                      ? AppColors.primary
                      : Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Container(
          height: 34,
          alignment: Alignment.bottomCenter,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            height: dietLogged ? 34 : 8,
            decoration: BoxDecoration(
              color:
                  dietLogged
                      ? AppColors.secondary
                      : Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          label,
          style: AppTypography.caption.copyWith(
            color:
                exercised || dietLogged
                    ? AppColors.textPrimary
                    : AppColors.textDisabled,
          ),
        ),
      ],
    );
  }
}

class _AiCoachCard extends StatelessWidget {
  final VoidCallback onTap;

  const _AiCoachCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return NeoGlassCard(
      highlighted: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.psychology_alt_outlined,
            color: AppColors.primary,
            size: 30,
          ),
          const SizedBox(height: AppSpacing.md),
          Text('AI 코치', style: AppTypography.h2),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '현재 목표와 기록을 컨텍스트로 사용해 출처가 확인된 답변을 요청할 수 있습니다.',
            style: AppTypography.body2.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.md),
          NeoPrimaryButton(
            label: 'AI 코치에게 질문',
            icon: Icons.auto_awesome,
            onPressed: onTap,
          ),
        ],
      ),
    );
  }
}

class _InlineState extends StatelessWidget {
  final String label;

  const _InlineState({required this.label});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 94,
      width: double.infinity,
      child: Center(
        child: Text(
          label,
          style: AppTypography.body2.copyWith(color: AppColors.textDisabled),
        ),
      ),
    );
  }
}

class _DashboardLoadingView extends StatelessWidget {
  const _DashboardLoadingView();

  @override
  Widget build(BuildContext context) {
    return const NeoPage(
      children: [
        NeoStateCard(
          icon: Icons.hourglass_top,
          title: '데이터를 동기화하는 중',
          message: '오늘의 식단, 운동, 프로필 데이터를 불러오고 있습니다.',
        ),
      ],
    );
  }
}

Map<String, dynamic> _map(Object? value) {
  return value is Map<String, dynamic> ? value : <String, dynamic>{};
}

List<Map<String, dynamic>> _mapList(Object? value) {
  if (value is! List) {
    return <Map<String, dynamic>>[];
  }
  return value
      .whereType<Map>()
      .map(
        (item) => item.map<String, dynamic>(
          (key, value) => MapEntry<String, dynamic>(key.toString(), value),
        ),
      )
      .toList();
}

List<String> _stringList(Object? value) {
  if (value is! List) {
    return <String>[];
  }
  return value.map((item) => item.toString()).toList();
}

double _toDouble(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value) ?? 0;
  }
  return 0;
}

double? _toNullableDouble(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value);
  }
  return null;
}

int _toRoundedInt(Object? value) => _toDouble(value).round();

List<double> _weightValues(List<Map<String, dynamic>> history) {
  final List<({DateTime date, double value})> entries = [];
  for (final Map<String, dynamic> item in history) {
    final DateTime? date = DateTime.tryParse(
      item['log_date']?.toString() ?? '',
    );
    final double? value = _toNullableDouble(item['weight_kg']);
    if (date != null && value != null) {
      entries.add((date: date, value: value));
    }
  }
  entries.sort((a, b) => a.date.compareTo(b.date));
  return entries.map((entry) => entry.value).toList();
}

String _monthKey(DateTime date) {
  return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}';
}

String _weekdayLabel(Object? rawDate, int fallbackIndex) {
  const List<String> labels = ['월', '화', '수', '목', '금', '토', '일'];
  final DateTime? date = DateTime.tryParse(rawDate?.toString() ?? '');
  if (date != null) {
    return labels[date.weekday - 1];
  }
  return labels[fallbackIndex.clamp(0, 6)];
}

String _muscleGroupLabel(String value) {
  return switch (value) {
    'chest' => '가슴',
    'back' => '등',
    'legs' => '하체',
    'shoulders' => '어깨',
    'arms' => '팔',
    'core' => '코어',
    'cardio' => '유산소',
    'full_body' => '전신',
    _ => value,
  };
}
