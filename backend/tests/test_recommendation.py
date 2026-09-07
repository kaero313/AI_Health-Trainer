from unittest.mock import AsyncMock, patch

import pytest

from app.services.recommendation_service import RecommendationServiceError
from app.services.ai_service import AIServiceError

MOCK_DIET_REC = {
    "remaining_nutrients": {
        "calories": 950,
        "protein_g": 50,
        "carbs_g": 120,
        "fat_g": 22,
    },
    "recommendation": "Try sweet potato and salmon",
    "suggested_foods": [
        {
            "food_name": "sweet_potato",
            "serving_size": "200g",
            "calories": 170,
            "protein_g": 3,
            "carbs_g": 40,
            "fat_g": 0,
            "reason": "carb refill",
        }
    ],
    "sources": ["bulking diet guide"],
}

MOCK_EXERCISE_REC = {
    "recommendation": "Try bench press at 62.5kg",
    "suggested_exercises": [
        {
            "exercise_name": "bench_press",
            "muscle_group": "chest",
            "sets": 4,
            "reps": 8,
            "weight_kg": 62.5,
            "reason": "progressive overload",
        }
    ],
    "sources": ["progressive overload principle"],
}


async def _setup_profile(client, token, auth_headers) -> None:
    response = await client.put(
        "/api/v1/profile",
        json={
            "height_cm": 175.0,
            "weight_kg": 70.0,
            "age": 28,
            "gender": "male",
            "goal": "bulk",
            "activity_level": "moderate",
            "allergies": [],
            "food_preferences": ["chicken_breast"],
        },
        headers=auth_headers(token),
    )
    assert response.status_code == 200


@pytest.mark.asyncio
@patch("app.api.v1.diet.RecommendationService")
@patch("app.api.v1.diet.RAGService")
@patch("app.api.v1.diet.AIService")
async def test_recommend_diet_success(
    mock_ai_class,
    mock_rag_class,
    mock_rec_class,
    client,
    register_and_get_token,
    auth_headers,
):
    _ = mock_rag_class
    mock_ai = mock_ai_class.return_value
    mock_ai.check_rate_limit = AsyncMock(return_value=False)

    mock_rec = mock_rec_class.return_value
    mock_rec.recommend_diet = AsyncMock(return_value=MOCK_DIET_REC)

    token, _ = await register_and_get_token(client, "diet-rec-success@example.com")
    await _setup_profile(client, token, auth_headers)
    create_response = await client.post(
        "/api/v1/diet/logs",
        json={
            "log_date": "2026-02-19",
            "meal_type": "lunch",
            "items": [
                {
                    "food_name": "chicken_breast",
                    "serving_size": "150g",
                    "calories": 250,
                    "protein_g": 45,
                    "carbs_g": 0,
                    "fat_g": 5,
                }
            ],
        },
        headers=auth_headers(token),
    )
    assert create_response.status_code == 201

    response = await client.get("/api/v1/diet/recommend", headers=auth_headers(token))
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "success"
    assert body["data"]["recommendation"] == MOCK_DIET_REC["recommendation"]
    assert len(body["data"]["suggested_foods"]) == 1


@pytest.mark.asyncio
@patch("app.api.v1.diet.RecommendationService")
@patch("app.api.v1.diet.RAGService")
@patch("app.api.v1.diet.AIService")
async def test_recommend_diet_no_profile(
    mock_ai_class,
    mock_rag_class,
    mock_rec_class,
    client,
    register_and_get_token,
    auth_headers,
):
    _ = mock_rag_class
    mock_ai = mock_ai_class.return_value
    mock_ai.check_rate_limit = AsyncMock(return_value=False)

    mock_rec = mock_rec_class.return_value
    mock_rec.recommend_diet = AsyncMock(
        side_effect=RecommendationServiceError(404, "NOT_FOUND", "Profile not found")
    )

    token, _ = await register_and_get_token(client, "diet-rec-no-profile@example.com")
    response = await client.get("/api/v1/diet/recommend", headers=auth_headers(token))

    assert response.status_code == 404
    body = response.json()
    assert body["status"] == "error"
    assert body["error"]["code"] == "NOT_FOUND"


@pytest.mark.asyncio
@patch("app.api.v1.diet.RecommendationService")
@patch("app.api.v1.diet.RAGService")
@patch("app.api.v1.diet.AIService")
async def test_recommend_diet_rate_limited(
    mock_ai_class,
    mock_rag_class,
    mock_rec_class,
    client,
    register_and_get_token,
    auth_headers,
):
    _ = mock_rag_class
    mock_ai = mock_ai_class.return_value
    mock_ai.check_rate_limit = AsyncMock(return_value=True)
    mock_rec = mock_rec_class.return_value
    mock_rec.recommend_diet = AsyncMock(
        side_effect=AIServiceError(
            429,
            "DAILY_LIMIT_EXCEEDED",
            "일일 AI 사용 한도에 도달했습니다",
            stage="quota_admission",
        )
    )

    token, _ = await register_and_get_token(client, "diet-rec-rate-limit@example.com")
    response = await client.get("/api/v1/diet/recommend", headers=auth_headers(token))

    assert response.status_code == 429
    body = response.json()
    assert body["status"] == "error"
    assert body["error"]["code"] == "DAILY_LIMIT_EXCEEDED"


@pytest.mark.asyncio
@patch("app.api.v1.exercise.RecommendationService")
@patch("app.api.v1.exercise.RAGService")
@patch("app.api.v1.exercise.AIService")
async def test_recommend_exercise_success(
    mock_ai_class,
    mock_rag_class,
    mock_rec_class,
    client,
    register_and_get_token,
    auth_headers,
):
    _ = mock_rag_class
    mock_ai = mock_ai_class.return_value
    mock_ai.check_rate_limit = AsyncMock(return_value=False)

    mock_rec = mock_rec_class.return_value
    mock_rec.recommend_exercise = AsyncMock(return_value=MOCK_EXERCISE_REC)

    token, _ = await register_and_get_token(client, "exercise-rec-success@example.com")
    await _setup_profile(client, token, auth_headers)
    create_response = await client.post(
        "/api/v1/exercise/logs",
        json={
            "exercise_date": "2026-02-19",
            "exercise_name": "Bench Press",
            "muscle_group": "chest",
            "sets": [{"set_number": 1, "reps": 8, "weight_kg": 60.0, "is_completed": True}],
        },
        headers=auth_headers(token),
    )
    assert create_response.status_code == 201

    response = await client.get("/api/v1/exercise/recommend", headers=auth_headers(token))
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "success"
    assert body["data"]["recommendation"] == MOCK_EXERCISE_REC["recommendation"]
    assert len(body["data"]["suggested_exercises"]) == 1


@pytest.mark.asyncio
@patch("app.api.v1.exercise.RecommendationService")
@patch("app.api.v1.exercise.RAGService")
@patch("app.api.v1.exercise.AIService")
async def test_recommend_exercise_no_profile(
    mock_ai_class,
    mock_rag_class,
    mock_rec_class,
    client,
    register_and_get_token,
    auth_headers,
):
    _ = mock_rag_class
    mock_ai = mock_ai_class.return_value
    mock_ai.check_rate_limit = AsyncMock(return_value=False)

    mock_rec = mock_rec_class.return_value
    mock_rec.recommend_exercise = AsyncMock(
        side_effect=RecommendationServiceError(404, "NOT_FOUND", "Profile not found")
    )

    token, _ = await register_and_get_token(client, "exercise-rec-no-profile@example.com")
    response = await client.get("/api/v1/exercise/recommend", headers=auth_headers(token))

    assert response.status_code == 404
    body = response.json()
    assert body["status"] == "error"
    assert body["error"]["code"] == "NOT_FOUND"


@pytest.mark.asyncio
@patch("app.api.v1.exercise.RecommendationService")
@patch("app.api.v1.exercise.RAGService")
@patch("app.api.v1.exercise.AIService")
async def test_recommend_exercise_no_records(
    mock_ai_class,
    mock_rag_class,
    mock_rec_class,
    client,
    register_and_get_token,
    auth_headers,
):
    _ = mock_rag_class
    mock_ai = mock_ai_class.return_value
    mock_ai.check_rate_limit = AsyncMock(return_value=False)

    mock_rec = mock_rec_class.return_value
    mock_rec.recommend_exercise = AsyncMock(return_value=MOCK_EXERCISE_REC)

    token, _ = await register_and_get_token(client, "exercise-rec-no-records@example.com")
    await _setup_profile(client, token, auth_headers)

    response = await client.get("/api/v1/exercise/recommend", headers=auth_headers(token))
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "success"
    assert len(body["data"]["suggested_exercises"]) == 1
