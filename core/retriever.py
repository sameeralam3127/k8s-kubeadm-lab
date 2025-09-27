# core/retriever.py - UPDATED FOR LANGCHAIN 0.1.46+
from langchain.retrievers import ContextualCompressionRetriever
from langchain.retrievers.document_compressors import LLMChainExtractor
from langchain_core.retrievers import BaseRetriever
from langchain_core.documents import Document
from langchain_core.callbacks import CallbackManagerForRetrieverRun
from typing import List, Optional
from core.llm import chatbot
from core.database import vector_db
from utils.helpers import QueryAnalyzer, text_processor
import re

class EnhancedRetriever(BaseRetriever):
    """Enhanced retriever with query expansion and relevance scoring"""
    
    def __init__(self):
        super().__init__()
        self.base_retriever = vector_db.get_retriever()
        self.query_analyzer = QueryAnalyzer()
        
    def _get_relevant_documents(
        self, 
        query: str, 
        *, 
        run_manager: CallbackManagerForRetrieverRun
    ) -> List[Document]:
        """Main retrieval method (new LangChain syntax)"""
        try:
            # Expand query for better retrieval
            expanded_queries = self.expand_query(query)
            
            all_docs = []
            for expanded_query in expanded_queries:
                # Use invoke() instead of deprecated get_relevant_documents()
                docs = self.base_retriever.invoke(expanded_query)
                all_docs.extend(docs)
            
            # Remove duplicates and score documents
            unique_docs = self._remove_duplicates(all_docs)
            scored_docs = self._score_documents(query, unique_docs)
            
            # Return top documents
            return scored_docs[:8]  # Increased limit for better recall
            
        except Exception as e:
            print(f"Retrieval error: {e}")
            return []
    
    def expand_query(self, original_query: str) -> List[str]:
        """Expand query with synonyms and related terms"""
        expansions = [original_query]
        
        # Query categorization for better expansion
        category, confidence = self.query_analyzer.categorize_query(original_query)
        
        # Add category-specific expansions
        expansion_map = {
            'it_support': [
                "technical issue", "computer problem", "IT help", 
                "software issue", "hardware problem", "troubleshoot"
            ],
            'hr_policies': [
                "company policy", "employee handbook", "HR question",
                "benefits information", "vacation policy"
            ],
            'onboarding': [
                "new employee", "orientation process", "getting started",
                "training materials", "welcome package"
            ],
            'facilities': [
                "office equipment", "meeting room", "facility issue",
                "building access", "office supplies"
            ]
        }
        
        if category in expansion_map:
            expansions.extend(expansion_map[category][:2])  # Add top 2 expansions
        
        return expansions
    
    def _remove_duplicates(self, documents: List[Document]) -> List[Document]:
        """Remove duplicate documents based on content"""
        seen_content = set()
        unique_docs = []
        
        for doc in documents:
            content_hash = hash(doc.page_content[:200])  # Hash first 200 chars
            if content_hash not in seen_content:
                seen_content.add(content_hash)
                unique_docs.append(doc)
        
        return unique_docs
    
    def _score_documents(self, query: str, documents: List[Document]) -> List[Document]:
        """Score documents by relevance to query"""
        scored_docs = []
        query_lower = query.lower()
        query_words = set(query_lower.split())
        
        for doc in documents:
            score = self._calculate_relevance_score(query_words, doc.page_content)
            
            # Add score to metadata for debugging
            doc.metadata = doc.metadata or {}
            doc.metadata["relevance_score"] = score
            
            scored_docs.append((doc, score))
        
        # Sort by score descending
        scored_docs.sort(key=lambda x: x[1], reverse=True)
        return [doc for doc, score in scored_docs]
    
    def _calculate_relevance_score(self, query_words: set, content: str) -> float:
        """Calculate relevance score between query and content"""
        if not query_words:
            return 0.0
        
        content_lower = content.lower()
        content_words = set(content_lower.split())
        
        # Basic word overlap
        overlap = len(query_words.intersection(content_words))
        base_score = overlap / len(query_words)
        
        # Boost score if query words appear in question part
        if "Q:" in content:
            q_part, a_part = content.split("A:", 1) if "A:" in content else (content, "")
            q_score = sum(1 for word in query_words if word in q_part.lower()) / len(query_words)
            base_score = max(base_score, q_score * 1.2)  # Boost question matches
        
        return min(base_score, 1.0)
    
    # Add invoke method for compatibility
    def invoke(self, query: str) -> List[Document]:
        """Public method to invoke retrieval"""
        from langchain_core.callbacks import CallbackManagerForRetrieverRun
        return self._get_relevant_documents(query, run_manager=CallbackManagerForRetrieverRun)

# Global instance
enhanced_retriever = EnhancedRetriever()