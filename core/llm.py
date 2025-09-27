from langchain_ollama.llms import OllamaLLM
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import StrOutputParser
from config.settings import settings

class BusinessChatbot:
    def __init__(self):
        self.model = OllamaLLM(
            model=settings.ollama_model,
            base_url=settings.ollama_base_url,
            temperature=0.1,
            num_predict=400
        )
        self.chain = self._create_chain()
    
    def _create_chain(self):
        prompt_template = """
You are a helpful Business Operations Assistant. Use the provided context to answer questions.

CONTEXT:
{docs}

CONVERSATION HISTORY:
{history}

USER QUESTION: {question}

INSTRUCTIONS:
- Answer based ONLY on the context provided
- If the answer isn't in the context, politely say so
- Be concise and helpful
- Suggest relevant contacts if you can't answer

ANSWER:
"""
        prompt = ChatPromptTemplate.from_template(prompt_template)
        return prompt | self.model | StrOutputParser()
    
    def generate_response(self, question: str, docs: List, history: List):
        """Generate response with context"""
        docs_text = "\n\n".join([doc.page_content for doc in docs[:4]])
        history_text = "\n".join([
            f"{msg['role']}: {msg['content']}" 
            for msg in history[-settings.max_history_messages:]
        ])
        
        return self.chain.invoke({
            "question": question,
            "docs": docs_text,
            "history": history_text
        })

# Global instance
chatbot = BusinessChatbot()