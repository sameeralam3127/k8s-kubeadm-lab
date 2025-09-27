import re
import time
import hashlib
import logging
from typing import List, Dict, Any, Optional, Tuple, Callable
from functools import wraps
from datetime import datetime

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

def timing_decorator(func: Callable) -> Callable:
    """Decorator to measure function execution time"""
    @wraps(func)
    def wrapper(*args, **kwargs):
        start_time = time.time()
        result = func(*args, **kwargs)
        end_time = time.time()
        execution_time = end_time - start_time
        
        logger.info(f"⏱️ {func.__name__} executed in {execution_time:.4f} seconds")
        return result, execution_time
    return wrapper

def retry_on_exception(max_retries: int = 3, delay: float = 1.0):
    """Retry decorator for handling transient errors"""
    def decorator(func: Callable):
        @wraps(func)
        def wrapper(*args, **kwargs):
            for attempt in range(max_retries):
                try:
                    return func(*args, **kwargs)
                except Exception as e:
                    if attempt == max_retries - 1:
                        raise e
                    logger.warning(f"Attempt {attempt + 1} failed: {str(e)}. Retrying...")
                    time.sleep(delay * (attempt + 1))
            return None
        return wrapper
    return decorator

class TextProcessor:
    """Text processing utilities"""
    
    @staticmethod
    def clean_text(text: str) -> str:
        """Clean and normalize text"""
        if not text:
            return ""
        
        # Remove extra whitespace
        text = re.sub(r'\s+', ' ', text)
        
        # Remove special characters but keep punctuation
        text = re.sub(r'[^\w\s.,!?;:]', '', text)
        
        return text.strip()
    
    @staticmethod
    def estimate_tokens(text: str) -> int:
        """Estimate token count (simple word-based approach)"""
        if not text:
            return 0
        return len(text.split())
    
    @staticmethod
    def truncate_text(text: str, max_tokens: int) -> str:
        """Truncate text to maximum token count"""
        words = text.split()
        if len(words) <= max_tokens:
            return text
        return ' '.join(words[:max_tokens]) + "..."
    
    @staticmethod
    def extract_keywords(text: str, max_keywords: int = 10) -> List[str]:
        """Extract important keywords from text"""
        words = text.lower().split()
        # Remove stopwords (basic list - extend as needed)
        stopwords = {'the', 'a', 'an', 'and', 'or', 'but', 'in', 'on', 'at', 'to', 'for', 'of', 'with', 'by'}
        keywords = [word for word in words if word not in stopwords and len(word) > 2]
        
        # Get unique keywords
        return list(dict.fromkeys(keywords))[:max_keywords]

class QueryAnalyzer:
    """Analyze user queries for better processing"""
    
    # Define categories and keywords
    CATEGORIES = {
        'it_support': ['computer', 'email', 'password', 'software', 'network', 'printer', 'login'],
        'hr_policies': ['vacation', 'leave', 'policy', 'benefits', 'salary', 'holiday', 'timeoff'],
        'onboarding': ['new', 'onboard', 'orientation', 'training', 'welcome', 'setup'],
        'facilities': ['office', 'desk', 'meeting', 'room', 'key', 'access', 'parking']
    }
    
    @classmethod
    def categorize_query(cls, query: str) -> Tuple[str, float]:
        """Categorize query and return confidence score"""
        query_lower = query.lower()
        best_category = 'general'
        best_score = 0.0
        
        for category, keywords in cls.CATEGORIES.items():
            score = sum(1 for keyword in keywords if keyword in query_lower) / len(keywords)
            if score > best_score:
                best_score = score
                best_category = category
        
        return best_category, best_score
    
    @classmethod
    def detect_urgency(cls, query: str) -> str:
        """Detect query urgency level"""
        urgent_keywords = ['urgent', 'emergency', 'immediately', 'asap', 'broken', 'not working']
        query_lower = query.lower()
        
        if any(keyword in query_lower for keyword in urgent_keywords):
            return 'high'
        elif 'help' in query_lower or 'problem' in query_lower:
            return 'normal'
        return 'low'

class ResponseFormatter:
    """Format responses for better readability"""
    
    @staticmethod
    def format_bullet_points(text: str) -> str:
        """Convert list-like text to bullet points"""
        lines = text.split('\n')
        bullet_points = []
        
        for line in lines:
            line = line.strip()
            if line and not line.startswith('- ') and not line.startswith('* '):
                bullet_points.append(f"• {line}")
            else:
                bullet_points.append(line)
        
        return '\n'.join(bullet_points)
    
    @staticmethod
    def highlight_important(text: str, important_phrases: List[str]) -> str:
        """Highlight important phrases in text (for display)"""
        for phrase in important_phrases:
            text = text.replace(phrase, f"**{phrase}**")
        return text
    
    @staticmethod
    def create_suggested_actions(query_category: str) -> List[str]:
        """Create context-aware suggested actions"""
        actions = {
            'it_support': [
                "Contact IT Help Desk: ext. 4357",
                "Submit a ticket via ServiceNow",
                "Visit the IT self-service portal"
            ],
            'hr_policies': [
                "Check the employee handbook",
                "Contact HR: hr@company.com",
                "Schedule meeting with your manager"
            ],
            'onboarding': [
                "Contact onboarding team",
                "Check onboarding checklist",
                "Schedule equipment setup"
            ],
            'facilities': [
                "Submit facilities request",
                "Contact front desk: ext. 4000",
                "Check room booking system"
            ],
            'general': [
                "Check company intranet",
                "Contact your manager",
                "Visit the help center"
            ]
        }
        
        return actions.get(query_category, actions['general'])

class CacheManager:
    """Simple cache management for frequent queries"""
    
    def __init__(self, max_size: int = 100):
        self.cache = {}
        self.max_size = max_size
        self.access_times = {}
    
    def generate_key(self, query: str) -> str:
        """Generate cache key from query"""
        return hashlib.md5(query.encode()).hexdigest()
    
    def get(self, key: str) -> Optional[Any]:
        """Get value from cache"""
        if key in self.cache:
            self.access_times[key] = time.time()
            return self.cache[key]
        return None
    
    def set(self, key: str, value: Any):
        """Set value in cache with size management"""
        if len(self.cache) >= self.max_size:
            # Remove least recently used item
            oldest_key = min(self.access_times, key=self.access_times.get)
            del self.cache[oldest_key]
            del self.access_times[oldest_key]
        
        self.cache[key] = value
        self.access_times[key] = time.time()
    
    def clear(self):
        """Clear entire cache"""
        self.cache.clear()
        self.access_times.clear()

def validate_email(email: str) -> bool:
    """Validate email format"""
    pattern = r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
    return bool(re.match(pattern, email))

def safe_get(dictionary: Dict, keys: List[str], default: Any = None) -> Any:
    """Safely get nested dictionary values"""
    current = dictionary
    for key in keys:
        if isinstance(current, dict) and key in current:
            current = current[key]
        else:
            return default
    return current

def format_timestamp(timestamp: Optional[float] = None) -> str:
    """Format timestamp for display"""
    if timestamp is None:
        timestamp = time.time()
    return datetime.fromtimestamp(timestamp).strftime("%Y-%m-%d %H:%M:%S")

def calculate_confidence_score(query: str, document_content: str) -> float:
    """Calculate confidence score for retrieval results"""
    query_words = set(query.lower().split())
    doc_words = set(document_content.lower().split())
    
    if not query_words:
        return 0.0
    
    intersection = query_words.intersection(doc_words)
    return len(intersection) / len(query_words)

# Global instances for easy access
text_processor = TextProcessor()
query_analyzer = QueryAnalyzer()
response_formatter = ResponseFormatter()
cache_manager = CacheManager()