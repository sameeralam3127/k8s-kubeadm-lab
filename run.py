import os
import subprocess
import shutil
from config.settings import settings
from utils.parser import FAQParser
from core.database import vector_db

def build_database(force_rebuild: bool = False):
    """Build or rebuild the vector database"""
    if force_rebuild and os.path.exists(settings.db_location):
        print("♻️ Removing existing database...")
        shutil.rmtree(settings.db_location)
    
    # Check if database needs to be built
    if not os.path.exists(settings.db_location) or not os.listdir(settings.db_location):
        print("📊 Building vector database...")
        
        if not os.path.exists(settings.faq_file):
            raise FileNotFoundError(f"FAQ file not found: {settings.faq_file}")
        
        # Parse documents
        documents = FAQParser.parse_faq_file(settings.faq_file)
        
        if not documents:
            raise ValueError("No documents found in FAQ file")
        
        # Add to database
        count = vector_db.add_documents(documents)
        print(f"✅ Added {count} documents to database")
        
        # Verify
        doc_count = vector_db.get_document_count()
        print(f"📁 Database now contains {doc_count} documents")
    else:
        doc_count = vector_db.get_document_count()
        print(f"✅ Database exists with {doc_count} documents")

def main():
    """Main application entry point"""
    import argparse
    
    parser = argparse.ArgumentParser(description="Business Operations Chatbot")
    parser.add_argument("--rebuild", action="store_true", help="Rebuild the vector database")
    parser.add_argument("--port", type=int, default=8501, help="Streamlit port")
    
    args = parser.parse_args()
    
    # Build database if needed
    build_database(force_rebuild=args.rebuild)
    
    # Launch Streamlit app
    print("🚀 Starting Business Operations Chatbot...")
    subprocess.run([
        "streamlit", "run", "app.py",
        "--server.port", str(args.port),
        "--server.headless", "true"
    ], check=True)

if __name__ == "__main__":
    main()