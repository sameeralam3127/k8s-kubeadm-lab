# debug_database.py
from core.database import vector_db
from utils.parser import FAQParser

# Test parser
print("Testing FAQ parser...")
docs = FAQParser.parse_faq_file("docs/complete_internal_knowledge_base.txt")
print(f"Parser found: {len(docs)} documents")

if docs:
    print("Sample document:")
    print(docs[0].page_content[:200] + "...")

# Test database
print("\nTesting database...")
count = vector_db.get_document_count()
print(f"Database has: {count} documents")

# Test search
if count > 0:
    test_docs = vector_db.vector_store.similarity_search("laptop", k=2)
    print(f"Search found: {len(test_docs)} documents")