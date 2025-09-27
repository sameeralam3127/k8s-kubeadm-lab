from langchain_ollama.llms import OllamaLLM
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import StrOutputParser
from langchain.schema import BaseRetriever
from config.settings import settings
import re

class EnhancedBusinessChatbot:
    def __init__(self):
        self.model = OllamaLLM(
            model=settings.ollama_model,
            base_url=settings.ollama_base_url,
            temperature=0.1,  # Lower for more consistent answers
            num_predict=512,  # Limit response length
            top_k=20,
            top_p=0.9
        )
        self.chain = self._create_chain()
    
    def _create_chain(self):
        """Create optimized RAG chain"""
        prompt_template = """
You are a precise Business Operations Assistant. Use ONLY the provided context.

CONTEXT:
{docs}

CONVERSATION HISTORY:
{history}

USER QUESTION: {question}

INSTRUCTIONS:
1. Answer strictly based on context - if answer isn't there, say so
2. Be concise but helpful
3. If unsure, suggest contacting relevant department
4. Format responses clearly with bullet points when helpful
5. Keep responses under 150 words

ANSWER:
"""
        prompt = ChatPromptTemplate.from_template(prompt_template)
        return prompt | self.model | StrOutputParser()
    
    def _format_history(self, messages: list, max_tokens: int = 1000):
        """Optimize history to avoid token overflow"""
        history_text = ""
        token_count = 0
        
        for msg in reversed(messages[:-1]):  # Exclude current question
            msg_text = f"{msg['role'].capitalize()}: {msg['content']}\n"
            msg_tokens = len(msg_text.split())
            
            if token_count + msg_tokens > max_tokens:
                break
                
            history_text = msg_text + history_text
            token_count += msg_tokens
            
        return history_text.strip()

    def generate_response(self, question: str, docs: list, history: list):
        """Generate response with optimized context"""
        formatted_history = self._format_history(history)
        docs_text = "\n\n".join([doc.page_content for doc in docs][:5])  # Limit docs
        
        return self.chain.invoke({
            "question": question,
            "docs": docs_text,
            "history": formatted_history
        })

# Global instance
chatbot = EnhancedBusinessChatbot()