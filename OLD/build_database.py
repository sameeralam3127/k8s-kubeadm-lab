# build_database.py - ENHANCED FOR INTEGRATION
import os
import shutil
from utils.parser import FAQParser
from langchain_ollama import OllamaEmbeddings
from langchain_chroma import Chroma
from config.settings import settings

def build_database_standalone():
    """Standalone function to build the database properly"""
    
    print("=" * 50)
    print("🏗️  DATABASE BUILD PROCESS STARTING")
    print("=" * 50)
    
    # Clean up existing database
    if os.path.exists(settings.db_location):
        print("🧹 Removing existing database...")
        shutil.rmtree(settings.db_location)
    
    # Step 1: Parse documents
    print("\n📄 Step 1: Parsing FAQ file...")
    if not os.path.exists(settings.faq_file):
        raise FileNotFoundError(f"FAQ file not found: {settings.faq_file}")
    
    documents = FAQParser.parse_faq_file(settings.faq_file)
    print(f"✅ Parsed {len(documents)} documents")
    
    if not documents:
        raise ValueError("❌ No documents found in FAQ file")
    
    # Show sample document
    print("\n📝 Sample document preview:")
    sample = documents[0].page_content[:150] + "..." if len(documents[0].page_content) > 150 else documents[0].page_content
    print(f"   {sample}")
    
    # Step 2: Create embeddings
    print("\n🔧 Step 2: Initializing embeddings...")
    try:
        embeddings = OllamaEmbeddings(
            model=settings.embed_model,
            base_url=settings.ollama_base_url
        )
        # Test embeddings
        test_embedding = embeddings.embed_query("test query")
        print(f"✅ Embeddings working (vector size: {len(test_embedding)})")
    except Exception as e:
        raise Exception(f"❌ Embeddings failed: {e}")
    
    # Step 3: Build vector store
    print("\n🏗️ Step 3: Building vector database...")
    try:
        vector_store = Chroma.from_documents(
            documents=documents,
            embedding=embeddings,
            persist_directory=settings.db_location,
            collection_name=settings.collection_name
        )
        print("✅ Vector database built successfully")
    except Exception as e:
        raise Exception(f"❌ Vector database build failed: {e}")
    
    # Step 4: Verification
    print("\n🧪 Step 4: Verifying database...")
    try:
        count = vector_store._collection.count()
        print(f"📊 Document count: {count}")
        
        # Test search functionality
        test_queries = ["laptop", "vacation", "meeting room"]
        for query in test_queries:
            results = vector_store.similarity_search(query, k=1)
            print(f"   🔍 '{query}': {len(results)} results")
        
        print("=" * 50)
        print("🎉 DATABASE BUILD COMPLETED SUCCESSFULLY")
        print("=" * 50)
        
        return count
        
    except Exception as e:
        raise Exception(f"❌ Database verification failed: {e}")

if __name__ == "__main__":
    build_database_standalone()