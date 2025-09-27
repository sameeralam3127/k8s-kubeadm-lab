#!/usr/bin/env python3
import os
import subprocess
import shutil
from utils.parser import FAQParser
from core.database import vector_db
from config.settings import settings

def build_database(force_rebuild: bool = False):
    """Build optimized vector database"""
    if force_rebuild and os.path.exists(settings.db_location):
        print("♻️ Force rebuilding database...")
        shutil.rmtree(settings.db_location)
    
    if os.path.exists(settings.db_location):
        print("✅ Database exists, skipping build.")
        return
    
    if not os.path.exists(settings.faq_file):
        raise FileNotFoundError(f"FAQ file not found: {settings.faq_file}")
    
    print(f"📊 Building database from {settings.faq_file}...")
    documents = FAQParser.parse_faq_file(settings.faq_file)
    
    if not documents:
        raise ValueError("No valid documents found in FAQ file")
    
    # Add to vector store
    vector_db.vector_store.add_documents(documents)
    print(f"✅ Added {len(documents)} documents to database!")

def main():
    """Main application entry point"""
    import argparse
    
    parser = argparse.ArgumentParser()
    parser.add_argument("--rebuild", action="store_true", help="Rebuild database")
    parser.add_argument("--port", type=int, default=8501, help="Streamlit port")
    args = parser.parse_args()
    
    # Build database if needed
    build_database(force_rebuild=args.rebuild)
    
    # Launch Streamlit
    print("🚀 Starting optimized Business Chatbot...")
    subprocess.run([
        "streamlit", "run", "app.py",
        "--server.port", str(args.port),
        "--server.headless", "true"
    ], check=True)

if __name__ == "__main__":
    main()