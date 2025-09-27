# core/database.py - ENHANCED
from langchain_ollama import OllamaEmbeddings
from langchain_chroma import Chroma
from langchain.text_splitter import RecursiveCharacterTextSplitter
from config.settings import settings
import os

class VectorDatabase:
    def __init__(self):
        self.embeddings = OllamaEmbeddings(
            model=settings.embed_model
        )
        self.vector_store = None
        self._initialize_db()
    
    def _initialize_db(self):
        """Initialize or connect to ChromaDB with better error handling"""
        try:
            # Check if database exists and has content
            db_exists = (os.path.exists(settings.db_location) and 
                        os.path.isdir(settings.db_location) and 
                        len(os.listdir(settings.db_location)) > 0)
            
            if not db_exists:
                raise RuntimeError(f"Chroma DB not found or empty at {settings.db_location}. Run build.py first.")
            
            self.vector_store = Chroma(
                collection_name=settings.collection_name,
                persist_directory=settings.db_location,
                embedding_function=self.embeddings,
            )
            
            # Test the connection
            test_count = self.vector_store._collection.count()
            print(f"✅ Vector store connected with {test_count} documents")
            
        except Exception as e:
            print(f"❌ Vector store initialization failed: {e}")
            raise

# Singleton instance
vector_db = VectorDatabase()