# core/database.py - FIXED VERSION
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
        """Initialize ChromaDB vector store - FIXED"""
        # Always create the directory if it doesn't exist
        os.makedirs(settings.db_location, exist_ok=True)
        
        # Initialize Chroma - this will create or connect to existing
        self.vector_store = Chroma(
            collection_name=settings.collection_name,
            persist_directory=settings.db_location,
            embedding_function=self.embeddings,
        )
        print(f"✅ Vector store initialized at {settings.db_location}")
    
    def add_documents(self, documents):
        """Add documents to vector store - FIXED"""
        if not documents:
            print("⚠️ No documents to add")
            return 0
        
        print(f"📝 Adding {len(documents)} documents to vector store...")
        
        try:
            # Use from_documents to properly create the collection
            if self.get_document_count() == 0:
                # First time - create collection with documents
                self.vector_store = Chroma.from_documents(
                    documents=documents,
                    embedding=self.embeddings,
                    persist_directory=settings.db_location,
                    collection_name=settings.collection_name
                )
            else:
                # Add to existing collection
                self.vector_store.add_documents(documents)
            
            # Persist changes
            self.vector_store.persist()
            
            new_count = self.get_document_count()
            print(f"✅ Successfully added documents. Total now: {new_count}")
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
    
    def test_search(self, query: str = "laptop", k: int = 2):
        """Test search functionality"""
        try:
            results = self.vector_store.similarity_search(query, k=k)
            print(f"🔍 Test search for '{query}': Found {len(results)} documents")
            for i, doc in enumerate(results):
                print(f"   {i+1}. {doc.page_content[:100]}...")
            return results
        except Exception as e:
            print(f"❌ Search test failed: {e}")
            return []

# Global instance
vector_db = VectorDatabase()