import os
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
    retriever_k: int = 8
    retriever_mode: str = "similarity"
    
    # FAQ Source
    faq_file: str = "docs/complete_internal_knowledge_base.txt"
    
    # App Settings
    max_history_messages: int = 6
    enable_debug: bool = False

    class Config:
        env_file = ".env"

settings = Settings()