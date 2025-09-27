import re
import time
from typing import List, Tuple

class TextProcessor:
    @staticmethod
    def clean_text(text: str) -> str:
        return re.sub(r'\s+', ' ', text).strip()
    
    @staticmethod
    def estimate_tokens(text: str) -> int:
        return len(text.split())

class QueryAnalyzer:
    CATEGORIES = {
        'it_support': ['computer', 'laptop', 'password', 'software', 'network', 'printer', 'login', 'technical'],
        'hr_policies': ['vacation', 'leave', 'policy', 'benefits', 'salary', 'holiday', 'timeoff'],
        'facilities': ['meeting', 'room', 'office', 'equipment', 'AV', 'projector']
    }
    
    @classmethod
    def categorize_query(cls, query: str) -> Tuple[str, float]:
        query_lower = query.lower()
        best_category = 'general'
        best_score = 0.0
        
        for category, keywords in cls.CATEGORIES.items():
            matches = sum(1 for keyword in keywords if keyword in query_lower)
            score = matches / len(keywords)
            if score > best_score:
                best_score = score
                best_category = category
        
        return best_category, best_score

text_processor = TextProcessor()
query_analyzer = QueryAnalyzer()