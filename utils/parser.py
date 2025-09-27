import re
from typing import List
from langchain_core.documents import Document

class FAQParser:
    """Advanced FAQ parser with better error handling"""
    
    @staticmethod
    def parse_faq_file(file_path: str) -> List[Document]:
        """Parse FAQ file with multiple format support"""
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # Try multiple parsing strategies
        documents = []
        
        # Strategy 1: Q: A: format
        documents.extend(FAQParser._parse_qa_format(content))
        
        # Strategy 2: Numbered questions
        if not documents:
            documents.extend(FAQParser._parse_numbered_format(content))
            
        return documents
    
    @staticmethod
    def _parse_qa_format(content: str) -> List[Document]:
        """Parse Q: A: format"""
        documents = []
        pattern = r'Q:\s*(.*?)\s*A:\s*(.*?)(?=\nQ:|\n\d+\.|\n\n|$)'
        
        matches = re.findall(pattern, content, re.DOTALL)
        for i, (question, answer) in enumerate(matches):
            if question.strip() and answer.strip():
                text = f"Q: {question.strip()}\nA: {answer.strip()}"
                documents.append(Document(
                    page_content=text,
                    metadata={"source": "faq", "id": f"qa_{i+1}"}
                ))
                
        return documents
    
    @staticmethod
    def _parse_numbered_format(content: str) -> List[Document]:
        """Parse numbered question format"""
        documents = []
        pattern = r'(\d+)\.\s*(.*?)\n\s*Answer:\s*(.*?)(?=\n\d+\.|\n\n|$)'
        
        matches = re.findall(pattern, content, re.DOTALL)
        for num, question, answer in matches:
            if question.strip() and answer.strip():
                text = f"Q: {question.strip()}\nA: {answer.strip()}"
                documents.append(Document(
                    page_content=text,
                    metadata={"source": "faq", "id": f"num_{num}"}
                ))
                
        return documents