# core/database.py - UPDATED
import os
from langchain_ollama import OllamaEmbeddings
from langchain_chroma import Chroma
from langchain_core.documents import Document
from config.settings import settings

class VectorDatabase:
    def __init__(self):
        self.embeddings = OllamaEmbeddings(
            model=settings.embed_model,
            base_url=settings.ollama_base_url
        )
        self.vector_store = None
        self._initialize_db()
    
    def _initialize_db(self):
        """Initialize ChromaDB vector store with better error handling"""
        try:
            # Ensure directory exists
            os.makedirs(settings.db_location, exist_ok=True)
            
            # Initialize Chroma
            self.vector_store = Chroma(
                collection_name=settings.collection_name,
                persist_directory=settings.db_location,
                embedding_function=self.embeddings,
            )
            
            print(f"✅ Vector store initialized at {settings.db_location}")
            
        except Exception as e:
            print(f"❌ Vector store initialization failed: {e}")
            raise
    
    def get_document_count(self):
        """Get total number of documents"""
        try:
            if self.vector_store and hasattr(self.vector_store, '_collection'):
                return self.vector_store._collection.count()
            return 0
        except Exception as e:
            print(f"❌ Error getting document count: {e}")
            return 0
    
    def get_retriever(self):
        """Get configured retriever"""
        return self.vector_store.as_retriever(
            search_type=settings.retriever_mode,
            search_kwargs={"k": settings.retriever_k}
        )
    
    def health_check(self):
        """Perform health check on the database"""
        try:
            count = self.get_document_count()
            can_search = len(self.vector_store.similarity_search("test", k=1)) >= 0
            return {
                "healthy": count > 0 and can_search,
                "document_count": count,
                "search_working": can_search
            }
        except Exception as e:
            return {
                "healthy": False,
                "error": str(e)
            }

# Global instance
vector_db = VectorDatabase()