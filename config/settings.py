import os
from typing import Optional
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    # Ollama Settings
    ollama_model: str = "llama3.1:8b"
    ollama_base_url: str = "http://localhost:11434"
    
    # Embeddings
    embed_model: str = "mxbai-embed-large"
    
    # Vector Database
    db_location: str = "./chroma_ops_db"
    collection_name: str = "business_ops"
    
    # Retrieval Settings
    retriever_k: int = 8  # Increased for better recall
    retriever_mode: str = "mmr"  # Max Marginal Relevance for diversity
    mmr_diversity: float = 0.7  # Balance relevance/diversity
    
    # FAQ Source
    faq_file: str = "docs/complete_internal_knowledge_base.txt"
    
    # Performance
    max_history_tokens: int = 1000
    chunk_size: int = 1000
    chunk_overlap: int = 200
    
    class Config:
        env_file = ".env"

settings = Settings()