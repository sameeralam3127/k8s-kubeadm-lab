from typing import Any, Literal

from pydantic import BaseModel, Field


class HealthResponse(BaseModel):
    status: str
    ollama_base_url: str
    chroma_collection: str


class OllamaModelItem(BaseModel):
    name: str
    size: int | None = None
    modified_at: str | None = None


class OllamaModelsResponse(BaseModel):
    models: list[OllamaModelItem]


class DocumentUploadResponse(BaseModel):
    filename: str
    chunks_indexed: int
    collection_name: str


class ReindexResponse(BaseModel):
    indexed_files: int
    indexed_chunks: int


class ProviderConfig(BaseModel):
    provider: Literal["ollama", "openai_compatible"] = "ollama"
    model: str | None = None
    api_key: str | None = None
    base_url: str | None = None


class ChatRequest(BaseModel):
    session_id: str | None = None
    message: str = Field(min_length=1)
    provider_config: ProviderConfig = Field(default_factory=ProviderConfig)


class ChatMessageResponse(BaseModel):
    role: str
    content: str
    provider: str
    model_name: str


class SourceItem(BaseModel):
    source: str
    page: int | None = None
    preview: str


class ChatResponse(BaseModel):
    session_id: str
    answer: str
    cached: bool
    provider: str
    model_name: str
    sources: list[SourceItem]
    history: list[ChatMessageResponse]


class SessionHistoryResponse(BaseModel):
    session_id: str
    history: list[ChatMessageResponse]


class ReindexRequest(BaseModel):
    rebuild: bool = False


class ProviderPayload(BaseModel):
    base_url: str | None = None
    api_key: str | None = None
    model: str
    extra_headers: dict[str, Any] | None = None
