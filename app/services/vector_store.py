from pathlib import Path
from typing import Any
from uuid import uuid4

import chromadb
from chromadb.config import Settings as ChromaSettings

from app.core.config import get_settings
from app.services.embedding_service import EmbeddingService


settings = get_settings()


class VectorStoreService:
    def __init__(self) -> None:
        self.embedding_service = EmbeddingService()
        self.client = chromadb.PersistentClient(
            path=settings.chroma_path,
            settings=ChromaSettings(anonymized_telemetry=False),
        )
        self.collection = self.client.get_or_create_collection(name=settings.chroma_collection)

    async def add_documents(self, chunks: list[dict[str, Any]]) -> int:
        if not chunks:
            return 0
        texts = [chunk["text"] for chunk in chunks]
        embeddings = await self.embedding_service.embed_texts(texts)
        ids = [str(uuid4()) for _ in chunks]
        metadatas = [chunk["metadata"] for chunk in chunks]
        self.collection.add(ids=ids, documents=texts, metadatas=metadatas, embeddings=embeddings)
        return len(chunks)

    async def similarity_search(self, query: str, limit: int | None = None) -> list[dict[str, Any]]:
        vector = await self.embedding_service.embed_query(query)
        results = self.collection.query(
            query_embeddings=[vector],
            n_results=limit or settings.retrieval_k,
        )
        matches: list[dict[str, Any]] = []
        documents = results.get("documents", [[]])[0]
        metadatas = results.get("metadatas", [[]])[0]
        distances = results.get("distances", [[]])[0]
        for doc, metadata, distance in zip(documents, metadatas, distances):
            matches.append(
                {
                    "content": doc,
                    "metadata": metadata,
                    "distance": distance,
                }
            )
        return matches

    def reset(self) -> None:
        try:
            self.client.delete_collection(settings.chroma_collection)
        except Exception:
            pass
        self.collection = self.client.get_or_create_collection(name=settings.chroma_collection)

    def ensure_storage(self) -> None:
        Path(settings.chroma_path).mkdir(parents=True, exist_ok=True)
