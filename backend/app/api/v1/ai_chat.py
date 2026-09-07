from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.database import get_db
from app.core.deps import get_ai_quota_service, get_current_user
from app.models.user import User
from app.schemas.ai import ChatRequest, ChatResponse
from app.services.ai_service import AIService, AIServiceError
from app.services.ai_quota_service import AIQuotaService
from app.services.chat_service import ChatService, ChatServiceError
from app.services.rag_service import RAGService

router = APIRouter(prefix="/ai", tags=["ai"])


@router.post("/chat", response_model=ChatResponse)
async def ai_chat(
    body: ChatRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
    quota_service: AIQuotaService = Depends(get_ai_quota_service),
) -> ChatResponse:
    settings = get_settings()
    ai_service = AIService(settings)
    rag_service = RAGService(db, settings)
    chat_service = ChatService(db, ai_service, rag_service, quota_service)

    try:
        result = await chat_service.chat(current_user.id, body.message, body.context_type)
    except ChatServiceError as exc:
        raise HTTPException(
            status_code=exc.status_code,
            detail={"code": exc.code, "message": exc.message},
        ) from exc
    except AIServiceError as exc:
        raise HTTPException(
            status_code=exc.status_code,
            detail={"code": exc.code, "message": exc.message},
        ) from exc

    return ChatResponse(status="success", data=result)
