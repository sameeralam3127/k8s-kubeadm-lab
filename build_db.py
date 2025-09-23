import os
from langchain_ollama import OllamaEmbeddings
from langchain_chroma import Chroma
from langchain_core.documents import Document

db_location = "./chroma_ops_db"
embeddings = OllamaEmbeddings(model="mxbai-embed-large")

if not os.path.exists(db_location):
    print("Building database from FAQ file...")
    docs = []

    with open("f2442acc-5c9d-46ed-a05b-f581e7484aa2.txt", "r", encoding="utf-8") as f:
        content = f.read()

    # Split by Q: for FAQs
    faqs = content.split("Q:")
    for i, faq in enumerate(faqs[1:], start=1):
        parts = faq.strip().split("A:")
        if len(parts) == 2:
            q, a = parts
            docs.append(Document(page_content=f"Q: {q.strip()} A: {a.strip()}", metadata={"id": str(i)}))

    vector_store = Chroma(
        collection_name="business_ops",
        persist_directory=db_location,
        embedding_function=embeddings
    )
    vector_store.add_documents(docs)
    print("✅ Business operations FAQ DB created!")
else:
    print("Database already exists, skipping.")
