from pydantic import BaseModel, Field
from typing import List, Dict, Any, Optional
from enum import Enum

class MessageRole(str, Enum):
    USER = "user"
    ASSISTANT = "assistant"
    SYSTEM = "system"

class ChatMessage(BaseModel):
    """Schema for chat messages"""
    role: MessageRole
    content: str
    timestamp: Optional[float] = Field(default_factory=lambda: None)
    tokens: Optional[int] = None
    
    class Config:
        use_enum_values = True

class ChatHistory(BaseModel):
    """Schema for managing chat history"""
    messages: List[ChatMessage] = Field(default_factory=list)
    max_tokens: int = 4000  # Maximum context window
    
    def add_message(self, message: ChatMessage):
        """Add message and enforce token limits"""
        self.messages.append(message)
        self._enforce_token_limit()
    
    def _enforce_token_limit(self):
        """Trim history if token limit exceeded"""
        total_tokens = sum(msg.tokens or len(msg.content.split()) for msg in self.messages)
        
        while total_tokens > self.max_tokens and len(self.messages) > 1:
            removed = self.messages.pop(0)
            removed_tokens = removed.tokens or len(removed.content.split())
            total_tokens -= removed_tokens

class DocumentMetadata(BaseModel):
    """Schema for document metadata"""
    source: str
    doc_id: str
    document_type: str = "faq"
    category: Optional[str] = None
    confidence_score: Optional[float] = None
    last_updated: Optional[float] = None

class RetrievedDocument(BaseModel):
    """Schema for retrieved documents with scoring"""
    page_content: str
    metadata: DocumentMetadata
    relevance_score: float = Field(ge=0.0, le=1.0)
    retrieval_rank: int

class RetrievalResult(BaseModel):
    """Schema for retrieval operation results"""
    query: str
    documents: List[RetrievedDocument]
    total_documents: int
    retrieval_time: float
    average_score: float

class ChatResponse(BaseModel):
    """Schema for chatbot response with metadata"""
    content: str
    source_documents: List[RetrievedDocument]
    generation_time: float
    total_tokens: Optional[int] = None
    confidence: Optional[float] = None
    suggested_actions: List[str] = Field(default_factory=list)

class PerformanceMetrics(BaseModel):
    """Schema for tracking performance metrics"""
    retrieval_time: float
    generation_time: float
    total_time: float
    documents_retrieved: int
    average_relevance_score: float
    tokens_generated: Optional[int] = None
    
    @property
    def tokens_per_second(self) -> Optional[float]:
        if self.tokens_generated and self.generation_time > 0:
            return self.tokens_generated / self.generation_time
        return None

class UserQuery(BaseModel):
    """Schema for analyzing user queries"""
    original_text: str
    processed_text: str
    intent: str
    category: Optional[str] = None
    urgency: str = "normal"  # low, normal, high
    requires_follow_up: bool = False
    entities: List[str] = Field(default_factory=list)

class AppConfig(BaseModel):
    """Schema for application configuration validation"""
    model_name: str
    embedding_model: str
    retriever_k: int = Field(ge=1, le=20)
    temperature: float = Field(ge=0.0, le=1.0)
    max_tokens: int = Field(ge=50, le=2000)
    
    def validate_config(self):
        """Validate configuration values"""
        if self.retriever_k > 15:
            raise ValueError("retriever_k should be <= 15 for performance")
        if self.temperature > 0.5:
            raise ValueError("Temperature should be <= 0.5 for business applications")