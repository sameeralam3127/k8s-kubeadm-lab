# run.py - UPDATED
import os
import subprocess
import shutil
from utils.parser import FAQParser, SimpleFAQParser
from core.database import vector_db
from config.settings import settings

def build_database(force_rebuild: bool = False):
    """Build vector database with better error handling"""
    if force_rebuild and os.path.exists(settings.db_location):
        print("♻️ Force rebuilding database...")
        shutil.rmtree(settings.db_location)
    
    if os.path.exists(settings.db_location):
        print("✅ Database exists, skipping build.")
        return True
    
    if not os.path.exists(settings.faq_file):
        raise FileNotFoundError(f"FAQ file not found: {settings.faq_file}")
    
    print(f"📊 Building database from {settings.faq_file}...")
    
    # Try main parser first, then fallback to simple parser
    try:
        documents = FAQParser.parse_faq_file(settings.faq_file)
        if not documents:
            print("⚠️ Main parser found 0 documents, trying simple parser...")
            documents = SimpleFAQParser.parse_faq_file(settings.faq_file)
    except Exception as e:
        print(f"⚠️ Parser error: {e}, trying simple parser...")
        documents = SimpleFAQParser.parse_faq_file(settings.faq_file)
    
    if not documents:
        raise ValueError("❌ No valid documents found after trying both parsers")
    
    print(f"📄 Successfully parsed {len(documents)} documents")
    
    # Add to vector store
    vector_db.vector_store.add_documents(documents)
    print(f"✅ Added {len(documents)} documents to vector database!")
    return True

def main():
    """Main application entry point"""
    import argparse
    
    parser = argparse.ArgumentParser()
    parser.add_argument("--rebuild", action="store_true", help="Rebuild database")
    parser.add_argument("--port", type=int, default=8501, help="Streamlit port")
    parser.add_argument("--diagnose", action="store_true", help="Run diagnosis first")
    args = parser.parse_args()
    
    if args.diagnose:
        from diagnose import diagnose_issues
        diagnose_issues()
        return
    
    # Build database if needed
    if build_database(force_rebuild=args.rebuild):
        # Launch Streamlit
        print("🚀 Starting Business Chatbot...")
        subprocess.run([
            "streamlit", "run", "app.py",
            "--server.port", str(args.port),
            "--server.headless", "true"
        ], check=True)

if __name__ == "__main__":
    main()