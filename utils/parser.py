import re
from typing import List
from langchain_core.documents import Document

class FAQParser:
    @staticmethod
    def parse_faq_file(file_path: str) -> List[Document]:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        documents = []
        sections = content.split('\n\n')
        
        for section in sections:
            lines = section.strip().split('\n')
            if len(lines) < 2:
                continue
                
            # Look for Q: and A: patterns
            question = None
            answer_lines = []
            
            for line in lines:
                line = line.strip()
                if line.startswith('Q:'):
                    if question and answer_lines:
                        # Save previous Q/A
                        answer = ' '.join(answer_lines)
                        documents.append(Document(
                            page_content=f"Q: {question}\nA: {answer}",
                            metadata={"source": "faq"}
                        ))
                    
                    question = line[2:].strip()
                    answer_lines = []
                    
                elif line.startswith('A:') and question:
                    answer_lines.append(line[2:].strip())
                elif answer_lines and line and not line.startswith('Q:'):
                    answer_lines.append(line)
            
            # Don't forget the last Q/A pair
            if question and answer_lines:
                answer = ' '.join(answer_lines)
                documents.append(Document(
                    page_content=f"Q: {question}\nA: {answer}",
                    metadata={"source": "faq"}
                ))
        
        return documents