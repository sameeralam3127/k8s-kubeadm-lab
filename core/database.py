from langchain_ollama import OllamaEmbeddings
from langchain_chroma import Chroma
from langchain.text_splitter import RecursiveCharacterTextSplitter
from config.settings import settings
import os

class VectorDatabase:
    def __init__(self):
        self.embeddings = OllamaEmbeddings(
            model=settings.embed_model,
            base_url=settings.ollama_base_url
        )
        self.vector_store = None
        self._initialize_db()
    
    def _initialize_db(self):
        """Initialize or connect to ChromaDB"""
        self.vector_store = Chroma(
            collection_name=settings.collection_name,
            persist_directory=settings.db_location,
            embedding_function=self.embeddings,
        )
    
    def get_retriever(self):
        """Get configured retriever with optimizations"""
        return self.vector_store.as_retriever(
            search_type=settings.retriever_mode,
            search_kwargs={
                "k": settings.retriever_k,
                "fetch_k": min(50, settings.retriever_k * 3),  # Better MMR
                "lambda_mult": settings.mmr_diversity
            }
        )

# Singleton instance
vector_db = VectorDatabase()