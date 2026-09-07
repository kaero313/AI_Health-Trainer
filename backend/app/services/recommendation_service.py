from __future__ import annotations

import hashlib
import time
from datetime import date
from decimal import Decimal, ROUND_HALF_UP
from uuid import uuid4

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.models.ai_recommendation import AIRecommendation, RecommendationTypeEnum
from app.models.diet import DietLog, DietLogItem
from app.models.exercise import ExerciseLog, MuscleGroupEnum
from app.models.rag import AIGenerationTrace
from app.models.user import UserProfile
from app.services.ai_service import (
    DIET_RECOMMEND_SCHEMA_VERSION,
    EXERCISE_RECOMMEND_SCHEMA_VERSION,
    AIInvocationResult,
    AIService,
    AIServiceError,
)
from app.services.ai_trace_service import AIGenerationAttemptRecorder
from app.services.ai_quota_service import AIQuotaError, AIQuotaService
from app.services.rag_prompt_context import build_rag_prompt_context
from app.services.rag_service import RAGService


class RecommendationServiceError(Exception):
    def __init__(self, status_code: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message


class RecommendationService:
    GOAL_DESCRIPTION_MAP = {
        "bulk": "벌크업",
        "diet": "다이어트",
        "maintain": "유지",
    }

    def __init__(
        self,
        db: AsyncSession,
        ai_service: AIService,
        rag_service: RAGService,
        quota_service: AIQuotaService,
    ) -> None:
        self.db = db
        self.ai_service = ai_service
        self.rag_service = rag_service
        self.quota_service = quota_service

    async def recommend_diet(self, user_id: int, target_date: date) -> dict:
        pipeline_started = time.perf_counter()
        profile = await self._get_profile(user_id)
        goal = profile.goal.value
        goal_description = self.GOAL_DESCRIPTION_MAP.get(goal, goal)

        consumed_calories, consumed_protein, consumed_carbs, consumed_fat = await self._get_daily_consumed(
            user_id,
            target_date,
        )

        target_calories = profile.target_calories if profile.target_calories is not None else 0
        target_protein = self._to_float(profile.target_protein_g)
        target_carbs = self._to_float(profile.target_carbs_g)
        target_fat = self._to_float(profile.target_fat_g)

        remaining = {
            "calories": self._round_one_decimal(float(target_calories) - consumed_calories),
            "protein_g": self._round_one_decimal(target_protein - consumed_protein),
            "carbs_g": self._round_one_decimal(target_carbs - consumed_carbs),
            "fat_g": self._round_one_decimal(target_fat - consumed_fat),
        }

        user_context = {
            "height_cm": self._to_float(profile.height_cm),
            "weight_kg": self._to_float(profile.weight_kg),
            "goal": goal,
            "goal_description": goal_description,
            "activity_level": profile.activity_level.value if profile.activity_level is not None else "unknown",
            "allergies": self._list_to_csv(profile.allergies),
            "food_preferences": self._list_to_csv(profile.food_preferences),
            "target_calories": int(target_calories),
            "target_protein_g": target_protein,
            "target_carbs_g": target_carbs,
            "target_fat_g": target_fat,
            "consumed_calories": consumed_calories,
            "consumed_protein": consumed_protein,
            "consumed_carbs": consumed_carbs,
            "consumed_fat": consumed_fat,
        }

        trace_group_id = str(uuid4())
        rag_query = self._build_diet_rag_query(goal_description, remaining, user_context)
        input_context_hash = self._hash_text(
            str({"context": user_context, "query": rag_query})
        )
        generation_trace = await self.ai_service.start_generation_trace(
            self.db,
            user_id=user_id,
            request_type="diet",
            prompt_version=DIET_RECOMMEND_SCHEMA_VERSION,
            rag_trace_group_id=trace_group_id,
            input_context_hash=input_context_hash,
            trace_metadata={"retrieval_category": "nutrition"},
        )
        await self._reserve_generation_quota(generation_trace)
        attempt_recorder = AIGenerationAttemptRecorder(
            self.db,
            generation_trace.id,
            self.quota_service,
        )
        retrieval_started = time.perf_counter()
        documents = await self.rag_service.search(
            rag_query,
            category="nutrition",
            top_k=3,
            user_id=user_id,
            request_type="diet",
            trace_group_id=trace_group_id,
        )
        pipeline_metadata = self._retrieval_metadata(
            documents,
            int((time.perf_counter() - retrieval_started) * 1000),
        )
        if not documents:
            error = self._rag_unavailable_error(DIET_RECOMMEND_SCHEMA_VERSION)
            pipeline_metadata["pre_persistence_pipeline_latency_ms"] = int(
                (time.perf_counter() - pipeline_started) * 1000
            )
            await self._record_failed_generation(
                user_id=user_id,
                request_type="diet",
                prompt_version=DIET_RECOMMEND_SCHEMA_VERSION,
                trace_group_id=trace_group_id,
                generation_trace_id=generation_trace.id,
                input_context_hash=input_context_hash,
                error=error,
                trace_metadata=pipeline_metadata,
            )
            raise error

        context_started = time.perf_counter()
        prompt_context = build_rag_prompt_context(documents)
        pipeline_metadata["prompt_context_build_latency_ms"] = int(
            (time.perf_counter() - context_started) * 1000
        )
        generation_started = time.perf_counter()
        try:
            invocation = await self.ai_service.recommend_diet(
                user_context,
                prompt_context.text,
                allowed_source_refs=prompt_context.allowed_refs,
                attempt_recorder=attempt_recorder,
            )
        except AIServiceError as error:
            pipeline_metadata["generation_call_latency_ms"] = int(
                (time.perf_counter() - generation_started) * 1000
            )
            pipeline_metadata["pre_persistence_pipeline_latency_ms"] = int(
                (time.perf_counter() - pipeline_started) * 1000
            )
            await self._record_failed_generation(
                user_id=user_id,
                request_type="diet",
                prompt_version=DIET_RECOMMEND_SCHEMA_VERSION,
                trace_group_id=trace_group_id,
                generation_trace_id=generation_trace.id,
                input_context_hash=input_context_hash,
                error=error,
                trace_metadata=pipeline_metadata,
            )
            raise
        pipeline_metadata["generation_call_latency_ms"] = int(
            (time.perf_counter() - generation_started) * 1000
        )

        recommendation_text = prompt_context.resolve_reference_markers(
            str(invocation.payload["recommendation"])
        )
        suggested_foods = list(invocation.payload["suggested_foods"])
        source_refs = [str(ref) for ref in invocation.payload["source_refs"]]
        sources = prompt_context.verified_titles(source_refs)
        await self.rag_service.mark_traces_used_in_response(
            trace_group_id,
            prompt_context.selected_chunk_ids(source_refs),
        )
        pipeline_metadata["pre_persistence_pipeline_latency_ms"] = int(
            (time.perf_counter() - pipeline_started) * 1000
        )
        await self._save_recommendation(
            user_id=user_id,
            recommendation_type=RecommendationTypeEnum.DIET,
            context_summary=f"{target_date.isoformat()} 식단 추천",
            recommendation=recommendation_text,
            rag_sources=sources,
            prompt_used=None,
            request_type="diet",
            prompt_version=DIET_RECOMMEND_SCHEMA_VERSION,
            trace_group_id=trace_group_id,
            generation_trace_id=generation_trace.id,
            input_context_hash=input_context_hash,
            output_hash=self._hash_text(recommendation_text),
            invocation=invocation,
            source_refs=source_refs,
            trace_metadata=pipeline_metadata,
        )

        return {
            "remaining_nutrients": remaining,
            "recommendation": recommendation_text,
            "suggested_foods": suggested_foods,
            "sources": sources,
        }

    async def recommend_exercise(self, user_id: int, muscle_group: str | None) -> dict:
        pipeline_started = time.perf_counter()
        profile = await self._get_profile(user_id)
        goal = profile.goal.value
        goal_description = self.GOAL_DESCRIPTION_MAP.get(goal, goal)

        parsed_muscle_group: MuscleGroupEnum | None = None
        if muscle_group is not None:
            try:
                parsed_muscle_group = MuscleGroupEnum(muscle_group)
            except ValueError as exc:
                raise RecommendationServiceError(400, "VALIDATION_ERROR", "지원하지 않는 근육군입니다") from exc

        recent_logs = await self._get_recent_exercise_logs(user_id, parsed_muscle_group)
        selected_muscle_group = (
            parsed_muscle_group.value
            if parsed_muscle_group is not None
            else (recent_logs[0].muscle_group.value if recent_logs else "full_body")
        )

        trace_group_id = str(uuid4())
        rag_query = self._build_exercise_rag_query(goal_description, selected_muscle_group, recent_logs)
        exercise_history = self._build_exercise_history(recent_logs)
        user_context = {
            "goal": goal,
            "weight_kg": self._to_float(profile.weight_kg),
            "muscle_group": selected_muscle_group,
            "exercise_history": exercise_history,
        }
        input_context_hash = self._hash_text(
            str({"context": user_context, "query": rag_query})
        )
        generation_trace = await self.ai_service.start_generation_trace(
            self.db,
            user_id=user_id,
            request_type="exercise",
            prompt_version=EXERCISE_RECOMMEND_SCHEMA_VERSION,
            rag_trace_group_id=trace_group_id,
            input_context_hash=input_context_hash,
            trace_metadata={"retrieval_category": "exercise"},
        )
        await self._reserve_generation_quota(generation_trace)
        attempt_recorder = AIGenerationAttemptRecorder(
            self.db,
            generation_trace.id,
            self.quota_service,
        )
        retrieval_started = time.perf_counter()
        documents = await self.rag_service.search(
            rag_query,
            category="exercise",
            top_k=3,
            user_id=user_id,
            request_type="exercise",
            trace_group_id=trace_group_id,
        )
        pipeline_metadata = self._retrieval_metadata(
            documents,
            int((time.perf_counter() - retrieval_started) * 1000),
        )

        if not documents:
            error = self._rag_unavailable_error(EXERCISE_RECOMMEND_SCHEMA_VERSION)
            pipeline_metadata["pre_persistence_pipeline_latency_ms"] = int(
                (time.perf_counter() - pipeline_started) * 1000
            )
            await self._record_failed_generation(
                user_id=user_id,
                request_type="exercise",
                prompt_version=EXERCISE_RECOMMEND_SCHEMA_VERSION,
                trace_group_id=trace_group_id,
                generation_trace_id=generation_trace.id,
                input_context_hash=input_context_hash,
                error=error,
                trace_metadata=pipeline_metadata,
            )
            raise error

        context_started = time.perf_counter()
        prompt_context = build_rag_prompt_context(documents)
        pipeline_metadata["prompt_context_build_latency_ms"] = int(
            (time.perf_counter() - context_started) * 1000
        )
        generation_started = time.perf_counter()
        try:
            invocation = await self.ai_service.recommend_exercise(
                user_context,
                prompt_context.text,
                allowed_source_refs=prompt_context.allowed_refs,
                attempt_recorder=attempt_recorder,
            )
        except AIServiceError as error:
            pipeline_metadata["generation_call_latency_ms"] = int(
                (time.perf_counter() - generation_started) * 1000
            )
            pipeline_metadata["pre_persistence_pipeline_latency_ms"] = int(
                (time.perf_counter() - pipeline_started) * 1000
            )
            await self._record_failed_generation(
                user_id=user_id,
                request_type="exercise",
                prompt_version=EXERCISE_RECOMMEND_SCHEMA_VERSION,
                trace_group_id=trace_group_id,
                generation_trace_id=generation_trace.id,
                input_context_hash=input_context_hash,
                error=error,
                trace_metadata=pipeline_metadata,
            )
            raise
        pipeline_metadata["generation_call_latency_ms"] = int(
            (time.perf_counter() - generation_started) * 1000
        )

        recommendation_text = prompt_context.resolve_reference_markers(
            str(invocation.payload["recommendation"])
        )
        suggested_exercises = list(invocation.payload["suggested_exercises"])
        source_refs = [str(ref) for ref in invocation.payload["source_refs"]]
        sources = prompt_context.verified_titles(source_refs)
        await self.rag_service.mark_traces_used_in_response(
            trace_group_id,
            prompt_context.selected_chunk_ids(source_refs),
        )
        pipeline_metadata["pre_persistence_pipeline_latency_ms"] = int(
            (time.perf_counter() - pipeline_started) * 1000
        )
        await self._save_recommendation(
            user_id=user_id,
            recommendation_type=RecommendationTypeEnum.EXERCISE,
            context_summary=f"{selected_muscle_group} 운동 추천",
            recommendation=recommendation_text,
            rag_sources=sources,
            prompt_used=None,
            request_type="exercise",
            prompt_version=EXERCISE_RECOMMEND_SCHEMA_VERSION,
            trace_group_id=trace_group_id,
            generation_trace_id=generation_trace.id,
            input_context_hash=input_context_hash,
            output_hash=self._hash_text(recommendation_text),
            invocation=invocation,
            source_refs=source_refs,
            trace_metadata=pipeline_metadata,
        )

        return {
            "recommendation": recommendation_text,
            "suggested_exercises": suggested_exercises,
            "sources": sources,
        }

    async def _get_profile(self, user_id: int) -> UserProfile:
        result = await self.db.execute(select(UserProfile).where(UserProfile.user_id == user_id))
        profile = result.scalar_one_or_none()
        if profile is None:
            raise RecommendationServiceError(404, "NOT_FOUND", "프로필을 먼저 설정해주세요")
        return profile

    async def _get_daily_consumed(self, user_id: int, target_date: date) -> tuple[float, float, float, float]:
        result = await self.db.execute(
            select(
                func.coalesce(func.sum(DietLogItem.calories), 0),
                func.coalesce(func.sum(DietLogItem.protein_g), 0),
                func.coalesce(func.sum(DietLogItem.carbs_g), 0),
                func.coalesce(func.sum(DietLogItem.fat_g), 0),
            )
            .select_from(DietLog)
            .join(DietLogItem, DietLogItem.diet_log_id == DietLog.id)
            .where(DietLog.user_id == user_id, DietLog.log_date == target_date)
        )
        row = result.one()
        return (
            self._to_float(row[0]),
            self._to_float(row[1]),
            self._to_float(row[2]),
            self._to_float(row[3]),
        )

    async def _get_recent_exercise_logs(
        self,
        user_id: int,
        muscle_group: MuscleGroupEnum | None,
    ) -> list[ExerciseLog]:
        stmt = (
            select(ExerciseLog)
            .options(selectinload(ExerciseLog.exercise_sets))
            .where(ExerciseLog.user_id == user_id)
            .order_by(ExerciseLog.exercise_date.desc(), ExerciseLog.created_at.desc(), ExerciseLog.id.desc())
            .limit(3)
        )
        if muscle_group is not None:
            stmt = stmt.where(ExerciseLog.muscle_group == muscle_group)

        result = await self.db.execute(stmt)
        return result.scalars().all()

    async def _save_recommendation(
        self,
        user_id: int,
        recommendation_type: RecommendationTypeEnum,
        context_summary: str,
        recommendation: str,
        rag_sources: list[str],
        prompt_used: str | None,
        request_type: str,
        prompt_version: str,
        trace_group_id: str | None,
        generation_trace_id: int,
        input_context_hash: str | None,
        output_hash: str | None,
        invocation: AIInvocationResult,
        source_refs: list[str],
        trace_metadata: dict[str, object],
    ) -> None:
        record = AIRecommendation(
            user_id=user_id,
            type=recommendation_type,
            context_summary=context_summary,
            prompt_used=prompt_used,
            recommendation=recommendation,
            rag_sources=rag_sources,
            model_used=invocation.model,
        )
        try:
            self.db.add(record)
            await self.db.flush()
            await self.rag_service.mark_traces_request_id(trace_group_id, record.id)
            generation_trace = await self.db.get(
                AIGenerationTrace,
                generation_trace_id,
            )
            if generation_trace is None:
                raise RuntimeError("generation trace disappeared before persistence")
            self.ai_service.apply_generation_trace_result(
                generation_trace,
                user_id=user_id,
                recommendation_id=record.id,
                request_type=request_type,
                prompt_version=prompt_version,
                status="succeeded",
                rag_trace_group_id=trace_group_id,
                input_context_hash=input_context_hash,
                output_hash=output_hash,
                invocation=invocation,
                trace_metadata={
                    **trace_metadata,
                    "selected_source_refs": source_refs,
                },
            )
            await self.db.commit()
        except Exception as exc:
            await self.db.rollback()
            raise RecommendationServiceError(500, "INTERNAL_ERROR", "추천 결과 저장에 실패했습니다") from exc

    async def _record_failed_generation(
        self,
        *,
        user_id: int,
        request_type: str,
        prompt_version: str,
        trace_group_id: str,
        generation_trace_id: int,
        input_context_hash: str,
        error: AIServiceError,
        trace_metadata: dict[str, object] | None = None,
    ) -> None:
        await self.ai_service.complete_generation_trace(
            self.db,
            generation_trace_id,
            quota_service=self.quota_service,
            user_id=user_id,
            request_type=request_type,
            prompt_version=prompt_version,
            status=error.trace_status,
            rag_trace_group_id=trace_group_id,
            input_context_hash=input_context_hash,
            error=error,
            provider_invoked=error.provider_invoked,
            trace_metadata=trace_metadata,
        )

    async def _reserve_generation_quota(
        self,
        generation_trace: AIGenerationTrace,
    ) -> None:
        try:
            await self.quota_service.reserve(self.db, generation_trace)
        except AIQuotaError as exc:
            raise AIServiceError(
                exc.status_code,
                exc.code,
                exc.message,
                stage=exc.stage,
                provider_invoked=False,
            ) from exc

    @staticmethod
    def _retrieval_metadata(documents: list[dict], retrieval_latency_ms: int) -> dict[str, object]:
        metadata: dict[str, object] = {
            "retrieval_latency_ms": retrieval_latency_ms,
            "retrieved_document_count": len(documents),
        }
        if not documents:
            return metadata

        first = documents[0]
        key_map = {
            "search_backend": "search_backend",
            "search_mode": "search_mode",
            "embedding_latency_ms": "retrieval_embedding_latency_ms",
            "backend_search_latency_ms": "retrieval_backend_search_latency_ms",
            "retrieval_core_latency_ms": "retrieval_core_latency_ms",
        }
        for source_key, target_key in key_map.items():
            value = first.get(source_key)
            if value is not None:
                metadata[target_key] = value
        return metadata

    @staticmethod
    def _rag_unavailable_error(schema_version: str) -> AIServiceError:
        return AIServiceError(
            503,
            "RAG_CONTEXT_UNAVAILABLE",
            "답변 근거를 찾지 못해 AI 요청을 처리할 수 없습니다",
            stage="retrieval",
            provider_invoked=False,
            response_schema_version=schema_version,
        )

    @staticmethod
    def _build_diet_rag_query(goal_description: str, remaining: dict, user_context: dict) -> str:
        return (
            f"{goal_description} 식단 추천 "
            f"남은 칼로리 {remaining['calories']}kcal 단백질 {remaining['protein_g']}g "
            f"탄수화물 {remaining['carbs_g']}g 지방 {remaining['fat_g']}g "
            f"알레르기 {user_context['allergies']} 선호 {user_context['food_preferences']}"
        )

    @staticmethod
    def _build_exercise_rag_query(
        goal_description: str,
        muscle_group: str,
        recent_logs: list[ExerciseLog],
    ) -> str:
        recent_summary = ", ".join(
            f"{log.exercise_name} {len(log.exercise_sets)}세트" for log in recent_logs
        ) or "최근 기록 없음"
        return f"{goal_description} {muscle_group} 운동 추천 최근 운동 {recent_summary}"

    @staticmethod
    def _hash_text(value: str) -> str:
        return hashlib.sha256(value.encode("utf-8")).hexdigest()

    @staticmethod
    def _build_exercise_history(logs: list[ExerciseLog]) -> str:
        if not logs:
            return "기록 없음"

        lines: list[str] = []
        for log in logs:
            set_parts: list[str] = []
            for exercise_set in log.exercise_sets:
                if exercise_set.weight_kg is None:
                    weight_text = "맨몸"
                else:
                    weight_text = f"{float(exercise_set.weight_kg):.1f}kg"
                set_parts.append(f"{exercise_set.set_number}세트 {exercise_set.reps}회 {weight_text}")
            sets_text = ", ".join(set_parts) if set_parts else "세트 정보 없음"
            lines.append(f"- {log.exercise_date.isoformat()} {log.exercise_name}: {sets_text}")
        return "\n".join(lines)

    @staticmethod
    def _list_to_csv(values: list[str]) -> str:
        normalized = [value.strip() for value in values if value.strip()]
        return ", ".join(normalized) if normalized else "없음"

    @staticmethod
    def _to_float(value: Decimal | int | float | None) -> float:
        if value is None:
            return 0.0
        decimal_value = value if isinstance(value, Decimal) else Decimal(str(value))
        return RecommendationService._round_one_decimal(float(decimal_value))

    @staticmethod
    def _round_one_decimal(value: float) -> float:
        return float(Decimal(str(value)).quantize(Decimal("0.1"), rounding=ROUND_HALF_UP))
