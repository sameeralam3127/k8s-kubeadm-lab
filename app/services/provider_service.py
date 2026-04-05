from typing import Any

import httpx

from app.core.config import get_settings
from app.models.schemas import ProviderConfig


settings = get_settings()


class ProviderService:
    def __init__(self) -> None:
        self.timeout = settings.request_timeout_seconds

    async def generate_answer(
        self,
        *,
        provider_config: ProviderConfig,
        messages: list[dict[str, str]],
    ) -> tuple[str, str]:
        if provider_config.provider == "ollama":
            model_name = provider_config.model or settings.default_chat_model
            return await self._chat_with_ollama(model_name, messages), model_name
        model_name = provider_config.model or "gpt-4o-mini"
        return await self._chat_with_openai_compatible(provider_config, model_name, messages), model_name

    async def list_ollama_models(self) -> list[dict[str, Any]]:
        async with httpx.AsyncClient(timeout=self.timeout) as client:
            response = await client.get(f"{settings.ollama_base_url}/api/tags")
            response.raise_for_status()
            return response.json().get("models", [])

    async def _chat_with_ollama(self, model_name: str, messages: list[dict[str, str]]) -> str:
        payload = {
            "model": model_name,
            "messages": messages,
            "stream": False,
        }
        async with httpx.AsyncClient(timeout=self.timeout) as client:
            response = await client.post(f"{settings.ollama_base_url}/api/chat", json=payload)
            response.raise_for_status()
            data = response.json()
        return data["message"]["content"]

    async def _chat_with_openai_compatible(
        self,
        provider_config: ProviderConfig,
        model_name: str,
        messages: list[dict[str, str]],
    ) -> str:
        if not provider_config.base_url or not provider_config.api_key:
            raise ValueError("External providers require both base URL and API key.")

        base_url = provider_config.base_url.rstrip("/")
        if not base_url.endswith("/v1"):
            base_url = f"{base_url}/v1"

        payload = {
            "model": model_name,
            "messages": messages,
            "temperature": 0.2,
        }
        headers = {
            "Authorization": f"Bearer {provider_config.api_key}",
            "Content-Type": "application/json",
        }
        async with httpx.AsyncClient(timeout=self.timeout) as client:
            response = await client.post(f"{base_url}/chat/completions", headers=headers, json=payload)
            response.raise_for_status()
            data = response.json()
        return data["choices"][0]["message"]["content"]
