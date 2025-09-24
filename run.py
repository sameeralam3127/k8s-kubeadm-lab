import os
import subprocess
import shutil
import re
from langchain_ollama import OllamaEmbeddings
from langchain_chroma import Chroma
from langchain_core.documents import Document

FAQ_FILE = os.getenv("FAQ_FILE", "complete_internal_knowledge_base.txt")
DB_LOCATION = os.getenv("DB_LOCATION", "./chroma_ops_db")
COLLECTION_NAME = os.getenv("COLLECTION_NAME", "business_ops")
EMBED_MODEL = os.getenv("EMBED_MODEL", "mxbai-embed-large")

def build_db(force_rebuild: bool = False):
    """Build Chroma vector DB from FAQ file."""
    if force_rebuild and os.path.exists(DB_LOCATION):
        print("♻️ Rebuilding database...")
        shutil.rmtree(DB_LOCATION)

    if os.path.exists(DB_LOCATION):
        print("✅ Database already exists, skipping build.")
        return

    if not os.path.exists(FAQ_FILE):
        raise FileNotFoundError(f"❌ FAQ file not found: {FAQ_FILE}")

    print(f"📂 Building Business Operations database from {FAQ_FILE}...")
    embeddings = OllamaEmbeddings(model=EMBED_MODEL)
    docs = []

    with open(FAQ_FILE, "r", encoding="utf-8") as f:
        content = f.read()

    # Regex-based parsing (more resilient)
    faqs = re.split(r"\n?Q:\s*", content)[1:]
    for i, faq in enumerate(faqs, start=1):
        parts = re.split(r"\n?A:\s*", faq, maxsplit=1)
        if len(parts) == 2:
            q, a = parts
            text = f"Q: {q.strip()} A: {a.strip()}"
            docs.append(Document(page_content=text, metadata={"id": str(i)}))
        else:
            print(f"⚠️ Skipped invalid FAQ at index {i}")

    if not docs:
        raise ValueError("❌ No valid FAQs found. Please check the input file.")

    vector_store = Chroma(
        collection_name=COLLECTION_NAME,
        persist_directory=DB_LOCATION,
        embedding_function=embeddings,
    )
    vector_store.add_documents(docs)
    print(f"✅ Added {len(docs)} FAQs to the database!")

def run_app():
    """Launch the Streamlit chatbot."""
    print("🚀 Starting Streamlit app...")
    subprocess.run(["streamlit", "run", "app.py"], check=True)

if __name__ == "__main__":
    force = os.getenv("REBUILD_DB", "false").lower() == "true"
    build_db(force_rebuild=force)
    run_app()
