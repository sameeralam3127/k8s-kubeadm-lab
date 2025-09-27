from langchain_core.retrievers import BaseRetriever
from langchain_core.documents import Document
from typing import List
from core.database import vector_db
from utils.helpers import query_analyzer

class EnhancedRetriever(BaseRetriever):
    def __init__(self):
        super().__init__()
        self.retriever = vector_db.get_retriever()
    
    def _get_relevant_documents(self, query: str, **kwargs) -> List[Document]:
        """Retrieve relevant documents with query expansion"""
        try:
            # Expand query based on category
            category, score = query_analyzer.categorize_query(query)
            expanded_queries = self._expand_query(query, category)
            
            all_docs = []
            for exp_query in expanded_queries:
                docs = self.retriever.invoke(exp_query)
                all_docs.extend(docs)
            
            # Remove duplicates and return
            return self._remove_duplicates(all_docs)[:6]
            
        except Exception as e:
            print(f"Retrieval error: {e}")
            return []
    
    def _expand_query(self, query: str, category: str) -> List[str]:
        """Expand query with related terms"""
        expansions = [query]
        
        if category == 'it_support':
            expansions.extend(["technical issue", "computer problem"])
        elif category == 'hr_policies':
            expansions.extend(["company policy", "HR question"])
        elif category == 'facilities':
            expansions.extend(["office equipment", "meeting room issue"])
        
        return expansions
    
    def _remove_duplicates(self, documents: List[Document]) -> List[Document]:
        """Remove duplicate documents"""
        seen = set()
        unique_docs = []
        
        for doc in documents:
            content_hash = hash(doc.page_content[:100])
            if content_hash not in seen:
                seen.add(content_hash)
                unique_docs.append(doc)
        
        return unique_docs
    
    def invoke(self, query: str) -> List[Document]:
        """Public method to invoke retrieval"""
        return self._get_relevant_documents(query)

# Global instance
retriever = EnhancedRetriever()