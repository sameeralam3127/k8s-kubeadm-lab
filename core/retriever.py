from langchain.retrievers import ContextualCompressionRetriever
from langchain.retrievers.document_compressors import LLMChainExtractor
from core.llm import chatbot
from core.database import vector_db

class EnhancedRetriever:
    def __init__(self):
        self.base_retriever = vector_db.get_retriever()
        self.compression_retriever = self._setup_compression()
    
    def _setup_compression(self):
        """Setup contextual compression to filter irrelevant docs"""
        compressor = LLMChainExtractor.from_llm(chatbot.model)
        return ContextualCompressionRetriever(
            base_compressor=compressor,
            base_retriever=self.base_retriever
        )
    
    def get_relevant_documents(self, query: str):
        """Get relevant documents with relevance scoring"""
        try:
            # First pass: get base results
            docs = self.base_retriever.get_relevant_documents(query)
            
            # Second pass: re-rank by relevance (simple cosine similarity)
            scored_docs = []
            for doc in docs:
                # Simple relevance scoring (you can enhance this)
                score = self._calculate_relevance_score(query, doc.page_content)
                scored_docs.append((doc, score))
            
            # Sort by score and return top ones
            scored_docs.sort(key=lambda x: x[1], reverse=True)
            return [doc for doc, score in scored_docs[:6]]  # Top 6
        
        except Exception as e:
            print(f"Retrieval error: {e}")
            return []
    
    def _calculate_relevance_score(self, query: str, content: str) -> float:
        """Simple relevance scoring based on keyword overlap"""
        query_words = set(query.lower().split())
        content_words = set(content.lower().split())
        
        if not query_words:
            return 0.0
            
        overlap = len(query_words.intersection(content_words))
        return overlap / len(query_words)

# Global instance
enhanced_retriever = EnhancedRetriever()