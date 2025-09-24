from langchain_ollama import OllamaEmbeddings
from langchain_chroma import Chroma
import os

db_location = "./chroma_ops_db"
embeddings = OllamaEmbeddings(model="mxbai-embed-large")

if not os.path.exists(db_location):
    raise RuntimeError(
        f"❌ Chroma DB not found at {db_location}. Run build.py first to create it."
    )

# Initialize vector store
vector_store = Chroma(
    collection_name="business_ops",
    persist_directory=db_location,
    embedding_function=embeddings,
)

# Configurable retriever (k via env var)
retriever_k = int(os.getenv("RETRIEVER_K", 5))
retriever_mode = os.getenv("RETRIEVER_MODE", "similarity")  # or "mmr"

retriever = vector_store.as_retriever(
    search_type=retriever_mode,
    search_kwargs={"k": retriever_k},
)
