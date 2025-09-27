# core/database.py - FIXED
import os
from langchain_ollama import OllamaEmbeddings
from langchain_chroma import Chroma
from langchain_core.documents import Document  # ADD THIS IMPORT
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
        """Initialize ChromaDB vector store"""
        # Always create the directory if it doesn't exist
        os.makedirs(settings.db_location, exist_ok=True)
        
        # Initialize Chroma
        self.vector_store = Chroma(
            collection_name=settings.collection_name,
            persist_directory=settings.db_location,
            embedding_function=self.embeddings,
        )
    
    def add_documents(self, documents):
        """Add documents to vector store"""
        if not documents:
            print("⚠️ No documents to add")
            return 0
        
        try:
            # Add documents to existing collection
            self.vector_store.add_documents(documents)
            return len(documents)
        except Exception as e:
            print(f"❌ Error adding documents: {e}")
            return 0
    
    def get_document_count(self):
        """Get total number of documents"""
        try:
            return self.vector_store._collection.count()
        except:
            return 0
    
    def get_retriever(self):
        """Get configured retriever"""
        return self.vector_store.as_retriever(
            search_type=settings.retriever_mode,
            search_kwargs={"k": settings.retriever_k}
        )

# Global instance
vector_db = VectorDatabase()