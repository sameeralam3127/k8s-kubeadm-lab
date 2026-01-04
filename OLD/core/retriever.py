# core/retriever.py - FIXED IMPORTS
from langchain_core.documents import Document
from typing import List  # ADD THIS IMPORT
from core.database import vector_db

class SimpleRetriever:
    """Simple retriever without Pydantic inheritance"""
    
    def __init__(self):
        self.retriever = vector_db.get_retriever()
    
    def get_relevant_documents(self, query: str) -> List[Document]:
        """Retrieve relevant documents"""
        try:
            docs = self.retriever.invoke(query)
            return docs[:6]  # Return top 6 documents
        except Exception as e:
            print(f"Retrieval error: {e}")
            return []
    
    def invoke(self, query: str) -> List[Document]:
        """Public method to invoke retrieval"""
        return self.get_relevant_documents(query)

# Global instance
retriever = SimpleRetriever()