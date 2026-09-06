import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/neo_widgets.dart';
import '../data/exercise_repository.dart';
import '../domain/exercise_controller.dart';

const Map<String, String> kMuscleGroupLabels = <String, String>{
  'chest': '가슴',
  'back': '등',
  'shoulder': '어깨',
  'legs': '하체',
  'arms': '팔',
  'core': '코어',
  'cardio': '유산소',
  'full_body': '전신',
};

const List<String> kMuscleGroupOrder = <String>[
  'chest',
  'back',
  'shoulder',
  'legs',
  'arms',
  'core',
  'cardio',
  'full_body',
];

class ExerciseScreen extends ConsumerWidget {
  const ExerciseScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DateTime selectedDate = ref.watch(exerciseDateProvider);
    final String? selectedMuscleGroup = ref.watch(selectedMuscleGroupProvider);
    final AsyncValue<Map<String, dynamic>> exerciseLogsAsync = ref.watch(
      exerciseLogsProvider,
    );

    return exerciseLogsAsync.when(
      loading:
          () => NeoPage(
            header: const NeoTopBar(title: '운동 플랜'),
            children: [
              _DateNavigator(
                date: selectedDate,
                onPrevious: () => _shiftDate(ref, selectedDate, -1),
                onNext: () => _shiftDate(ref, selectedDate, 1),
                onPick: () => _pickDate(context, ref, selectedDate),
              ),
              const SizedBox(height: AppSpacing.lg),
              const NeoStateCard(
                icon: Icons.fitness_center,
                title: '운동 기록을 불러오는 중',
                message: '선택한 날짜의 세트 기록을 동기화하고 있습니다.',
              ),
            ],
          ),
      error:
          (Object error, StackTrace _) => NeoPage(
            header: const NeoTopBar(title: '운동 플랜'),
            children: [
              _DateNavigator(
                date: selectedDate,
                onPrevious: () => _shiftDate(ref, selectedDate, -1),
                onNext: () => _shiftDate(ref, selectedDate, 1),
                onPick: () => _pickDate(context, ref, selectedDate),
              ),
              const SizedBox(height: AppSpacing.lg),
              NeoStateCard(
                icon: Icons.error_outline,
                title: '운동 기록을 불러오지 못했습니다',
                message: _extractErrorMessage(error),
                actionLabel: '다시 시도',
                onAction: () => ref.invalidate(exerciseLogsProvider),
              ),
            ],
          ),
      data: (Map<String, dynamic> data) {
        final List<Map<String, dynamic>> allExercises = _readExercises(data);
        final List<Map<String, dynamic>> filteredExercises = _filterExercises(
          allExercises,
          selectedMuscleGroup,
        );
        final int totalSets = allExercises.fold<int>(
          0,
          (int total, Map<String, dynamic> exercise) =>
              total + _readSets(exercise).length,
        );

        return NeoPage(
          header: const NeoTopBar(title: '운동 플랜'),
          onRefresh: () async {
            ref.invalidate(exerciseLogsProvider);
            await Future<void>.delayed(const Duration(milliseconds: 300));
          },
          children: [
            _DateNavigator(
              date: selectedDate,
              onPrevious: () => _shiftDate(ref, selectedDate, -1),
              onNext: () => _shiftDate(ref, selectedDate, 1),
              onPick: () => _pickDate(context, ref, selectedDate),
            ),
            const SizedBox(height: AppSpacing.lg),
            _NoActiveSessionCard(
              recordedExerciseCount: allExercises.length,
              recordedSetCount: totalSets,
              onAdd: () => context.push('/exercise/add'),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('근육군', style: AppTypography.caption),
            const SizedBox(height: AppSpacing.sm),
            _MuscleGroupFilter(
              selectedMuscleGroup: selectedMuscleGroup,
              onSelected: (String? muscleGroup) {
                ref.read(selectedMuscleGroupProvider.notifier).state =
                    muscleGroup;
              },
            ),
            const SizedBox(height: AppSpacing.lg),
            NeoSectionHeader(
              title: '기록된 운동',
              actionLabel: 'AI 추천',
              onAction: () => context.push('/exercise/recommend'),
            ),
            const SizedBox(height: AppSpacing.xs),
            if (filteredExercises.isEmpty)
              NeoStateCard(
                icon: Icons.add_circle_outline,
                title: '아직 기록된 운동이 없습니다',
                message:
                    selectedMuscleGroup == null
                        ? '수행한 운동과 세트를 기록하거나 AI 추천을 확인해 보세요.'
                        : '선택한 근육군에 해당하는 기록이 없습니다.',
                actionLabel: '운동 추가',
                onAction: () => context.push('/exercise/add'),
              )
            else
              for (final Map<String, dynamic> exercise
                  in filteredExercises) ...[
                _ExerciseCard(
                  exercise: exercise,
                  onDelete:
                      (int logId) => _deleteExerciseLog(context, ref, logId),
                ),
                const SizedBox(height: AppSpacing.md),
              ],
            _AiCoachCard(
              onRecommend: () => context.push('/exercise/recommend'),
              onChat: () => context.push('/ai/chat'),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: NeoPrimaryButton(
                    label: '운동 추가',
                    icon: Icons.add,
                    onPressed: () => context.push('/exercise/add'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: NeoOutlineButton(
                    label: 'AI 추천',
                    icon: Icons.auto_awesome,
                    onPressed: () => context.push('/exercise/recommend'),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  void _shiftDate(WidgetRef ref, DateTime currentDate, int days) {
    ref.read(exerciseDateProvider.notifier).state = currentDate.add(
      Duration(days: days),
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
    if (pickedDate != null) {
      ref.read(exerciseDateProvider.notifier).state = pickedDate;
    }
  }

  Future<bool> _deleteExerciseLog(
    BuildContext context,
    WidgetRef ref,
    int logId,
  ) async {
    if (logId <= 0) {
      return false;
    }
    try {
      await deleteExerciseLogAndRefresh(ref, logId);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('운동 기록을 삭제했습니다.')));
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

class _DateNavigator extends StatelessWidget {
  final DateTime date;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onPick;

  const _DateNavigator({
    required this.date,
    required this.onPrevious,
    required this.onNext,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _DateIconButton(
          tooltip: '이전 날짜',
          icon: Icons.chevron_left,
          onPressed: onPrevious,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.md),
            onTap: onPick,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Column(
                children: [
                  Text('선택한 날짜', style: AppTypography.caption),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    DateFormat('yyyy년 M월 d일').format(date),
                    style: AppTypography.h3,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        _DateIconButton(
          tooltip: '다음 날짜',
          icon: Icons.chevron_right,
          onPressed: onNext,
        ),
      ],
    );
  }
}

class _DateIconButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  const _DateIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        minimumSize: const Size(44, 44),
        backgroundColor: AppColors.surfaceHigh,
        side: const BorderSide(color: AppColors.divider),
      ),
      icon: Icon(icon, color: AppColors.textPrimary),
    );
  }
}

class _NoActiveSessionCard extends StatelessWidget {
  final int recordedExerciseCount;
  final int recordedSetCount;
  final VoidCallback onAdd;

  const _NoActiveSessionCard({
    required this.recordedExerciseCount,
    required this.recordedSetCount,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return NeoGlassCard(
      highlighted: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: const Icon(
                  Icons.timer_outlined,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('진행 중인 세션 없음', style: AppTypography.h3),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      '실시간 세션 데이터는 준비 중입니다.',
                      style: AppTypography.body2.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (recordedExerciseCount > 0) ...[
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                NeoInfoChip(
                  label: '기록 $recordedExerciseCount개',
                  color: AppColors.primary,
                ),
                NeoInfoChip(
                  label: '총 $recordedSetCount세트',
                  color: AppColors.secondary,
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          NeoPrimaryButton(
            label: '운동 기록 시작',
            icon: Icons.add,
            onPressed: onAdd,
          ),
        ],
      ),
    );
  }
}

class _MuscleGroupFilter extends StatelessWidget {
  final String? selectedMuscleGroup;
  final ValueChanged<String?> onSelected;

  const _MuscleGroupFilter({
    required this.selectedMuscleGroup,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _MuscleChip(
            label: '전체',
            selected: selectedMuscleGroup == null,
            onTap: () => onSelected(null),
          ),
          const SizedBox(width: AppSpacing.xs),
          for (final String muscleGroup in kMuscleGroupOrder) ...[
            _MuscleChip(
              label: kMuscleGroupLabels[muscleGroup] ?? muscleGroup,
              selected: selectedMuscleGroup == muscleGroup,
              onTap: () => onSelected(muscleGroup),
            ),
            const SizedBox(width: AppSpacing.xs),
          ],
        ],
      ),
    );
  }
}

class _MuscleChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _MuscleChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.full),
      onTap: onTap,
      child: NeoInfoChip(
        label: label,
        filled: selected,
        color: selected ? AppColors.primary : AppColors.textSecondary,
      ),
    );
  }
}

class _ExerciseCard extends StatelessWidget {
  final Map<String, dynamic> exercise;
  final Future<bool> Function(int logId) onDelete;

  const _ExerciseCard({required this.exercise, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final int logId = _toInt(exercise['id']);
    final String exerciseName =
        exercise['exercise_name']?.toString().trim().isNotEmpty == true
            ? exercise['exercise_name'].toString().trim()
            : '이름 없는 운동';
    final String muscleGroup = exercise['muscle_group']?.toString() ?? '';
    final String muscleLabel = kMuscleGroupLabels[muscleGroup] ?? muscleGroup;
    final String memo = exercise['memo']?.toString().trim() ?? '';
    final List<Map<String, dynamic>> sets = _readSets(exercise);
    final String? assetPath = _assetForExercise(exerciseName);

    return NeoGlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (assetPath != null)
                NeoAssetImage(path: assetPath, width: 72, height: 72)
              else
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceHigh,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    border: Border.all(color: AppColors.glassBorder),
                  ),
                  child: const Icon(
                    Icons.fitness_center,
                    color: AppColors.primary,
                    size: 28,
                  ),
                ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(exerciseName, style: AppTypography.h3),
                    const SizedBox(height: AppSpacing.sm),
                    Wrap(
                      spacing: AppSpacing.xs,
                      runSpacing: AppSpacing.xs,
                      children: [
                        if (muscleLabel.isNotEmpty)
                          NeoInfoChip(
                            label: muscleLabel,
                            color: AppColors.secondary,
                          ),
                        NeoInfoChip(
                          label: '${sets.length}세트',
                          color: AppColors.primary,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '운동 기록 삭제',
                onPressed: logId > 0 ? () => onDelete(logId) : null,
                icon: const Icon(Icons.delete_outline),
                color: AppColors.textDisabled,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (sets.isEmpty)
            Text(
              '저장된 세트 정보가 없습니다.',
              style: AppTypography.body2.copyWith(
                color: AppColors.textSecondary,
              ),
            )
          else
            _SetDetails(sets: sets),
          if (memo.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.notes,
                  size: 16,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    memo,
                    style: AppTypography.caption.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SetDetails extends StatelessWidget {
  final List<Map<String, dynamic>> sets;

  const _SetDetails({required this.sets});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: Text('세트', style: AppTypography.caption)),
            Expanded(
              child: Text(
                '횟수',
                style: AppTypography.caption,
                textAlign: TextAlign.center,
              ),
            ),
            Expanded(
              child: Text(
                '중량',
                style: AppTypography.caption,
                textAlign: TextAlign.end,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        for (int index = 0; index < sets.length; index += 1) ...[
          _SetDetailRow(set: sets[index], fallbackNumber: index + 1),
          if (index != sets.length - 1)
            const Divider(height: AppSpacing.md, color: AppColors.divider),
        ],
      ],
    );
  }
}

class _SetDetailRow extends StatelessWidget {
  final Map<String, dynamic> set;
  final int fallbackNumber;

  const _SetDetailRow({required this.set, required this.fallbackNumber});

  @override
  Widget build(BuildContext context) {
    final int setNumber = _toInt(set['set_number']);
    final int reps = _toInt(set['reps']);
    final double? weight = _toDoubleOrNull(set['weight_kg']);

    return Row(
      children: [
        Expanded(
          child: Text(
            '${setNumber > 0 ? setNumber : fallbackNumber}',
            style: AppTypography.label,
          ),
        ),
        Expanded(
          child: Text(
            reps > 0 ? '$reps회' : '--',
            style: AppTypography.label.copyWith(color: AppColors.textPrimary),
            textAlign: TextAlign.center,
          ),
        ),
        Expanded(
          child: Text(
            weight == null ? '미지정' : '${_formatNumber(weight)}kg',
            style: AppTypography.label.copyWith(
              color:
                  weight == null ? AppColors.textDisabled : AppColors.primary,
            ),
            textAlign: TextAlign.end,
          ),
        ),
      ],
    );
  }
}

class _AiCoachCard extends StatelessWidget {
  final VoidCallback onRecommend;
  final VoidCallback onChat;

  const _AiCoachCard({required this.onRecommend, required this.onChat});

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
          Text('AI 운동 코치', style: AppTypography.h2),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '저장된 운동 기록과 검증된 지식 출처를 바탕으로 다음 루틴을 요청할 수 있습니다.',
            style: AppTypography.body2.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: NeoPrimaryButton(label: '루틴 추천', onPressed: onRecommend),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: NeoOutlineButton(label: '코치에게 질문', onPressed: onChat),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

List<Map<String, dynamic>> _readExercises(Map<String, dynamic> data) {
  final List<dynamic> logs = data['exercises'] as List<dynamic>? ?? <dynamic>[];
  return logs.whereType<Map<String, dynamic>>().toList();
}

List<Map<String, dynamic>> _filterExercises(
  List<Map<String, dynamic>> exercises,
  String? selectedMuscleGroup,
) {
  if (selectedMuscleGroup == null) {
    return exercises;
  }
  return exercises
      .where(
        (Map<String, dynamic> item) =>
            item['muscle_group']?.toString() == selectedMuscleGroup,
      )
      .toList();
}

List<Map<String, dynamic>> _readSets(Map<String, dynamic> exercise) {
  final List<dynamic> sets = exercise['sets'] as List<dynamic>? ?? <dynamic>[];
  return sets.whereType<Map<String, dynamic>>().toList();
}

String? _assetForExercise(String exerciseName) {
  final String normalized = exerciseName.toLowerCase();
  if (normalized.contains('스쿼트') || normalized.contains('squat')) {
    return 'assets/stitch/workout_squat.jpg';
  }
  if (normalized.contains('레그 익스텐션') || normalized.contains('leg extension')) {
    return 'assets/stitch/workout_leg_extension.jpg';
  }
  if (normalized.contains('로우') || normalized.contains('row')) {
    return 'assets/stitch/workout_row.jpg';
  }
  return null;
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

double? _toDoubleOrNull(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value);
  }
  return null;
}

String _formatNumber(double value) {
  if (value == value.roundToDouble()) {
    return value.toStringAsFixed(0);
  }
  return value.toStringAsFixed(1);
}

String _extractErrorMessage(Object error) {
  if (error is ExerciseRepositoryException) {
    return error.message;
  }
  return '운동 기록을 처리하는 중 오류가 발생했습니다.';
}
