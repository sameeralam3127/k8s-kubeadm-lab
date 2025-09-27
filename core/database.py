import os
from langchain_ollama import OllamaEmbeddings
from langchain_chroma import Chroma
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
        if not os.path.exists(settings.db_location):
            os.makedirs(settings.db_location, exist_ok=True)
        
        self.vector_store = Chroma(
            collection_name=settings.collection_name,
            persist_directory=settings.db_location,
            embedding_function=self.embeddings,
        )
    
    def get_retriever(self):
        """Get configured retriever"""
        return self.vector_store.as_retriever(
            search_type=settings.retriever_mode,
            search_kwargs={"k": settings.retriever_k}
        )
    
    def add_documents(self, documents):
        """Add documents to vector store"""
        if documents:
            self.vector_store.add_documents(documents)
            return len(documents)
        return 0
    
    def get_document_count(self):
        """Get total number of documents"""
        return self.vector_store._collection.count()

# Global instance
vector_db = VectorDatabase()