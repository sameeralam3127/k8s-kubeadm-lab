from pydantic import BaseModel
from typing import List, Optional
from enum import Enum

class MessageRole(str, Enum):
    USER = "user"
    ASSISTANT = "assistant"

class ChatMessage(BaseModel):
    role: MessageRole
    content: str

class RetrievedDocument(BaseModel):
    content: str
    metadata: dict
    score: float

class RetrievalResult(BaseModel):
    query: str
    documents: List[RetrievedDocument]
    total_found: int