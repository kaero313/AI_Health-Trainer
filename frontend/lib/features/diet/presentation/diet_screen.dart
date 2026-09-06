import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/neo_widgets.dart';
import '../data/diet_repository.dart';
import '../domain/diet_controller.dart';

class DietScreen extends ConsumerWidget {
  const DietScreen({super.key});

  static const List<String> _mealOrder = <String>[
    'breakfast',
    'lunch',
    'dinner',
    'snack',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DateTime selectedDate = ref.watch(selectedDietDateProvider);
    final AsyncValue<Map<String, dynamic>> dietLogsAsync = ref.watch(
      dietLogsProvider,
    );
    return dietLogsAsync.when(
      loading:
          () => const NeoPage(
            children: [
              NeoStateCard(
                icon: Icons.restaurant,
                title: '식단 데이터를 불러오는 중',
                message: '오늘의 섭취량과 매크로 균형을 계산하고 있습니다.',
              ),
            ],
          ),
      error:
          (Object error, StackTrace _) => NeoPage(
            children: [
              NeoStateCard(
                icon: Icons.error_outline,
                title: '식단 기록을 불러오지 못했습니다',
                message: _extractErrorMessage(error),
                actionLabel: '다시 시도',
                onAction: () => ref.invalidate(dietLogsProvider),
              ),
            ],
          ),
      data:
          (Map<String, dynamic> data) => NeoPage(
            onRefresh: () async {
              ref.invalidate(dietLogsProvider);
              await Future<void>.delayed(const Duration(milliseconds: 300));
            },
            children: [
              _DietHeader(
                selectedDate: selectedDate,
                onDateTap: () => _pickDate(context, ref, selectedDate),
              ),
              const SizedBox(height: AppSpacing.lg),
              _TargetDistributionCard(data: data),
              const SizedBox(height: AppSpacing.md),
              _AiNutritionCoach(onTap: () => context.push('/diet/recommend')),
              const SizedBox(height: AppSpacing.lg),
              NeoSectionHeader(
                title: '식사 타임라인',
                actionLabel: '사진 분석',
                onAction: () => context.push('/diet/analyze'),
              ),
              _MealTimeline(
                data: data,
                onDelete: (int logId) => _deleteLog(context, ref, logId),
              ),
              const SizedBox(height: AppSpacing.md),
              const _ProfilePreferenceCards(),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: NeoPrimaryButton(
                      label: '식단 추가',
                      icon: Icons.add,
                      onPressed: () => context.push('/diet/add'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: NeoOutlineButton(
                      label: 'AI 추천',
                      icon: Icons.auto_awesome,
                      onPressed: () => context.push('/diet/recommend'),
                    ),
                  ),
                ],
              ),
            ],
          ),
    );
  }

  Future<void> _pickDate(
    BuildContext context,
    WidgetRef ref,
    DateTime currentDate,
  ) async {
    final DateTime now = DateTime.now();
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: currentDate,
      firstDate: DateTime(now.year - 2),
      lastDate: DateTime(now.year + 2),
      locale: const Locale('ko'),
    );
    if (pickedDate == null) {
      return;
    }
    ref.read(selectedDietDateProvider.notifier).state = pickedDate;
  }

  Future<bool> _deleteLog(
    BuildContext context,
    WidgetRef ref,
    int logId,
  ) async {
    try {
      await deleteDietLogAndRefresh(ref, logId);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('식단 기록을 삭제했습니다.')));
      }
      return true;
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(_extractErrorMessage(error))));
      }
      return false;
    }
  }
}

class _DietHeader extends StatelessWidget {
  final DateTime selectedDate;
  final VoidCallback onDateTap;

  const _DietHeader({required this.selectedDate, required this.onDateTap});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('식단 플래너', style: AppTypography.h1),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '목표 대비 오늘의 영양 균형을 확인합니다.',
          style: AppTypography.body2.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: AppSpacing.md),
        InkWell(
          borderRadius: BorderRadius.circular(AppRadius.full),
          onTap: onDateTap,
          child: NeoInfoChip(
            label: DateFormat('yyyy년 M월 d일').format(selectedDate),
            color: AppColors.primary,
          ),
        ),
      ],
    );
  }
}

class _TargetDistributionCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const _TargetDistributionCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> dailyTotal = _map(data['daily_total']);
    final Map<String, dynamic> targetRemaining = _map(data['target_remaining']);
    final int calories = _toRoundedInt(dailyTotal['calories']);
    final int targetCalories = _targetValue(
      dailyTotal['calories'],
      targetRemaining['calories'],
    );
    final int protein = _toRoundedInt(dailyTotal['protein_g']);
    final int targetProtein = _targetValue(
      dailyTotal['protein_g'],
      targetRemaining['protein_g'],
    );
    final int carbs = _toRoundedInt(dailyTotal['carbs_g']);
    final int targetCarbs = _targetValue(
      dailyTotal['carbs_g'],
      targetRemaining['carbs_g'],
    );
    final int fat = _toRoundedInt(dailyTotal['fat_g']);
    final int targetFat = _targetValue(
      dailyTotal['fat_g'],
      targetRemaining['fat_g'],
    );

    return NeoGlassCard(
      highlighted: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('목표 영양 분배', style: AppTypography.h2)),
              NeoInfoChip(
                label: '${_percent(calories, targetCalories)}% 충족',
                color: AppColors.primary,
                filled: true,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double itemWidth =
                  (constraints.maxWidth - AppSpacing.sm) / 2;
              return Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  SizedBox(
                    width: itemWidth,
                    child: _MacroProgress(
                      label: '칼로리',
                      value: calories,
                      target: targetCalories,
                      unit: 'kcal',
                      color: AppColors.primary,
                    ),
                  ),
                  SizedBox(
                    width: itemWidth,
                    child: _MacroProgress(
                      label: '단백질',
                      value: protein,
                      target: targetProtein,
                      unit: 'g',
                      color: AppColors.primary,
                    ),
                  ),
                  SizedBox(
                    width: itemWidth,
                    child: _MacroProgress(
                      label: '탄수화물',
                      value: carbs,
                      target: targetCarbs,
                      unit: 'g',
                      color: AppColors.secondary,
                    ),
                  ),
                  SizedBox(
                    width: itemWidth,
                    child: _MacroProgress(
                      label: '지방',
                      value: fat,
                      target: targetFat,
                      unit: 'g',
                      color: AppColors.tertiary,
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _MacroProgress extends StatelessWidget {
  final String label;
  final int value;
  final int target;
  final String unit;
  final Color color;

  const _MacroProgress({
    required this.label,
    required this.value,
    required this.target,
    required this.unit,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final double progress =
        target <= 0 ? 0 : (value / target).clamp(0, 1).toDouble();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTypography.caption),
          const SizedBox(height: 2),
          Text(
            '$value / ${target == 0 ? '--' : target} $unit',
            maxLines: 2,
            softWrap: true,
            style: AppTypography.caption.copyWith(color: AppColors.textPrimary),
          ),
          const SizedBox(height: AppSpacing.xs),
          NeoProgressBar(value: progress, color: color, height: 5),
        ],
      ),
    );
  }
}

class _AiNutritionCoach extends StatelessWidget {
  final VoidCallback onTap;

  const _AiNutritionCoach({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return NeoGlassCard(
      highlighted: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'AI 코치',
            style: AppTypography.h2.copyWith(color: AppColors.primary),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '오늘 식단의 단백질, 탄수화물, 지방 균형을 분석해 다음 식사를 조정합니다.',
            style: AppTypography.body2.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.md),
          NeoPrimaryButton(
            label: '식단 추천 받기',
            icon: Icons.auto_awesome,
            onPressed: onTap,
          ),
        ],
      ),
    );
  }
}

class _MealTimeline extends StatelessWidget {
  final Map<String, dynamic> data;
  final Future<bool> Function(int logId) onDelete;

  const _MealTimeline({required this.data, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final List<Widget> cards = <Widget>[];
    for (final String mealType in DietScreen._mealOrder) {
      final List<Map<String, dynamic>> logs = _readMealLogs(data, mealType);
      if (logs.isEmpty) {
        cards.add(_EmptyMealCard(mealType: mealType));
      } else {
        for (final Map<String, dynamic> log in logs) {
          cards.add(
            _DietLogCard(log: log, mealType: mealType, onDelete: onDelete),
          );
        }
      }
    }
    return Column(
      children: [
        for (int i = 0; i < cards.length; i++) ...[
          if (i > 0)
            Container(
              width: 2,
              height: 28,
              color: i.isEven ? AppColors.primary : AppColors.divider,
            ),
          cards[i],
        ],
      ],
    );
  }
}

class _DietLogCard extends StatelessWidget {
  final Map<String, dynamic> log;
  final String mealType;
  final Future<bool> Function(int logId) onDelete;

  const _DietLogCard({
    required this.log,
    required this.mealType,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final int logId = _toInt(log['id']);
    final List<Map<String, dynamic>> items = _readLogItems(log);
    final String title =
        items.isEmpty
            ? _mealLabel(mealType)
            : items
                .map(
                  (Map<String, dynamic> item) =>
                      item['food_name']?.toString() ?? '음식',
                )
                .join(', ');
    final double calories = items.fold<double>(
      0,
      (double total, Map<String, dynamic> item) =>
          total + _toDouble(item['calories']),
    );
    final double protein = items.fold<double>(
      0,
      (double total, Map<String, dynamic> item) =>
          total + _toDouble(item['protein_g']),
    );
    final double carbs = items.fold<double>(
      0,
      (double total, Map<String, dynamic> item) =>
          total + _toDouble(item['carbs_g']),
    );
    final double fat = items.fold<double>(
      0,
      (double total, Map<String, dynamic> item) =>
          total + _toDouble(item['fat_g']),
    );

    return NeoGlassCard(
      highlighted: mealType == 'lunch',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: _mealColor(mealType).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(
                    color: _mealColor(mealType).withValues(alpha: 0.38),
                  ),
                ),
                child: Icon(
                  _mealIcon(mealType),
                  color: _mealColor(mealType),
                  size: 21,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppTypography.h3),
                    const SizedBox(height: 2),
                    Text(
                      _mealLabel(mealType),
                      style: AppTypography.body2.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => onDelete(logId),
                icon: const Icon(
                  Icons.more_vert,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              NeoInfoChip(
                label: '${calories.round()} kcal',
                color: AppColors.primary,
              ),
              NeoInfoChip(
                label: 'P ${protein.round()}g',
                color: AppColors.textSecondary,
              ),
              NeoInfoChip(
                label: 'C ${carbs.round()}g',
                color: AppColors.secondary,
              ),
              NeoInfoChip(
                label: 'F ${fat.round()}g',
                color: AppColors.tertiary,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyMealCard extends StatelessWidget {
  final String mealType;

  const _EmptyMealCard({required this.mealType});

  @override
  Widget build(BuildContext context) {
    return NeoGlassCard(
      onTap: () => context.push('/diet/add?meal_type=$mealType'),
      child: Row(
        children: [
          const Icon(Icons.add_circle_outline, color: AppColors.primary),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              '${_mealLabel(mealType)} 기록 추가',
              style: AppTypography.body1,
            ),
          ),
          Text('기록 없음', style: AppTypography.caption),
        ],
      ),
    );
  }
}

class _ProfilePreferenceCards extends StatelessWidget {
  const _ProfilePreferenceCards();

  @override
  Widget build(BuildContext context) {
    return NeoGlassCard(
      onTap: () => context.push('/profile/edit'),
      child: Row(
        children: [
          const Icon(Icons.tune, color: AppColors.primary),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('식단 기준 관리', style: AppTypography.h3),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '알레르기와 선호 식단은 프로필에서 확인하고 수정할 수 있습니다.',
                  style: AppTypography.body2.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: AppColors.textSecondary),
        ],
      ),
    );
  }
}

List<Map<String, dynamic>> _readMealLogs(
  Map<String, dynamic> data,
  String mealType,
) {
  final Map<String, dynamic> meals = _map(data['meals']);
  final List<dynamic> logs = meals[mealType] as List<dynamic>? ?? <dynamic>[];
  return logs.whereType<Map<String, dynamic>>().toList();
}

List<Map<String, dynamic>> _readLogItems(Map<String, dynamic> log) {
  final List<dynamic> items = log['items'] as List<dynamic>? ?? <dynamic>[];
  return items.whereType<Map<String, dynamic>>().toList();
}

Map<String, dynamic> _map(Object? value) {
  return value is Map<String, dynamic> ? value : <String, dynamic>{};
}

int _percent(int value, int target) {
  if (target <= 0) {
    return 0;
  }
  return ((value / target) * 100).clamp(0, 999).round();
}

int _toInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? 0;
  }
  return 0;
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

int _toRoundedInt(Object? value) => _toDouble(value).round();

int _targetValue(Object? consumed, Object? remaining) {
  if (remaining == null) {
    return 0;
  }
  return (_toDouble(consumed) + _toDouble(remaining)).round();
}

String _mealLabel(String mealType) {
  return switch (mealType) {
    'breakfast' => '아침',
    'lunch' => '점심',
    'dinner' => '저녁',
    'snack' => '간식',
    _ => mealType,
  };
}

Color _mealColor(String mealType) {
  return switch (mealType) {
    'breakfast' => AppColors.primary,
    'lunch' => AppColors.secondary,
    'dinner' => AppColors.tertiary,
    _ => AppColors.textSecondary,
  };
}

IconData _mealIcon(String mealType) {
  return switch (mealType) {
    'breakfast' => Icons.wb_sunny_outlined,
    'lunch' => Icons.lunch_dining_outlined,
    'dinner' => Icons.nightlight_outlined,
    _ => Icons.local_cafe_outlined,
  };
}

String _extractErrorMessage(Object error) {
  if (error is DietRepositoryException) {
    return error.message;
  }
  return error.toString();
}
