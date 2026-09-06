import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/neo_widgets.dart';
import '../../auth/domain/auth_state_provider.dart';
import '../../dashboard/domain/dashboard_controller.dart';
import '../data/profile_repository.dart';
import '../domain/profile_controller.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String monthKey = _monthKey(DateTime.now());
    final AsyncValue<Map<String, dynamic>> profileAsync = ref.watch(
      profileControllerProvider,
    );
    final AsyncValue<List<Map<String, dynamic>>> weightAsync = ref.watch(
      weightHistoryProvider(monthKey),
    );

    return profileAsync.when(
      loading:
          () => const NeoPage(
            children: [
              NeoStateCard(
                icon: Icons.monitor_heart_outlined,
                title: '신체 데이터를 불러오는 중',
                message: '프로필과 목표 정보를 동기화하고 있습니다.',
              ),
            ],
          ),
      error: (Object error, _) {
        if (_isNotFoundError(error)) {
          return NeoPage(
            children: [
              NeoStateCard(
                icon: Icons.person_outline,
                title: '프로필 설정이 필요합니다',
                message: '체중, 목표, 활동량을 입력하면 개인화된 통계를 볼 수 있습니다.',
                actionLabel: '프로필 설정하기',
                onAction: () => context.push('/profile/edit'),
              ),
            ],
          );
        }
        return NeoPage(
          children: [
            NeoStateCard(
              icon: Icons.error_outline,
              title: '프로필을 불러오지 못했습니다',
              message: _extractErrorMessage(error),
              actionLabel: '다시 시도',
              onAction: () => ref.invalidate(profileControllerProvider),
            ),
          ],
        );
      },
      data:
          (Map<String, dynamic> data) => NeoPage(
            onRefresh: () async {
              ref.invalidate(profileControllerProvider);
              ref.invalidate(weightHistoryProvider(monthKey));
              await Future<void>.delayed(const Duration(milliseconds: 300));
            },
            children: [
              const _StatsHeader(),
              const SizedBox(height: AppSpacing.lg),
              _PersonalizationCard(data: data),
              const SizedBox(height: AppSpacing.md),
              NeoMetricTile(
                label: '현재 체중',
                value: _formatNumber(data['weight_kg']),
                unit: 'kg',
                accent: AppColors.primary,
              ),
              const SizedBox(height: AppSpacing.sm),
              const NeoMetricTile(
                label: '체지방률',
                value: '--',
                unit: '%',
                accent: AppColors.secondary,
              ),
              const SizedBox(height: AppSpacing.sm),
              const NeoMetricTile(
                label: '근육량',
                value: '--',
                unit: 'kg',
                accent: AppColors.tertiary,
              ),
              const SizedBox(height: AppSpacing.md),
              _PerformanceTrendCard(weightAsync: weightAsync),
              const SizedBox(height: AppSpacing.md),
              const _VitalsCard(),
              const SizedBox(height: AppSpacing.md),
              const _CompositionCard(),
              const SizedBox(height: AppSpacing.md),
              const _SyncDevicesCard(),
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: NeoPrimaryButton(
                      label: '프로필 수정',
                      icon: Icons.edit,
                      onPressed: () => context.push('/profile/edit'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: NeoOutlineButton(
                      label: '로그아웃',
                      icon: Icons.logout,
                      onPressed: () async {
                        await ref.read(authStateProvider.notifier).logout();
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
    );
  }

  static bool _isNotFoundError(Object error) {
    return error is ProfileRepositoryException && error.statusCode == 404;
  }

  static String _extractErrorMessage(Object error) {
    if (error is ProfileRepositoryException) {
      return error.message;
    }
    return error.toString();
  }
}

class _StatsHeader extends StatelessWidget {
  const _StatsHeader();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('신체 통계', style: AppTypography.h1),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '프로필과 실제 체중 기록을 기준으로 표시합니다.',
          style: AppTypography.body2.copyWith(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _PersonalizationCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const _PersonalizationCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final String goal = _goalLabel(data['goal']?.toString());
    final String activity = _activityLabel(data['activity_level']?.toString());
    final String targetCalories = _formatWholeNumber(data['target_calories']);
    final String targetProtein = _formatNumber(data['target_protein_g']);

    return NeoGlassCard(
      highlighted: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.psychology_alt_outlined,
                color: AppColors.primary,
                size: 26,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'AI 개인화 기준',
                  style: AppTypography.h2.copyWith(color: AppColors.primary),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '현재 목표는 $goal이며 활동 수준은 $activity입니다. AI 코칭은 이 프로필과 사용자가 남긴 기록을 기준으로 동작합니다.',
            style: AppTypography.body2,
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              NeoInfoChip(label: '목표 · $goal', color: AppColors.secondary),
              NeoInfoChip(label: '활동 · $activity', color: AppColors.primary),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: _TargetMetric(
                  label: '일일 열량 목표',
                  value: targetCalories,
                  unit: 'kcal',
                  color: AppColors.primary,
                ),
              ),
              Container(width: 1, height: 56, color: AppColors.divider),
              Expanded(
                child: _TargetMetric(
                  label: '단백질 목표',
                  value: targetProtein,
                  unit: 'g',
                  color: AppColors.secondary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TargetMetric extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final Color color;

  const _TargetMetric({
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(label, style: AppTypography.caption, textAlign: TextAlign.center),
        const SizedBox(height: AppSpacing.xs),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: value,
                  style: AppTypography.numberSmall.copyWith(color: color),
                ),
                TextSpan(
                  text: ' $unit',
                  style: AppTypography.caption.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _PerformanceTrendCard extends StatelessWidget {
  final AsyncValue<List<Map<String, dynamic>>> weightAsync;

  const _PerformanceTrendCard({required this.weightAsync});

  @override
  Widget build(BuildContext context) {
    final List<double> values = _weightValues(weightAsync.valueOrNull ?? []);
    final double? delta = values.length > 1 ? values.last - values.first : null;

    return NeoGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('체중 추이', style: AppTypography.h2)),
              if (delta != null)
                NeoInfoChip(
                  label:
                      '${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(1)} kg',
                  color: AppColors.primary,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '이번 달에 저장된 체중 기록',
            style: AppTypography.body2.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.lg),
          if (weightAsync.isLoading)
            const _MetricEmptyState(label: '체중 기록을 불러오는 중')
          else if (weightAsync.hasError)
            const _MetricEmptyState(label: '체중 기록을 불러오지 못했습니다')
          else if (values.length < 2)
            _MetricEmptyState(
              label: values.isEmpty ? '기록 없음' : '추이 확인을 위해 체중 기록이 2건 이상 필요합니다.',
            )
          else
            NeoLineChart(values: values, height: 170),
        ],
      ),
    );
  }
}

class _VitalsCard extends StatelessWidget {
  const _VitalsCard();

  @override
  Widget build(BuildContext context) {
    return NeoGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.favorite_border,
                color: AppColors.secondary,
                size: 22,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text('활력 지표', style: AppTypography.h2),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          const _InfoRow(label: '안정 시 심박', value: '--', note: '기록 없음'),
          const _InfoRow(label: '수면 품질', value: '--', note: '기록 없음'),
          const _InfoRow(label: 'VO2 Max', value: '--', note: '기록 없음'),
        ],
      ),
    );
  }
}

class _CompositionCard extends StatelessWidget {
  const _CompositionCard();

  @override
  Widget build(BuildContext context) {
    return NeoGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.accessibility_new,
                color: AppColors.tertiary,
                size: 22,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text('신체 구성', style: AppTypography.h2),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          const _InfoRow(label: '골밀도', value: '--', note: '기록 없음'),
          const _InfoRow(label: '체수분', value: '--', note: '기록 없음'),
          const _InfoRow(label: '내장 지방', value: '--', note: '기록 없음'),
        ],
      ),
    );
  }
}

class _SyncDevicesCard extends StatelessWidget {
  const _SyncDevicesCard();

  @override
  Widget build(BuildContext context) {
    return NeoGlassCard(
      padding: EdgeInsets.zero,
      child: Stack(
        children: [
          const NeoAssetImage(
            path: 'assets/stitch/stats_scale.jpg',
            height: 150,
            width: double.infinity,
            borderRadius: BorderRadius.all(Radius.circular(AppRadius.md)),
          ),
          Container(
            height: 150,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.md),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.16),
                  Colors.black.withValues(alpha: 0.9),
                ],
              ),
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 18,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('연결 기기', style: AppTypography.h2),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '기기 미연결',
                  style: AppTypography.body2.copyWith(
                    color: AppColors.textSecondary,
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

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final String note;

  const _InfoRow({
    required this.label,
    required this.value,
    required this.note,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        children: [
          Expanded(child: Text(label, style: AppTypography.caption)),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(value, style: AppTypography.numberSmall),
              Text(
                note,
                style: AppTypography.caption.copyWith(
                  color: AppColors.textDisabled,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MetricEmptyState extends StatelessWidget {
  final String label;

  const _MetricEmptyState({required this.label});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 150,
      width: double.infinity,
      child: Center(
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: AppTypography.body2.copyWith(color: AppColors.textDisabled),
        ),
      ),
    );
  }
}

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

double? _toNullableDouble(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value);
  }
  return null;
}

String _formatNumber(Object? value) {
  final double? number = _toNullableDouble(value);
  return number == null ? '--' : number.toStringAsFixed(1);
}

String _formatWholeNumber(Object? value) {
  final double? number = _toNullableDouble(value);
  return number == null ? '--' : number.round().toString();
}

String _monthKey(DateTime date) {
  return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}';
}

String _goalLabel(String? goal) {
  return switch (goal) {
    'bulk' => '근육 증가',
    'diet' => '체지방 감량',
    'maintain' => '현재 상태 유지',
    _ => '미설정',
  };
}

String _activityLabel(String? activity) {
  return switch (activity) {
    'sedentary' => '비활동적',
    'light' => '가벼운 활동',
    'moderate' => '보통 활동',
    'active' => '활동적',
    'very_active' => '매우 활동적',
    _ => '미설정',
  };
}
