# utils/parser.py - FIXED FOR YOUR FORMAT
import re
import os
from typing import List
from langchain_core.documents import Document
from utils.helpers import logger

class FAQParser:
    """Parser optimized for your specific FAQ format"""
    
    @staticmethod
    def parse_faq_file(file_path: str) -> List[Document]:
        """Parse your specific FAQ format with sections"""
        if not os.path.exists(file_path):
            raise FileNotFoundError(f"FAQ file not found: {file_path}")
        
        with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
        
        logger.info(f"📄 Parsing FAQ file: {file_path} (Size: {len(content)} chars)")
        
        # Your file has sections like "1. IT & Technical Support"
        # Then subsections like "1.1. Hardware Requests & Issues"
        # Then Q: A: pairs
        
        documents = []
        current_section = "General"
        current_subsection = "General"
        
        lines = content.split('\n')
        i = 0
        
        while i < len(lines):
            line = lines[i].strip()
            
            # Detect section headers (e.g., "1. IT & Technical Support")
            if re.match(r'^\d+\.\s+[A-Za-z& ]+', line):
                current_section = re.sub(r'^\d+\.\s+', '', line)
                i += 1
                continue
            
            # Detect subsection headers (e.g., "1.1. Hardware Requests & Issues")
            elif re.match(r'^\d+\.\d+\.\s+[A-Za-z& ]+', line):
                current_subsection = re.sub(r'^\d+\.\d+\.\s+', '', line)
                i += 1
                continue
            
            # Detect Q: A: pairs
            elif line.startswith('Q:'):
                # Extract question
                question = line[2:].strip()
                
                # Look ahead for multi-line questions
                j = i + 1
                while j < len(lines) and not lines[j].strip().startswith('A:'):
                    if lines[j].strip():
                        question += " " + lines[j].strip()
                    j += 1
                
                # Extract answer
                if j < len(lines) and lines[j].strip().startswith('A:'):
                    answer = lines[j][2:].strip()
                    k = j + 1
                    while k < len(lines) and not lines[k].strip().startswith('Q:') and not re.match(r'^\d+\.', lines[k].strip()):
                        if lines[k].strip():
                            answer += " " + lines[k].strip()
                        k += 1
                    
                    # Create document with metadata
                    text = f"Q: {question}\nA: {answer}"
                    documents.append(Document(
                        page_content=text,
                        metadata={
                            "section": current_section,
                            "subsection": current_subsection,
                            "source": "knowledge_base",
                            "id": f"doc_{len(documents)+1}"
                        }
                    ))
                    
                    i = k - 1  # Skip processed lines
                else:
                    i = j
            else:
                i += 1
        
        logger.info(f"✅ Parsed {len(documents)} Q/A pairs from {current_section} sections")
        return documents

# Alternative simpler parser if above doesn't work
class SimpleFAQParser:
    """Simpler parser as backup"""
    
    @staticmethod
    def parse_faq_file(file_path: str) -> List[Document]:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        documents = []
        
        # Simple regex that should work with your format
        pattern = r'Q:\s*(.*?)\s*A:\s*(.*?)(?=\nQ:|\n\d+\.|\n\n|$)'
        matches = re.findall(pattern, content, re.DOTALL)
        
        for i, (question, answer) in enumerate(matches):
            if question.strip() and answer.strip():
                # Clean up whitespace
                question = ' '.join(question.split())
                answer = ' '.join(answer.split())
                
                text = f"Q: {question}\nA: {answer}"
                documents.append(Document(
                    page_content=text,
                    metadata={"id": f"qa_{i+1}", "source": "knowledge_base"}
                ))
        
        logger.info(f"✅ Simple parser found {len(documents)} Q/A pairs")
        return documents