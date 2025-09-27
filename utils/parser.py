# utils/parser.py - FIXED
import re
from typing import List  # ADD THIS IMPORT
from langchain_core.documents import Document

class FAQParser:
    @staticmethod
    def parse_faq_file(file_path: str) -> List[Document]:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        documents = []
        
        # Split by Q: patterns
        qa_blocks = re.split(r'\n(?=Q:)', content)
        
        for block in qa_blocks:
            if not block.strip():
                continue
                
            # Extract Q and A
            q_match = re.search(r'Q:\s*(.*?)(?=\nA:|\n\n|$)', block, re.DOTALL)
            a_match = re.search(r'A:\s*(.*?)(?=\nQ:|\n\n|$)', block, re.DOTALL)
            
            if q_match and a_match:
                question = q_match.group(1).strip()
                answer = a_match.group(1).strip()
                
                if question and answer:
                    text = f"Q: {question}\nA: {answer}"
                    documents.append(Document(
                        page_content=text,
                        metadata={"source": "faq"}
                    ))
        
        return documents