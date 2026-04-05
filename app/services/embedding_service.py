import httpx

from app.core.config import get_settings


settings = get_settings()


class EmbeddingService:
    def __init__(self) -> None:
        self.timeout = settings.request_timeout_seconds

    async def embed_texts(self, texts: list[str], model: str | None = None) -> list[list[float]]:
        embed_model = model or settings.default_embedding_model
        embeddings: list[list[float]] = []
        async with httpx.AsyncClient(timeout=self.timeout) as client:
            for text in texts:
                response = await self._call_embed_endpoint(client, embed_model, text)
                embeddings.append(response)
        return embeddings

    async def embed_query(self, text: str, model: str | None = None) -> list[float]:
        return (await self.embed_texts([text], model=model))[0]

    async def _call_embed_endpoint(
        self,
        client: httpx.AsyncClient,
        model: str,
        text: str,
    ) -> list[float]:
        payloads = (
            ("/api/embed", {"model": model, "input": text}),
            ("/api/embeddings", {"model": model, "prompt": text}),
        )
        for path, payload in payloads:
            response = await client.post(f"{settings.ollama_base_url}{path}", json=payload)
            if response.is_success:
                data = response.json()
                if "embeddings" in data:
                    return data["embeddings"][0]
                if "embedding" in data:
                    return data["embedding"]
        raise RuntimeError("Unable to create embeddings from Ollama. Check the embedding model and Ollama service.")
