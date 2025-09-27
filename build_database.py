# build_database.py
import os
import shutil
from utils.parser import FAQParser
from langchain_ollama import OllamaEmbeddings
from langchain_chroma import Chroma
from config.settings import settings

def build_database_standalone():
    """Standalone function to build the database properly"""
    
    # Clean up existing database
    if os.path.exists(settings.db_location):
        print("🧹 Removing existing database...")
        shutil.rmtree(settings.db_location)
    
    # Parse documents
    print("📄 Parsing FAQ file...")
    documents = FAQParser.parse_faq_file(settings.faq_file)
    print(f"✅ Parsed {len(documents)} documents")
    
    if not documents:
        raise ValueError("No documents found to add to database")
    
    # Show sample document
    print("\n📝 Sample document:")
    print(documents[0].page_content[:200] + "...")
    
    # Create embeddings
    print("\n🔧 Creating embeddings...")
    embeddings = OllamaEmbeddings(
        model=settings.embed_model,
        base_url=settings.ollama_base_url
    )
    
    # Build vector store from documents
    print("🏗️ Building vector database...")
    vector_store = Chroma.from_documents(
        documents=documents,
        embedding=embeddings,
        persist_directory=settings.db_location,
        collection_name=settings.collection_name
    )
    
    # Test the database
    print("\n🧪 Testing database...")
    count = vector_store._collection.count()
    print(f"📊 Database document count: {count}")
    
    # Test search
    test_results = vector_store.similarity_search("laptop", k=2)
    print(f"🔍 Test search found: {len(test_results)} documents")
    
    if test_results:
        print("✅ Sample search result:")
        print(test_results[0].page_content[:150] + "...")
    
    return count

if __name__ == "__main__":
    build_database_standalone()