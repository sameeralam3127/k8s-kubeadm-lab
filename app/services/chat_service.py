import hashlib
import json
from typing import Any

import redis
from redis.exceptions import RedisError
from sqlalchemy.orm import Session

from app.core.config import get_settings
from app.db.models import ChatMessage, ChatSession
from app.models.schemas import ChatMessageResponse, ProviderConfig, SourceItem
from app.services.provider_service import ProviderService
from app.services.vector_store import VectorStoreService


settings = get_settings()


class ChatService:
    def __init__(self) -> None:
        self.vector_store = VectorStoreService()
        self.provider_service = ProviderService()
        self.redis = redis.Redis.from_url(settings.redis_url, decode_responses=True)

    async def chat(
        self,
        db: Session,
        *,
        session_id: str | None,
        message: str,
        provider_config: ProviderConfig,
    ) -> dict[str, Any]:
        session = self._get_or_create_session(db, session_id)
        history = self._serialize_history(session.messages)
        sources = await self.vector_store.similarity_search(message)
        context = self._build_context(sources)
        prompt_messages = self._build_prompt(message, context, history)
        cache_key = self._make_cache_key(message, provider_config, context)

        cached_answer = self._cache_get(cache_key)
        cached = cached_answer is not None
        if cached_answer is None:
            answer, model_name = await self.provider_service.generate_answer(
                provider_config=provider_config,
                messages=prompt_messages,
            )
            self._cache_set(cache_key, answer)
        else:
            answer = cached_answer
            model_name = provider_config.model or settings.default_chat_model

        self._persist_message(
            db,
            session=session,
            role="user",
            content=message,
            provider=provider_config.provider,
            model_name=provider_config.model or "",
        )
        self._persist_message(
            db,
            session=session,
            role="assistant",
            content=answer,
            provider=provider_config.provider,
            model_name=model_name,
        )
        db.refresh(session)

        return {
            "session_id": session.id,
            "answer": answer,
            "cached": cached,
            "provider": provider_config.provider,
            "model_name": model_name,
            "sources": [
                SourceItem(
                    source=source["metadata"].get("source", "unknown"),
                    page=source["metadata"].get("page"),
                    preview=source["content"][:220],
                )
                for source in sources
            ],
            "history": self._serialize_history(session.messages),
        }

    def get_history(self, db: Session, session_id: str) -> list[ChatMessageResponse]:
        session = db.get(ChatSession, session_id)
        if not session:
            return []
        return self._serialize_history(session.messages)

    def _get_or_create_session(self, db: Session, session_id: str | None) -> ChatSession:
        if session_id:
            existing = db.get(ChatSession, session_id)
            if existing:
                return existing
        session = ChatSession()
        db.add(session)
        db.commit()
        db.refresh(session)
        return session

    def _persist_message(
        self,
        db: Session,
        *,
        session: ChatSession,
        role: str,
        content: str,
        provider: str,
        model_name: str,
    ) -> None:
        db.add(
            ChatMessage(
                session_id=session.id,
                role=role,
                content=content,
                provider=provider,
                model_name=model_name,
            )
        )
        db.commit()

    def _serialize_history(self, messages: list[ChatMessage]) -> list[ChatMessageResponse]:
        return [
            ChatMessageResponse(
                role=message.role,
                content=message.content,
                provider=message.provider,
                model_name=message.model_name,
            )
            for message in messages
        ]

    def _build_context(self, matches: list[dict[str, Any]]) -> str:
        if not matches:
            return "No internal documents matched this question."
        lines = []
        for idx, match in enumerate(matches, start=1):
            source = match["metadata"].get("source", "unknown")
            page = match["metadata"].get("page", "?")
            lines.append(f"[{idx}] Source={source} Page={page}\n{match['content']}")
        return "\n\n".join(lines)

    def _build_prompt(
        self,
        user_message: str,
        context: str,
        history: list[ChatMessageResponse],
    ) -> list[dict[str, str]]:
        conversation = [
            {
                "role": "system",
                "content": (
                    "You are an assistant for an offline-first RAG system. "
                    "Answer using the provided document context first. "
                    "If the context is insufficient, say what is missing clearly."
                ),
            }
        ]
        for item in history[-6:]:
            conversation.append({"role": item.role, "content": item.content})
        conversation.append(
            {
                "role": "user",
                "content": f"Context:\n{context}\n\nQuestion:\n{user_message}",
            }
        )
        return conversation

    def _make_cache_key(self, message: str, provider_config: ProviderConfig, context: str) -> str:
        raw = json.dumps(
            {
                "message": message,
                "provider": provider_config.provider,
                "model": provider_config.model,
                "context": context,
            },
            sort_keys=True,
        )
        digest = hashlib.sha256(raw.encode("utf-8")).hexdigest()
        return f"rag:chat:{digest}"

    def _cache_get(self, cache_key: str) -> str | None:
        try:
            return self.redis.get(cache_key)
        except RedisError:
            return None

    def _cache_set(self, cache_key: str, answer: str) -> None:
        try:
            self.redis.setex(cache_key, settings.cache_ttl_seconds, answer)
        except RedisError:
            return None
