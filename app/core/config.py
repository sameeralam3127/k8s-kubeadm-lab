from functools import lru_cache
from pathlib import Path

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


BASE_DIR = Path(__file__).resolve().parents[2]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    app_name: str = "Ollama RAG Studio"
    app_env: str = "development"
    api_prefix: str = "/api/v1"
    admin_token: str = "change-me"
    cors_origins: list[str] = Field(
        default_factory=lambda: [
            "http://localhost:8000",
            "http://localhost:8501",
            "http://127.0.0.1:8501",
        ]
    )

    ollama_base_url: str = "http://localhost:11434"
    default_chat_model: str = "llama3.1:8b"
    default_embedding_model: str = "nomic-embed-text"

    chroma_path: str = str(BASE_DIR / "data" / "chroma")
    documents_path: str = str(BASE_DIR / "data" / "documents")
    chroma_collection: str = "ollama_rag_studio_documents"
    chunk_size: int = 1200
    chunk_overlap: int = 200
    retrieval_k: int = 4
    cache_ttl_seconds: int = 900

    postgres_url: str = "postgresql+psycopg://ollama_rag_studio:ollama_rag_studio@localhost:5432/ollama_rag_studio"
    redis_url: str = "redis://localhost:6379/0"

    request_timeout_seconds: int = 180


@lru_cache
def get_settings() -> Settings:
    settings = Settings()
    Path(settings.documents_path).mkdir(parents=True, exist_ok=True)
    Path(settings.chroma_path).mkdir(parents=True, exist_ok=True)
    return settings
