import os
import re
import argparse
from langchain_ollama import OllamaEmbeddings
from langchain_chroma import Chroma
from langchain_core.documents import Document
import shutil

db_location = "./chroma_ops_db"
embeddings = OllamaEmbeddings(model="mxbai-embed-large")

def build_database(file_path: str):
    print(f"📄 Building database from {file_path}...")
    docs = []

    with open(file_path, "r", encoding="utf-8") as f:
        content = f.read()

    # Regex split for robust parsing
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
        collection_name="business_ops",
        persist_directory=db_location,
        embedding_function=embeddings,
    )
    vector_store.add_documents(docs)
    print(f"✅ Added {len(docs)} FAQs to the database!")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", default="f2442acc-5c9d-46ed-a05b-f581e7484aa2.txt", help="FAQ text file")
    parser.add_argument("--rebuild", action="store_true", help="Force rebuild of database")
    args = parser.parse_args()

    if args.rebuild and os.path.exists(db_location):
        print("♻️ Rebuilding database...")
        shutil.rmtree(db_location)

    if not os.path.exists(db_location):
        build_database(args.file)
    else:
        print("✅ Database already exists, skipping.")
