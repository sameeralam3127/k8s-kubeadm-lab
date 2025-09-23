import os
import subprocess
from langchain_ollama import OllamaEmbeddings
from langchain_chroma import Chroma
from langchain_core.documents import Document

FAQ_FILE = "f2442acc-5c9d-46ed-a05b-f581e7484aa2.txt"
DB_LOCATION = "./chroma_ops_db"
COLLECTION_NAME = "business_ops"

def build_db():
    """Build Chroma vector DB from FAQ file if not already built."""
    if os.path.exists(DB_LOCATION):
        print("✅ Database already exists, skipping build.")
        return

    print("📂 Building Business Operations database...")
    embeddings = OllamaEmbeddings(model="mxbai-embed-large")
    docs = []

    with open(FAQ_FILE, "r", encoding="utf-8") as f:
        content = f.read()

    # Split by "Q:" (basic FAQ parsing)
    faqs = content.split("Q:")
    for i, faq in enumerate(faqs[1:], start=1):
        parts = faq.strip().split("A:")
        if len(parts) == 2:
            q, a = parts
            docs.append(
                Document(page_content=f"Q: {q.strip()} A: {a.strip()}",
                         metadata={"id": str(i)})
            )

    vector_store = Chroma(
        collection_name=COLLECTION_NAME,
        persist_directory=DB_LOCATION,
        embedding_function=embeddings
    )
    vector_store.add_documents(docs)
    print("✅ Database created and persisted!")

def run_app():
    """Launch the Streamlit chatbot."""
    print("🚀 Starting Streamlit app...")
    subprocess.run(["streamlit", "run", "app.py"])

if __name__ == "__main__":
    build_db()
    run_app()
