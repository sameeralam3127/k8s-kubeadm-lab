# run.py - FIXED VERSION
import os
import subprocess
import shutil
from utils.parser import FAQParser, SimpleFAQParser
from core.database import vector_db
from config.settings import settings

def build_database(force_rebuild: bool = False):
    """Build vector database with proper existence checking"""
    db_exists = os.path.exists(settings.db_location) and os.path.isdir(settings.db_location)
    
    if force_rebuild and db_exists:
        print("♻️ Force rebuilding database...")
        shutil.rmtree(settings.db_location)
        db_exists = False
    
    if db_exists:
        # Verify it's not an empty directory
        contents = os.listdir(settings.db_location)
        if contents:
            print("✅ Database exists and has content, skipping build.")
            return True
        else:
            print("⚠️ Database directory exists but is empty, rebuilding...")
            shutil.rmtree(settings.db_location)
            db_exists = False
    
    if not os.path.exists(settings.faq_file):
        raise FileNotFoundError(f"FAQ file not found: {settings.faq_file}")
    
    print(f"📊 Building database from {settings.faq_file}...")
    
    # Try main parser first, then fallback to simple parser
    try:
        documents = FAQParser.parse_faq_file(settings.faq_file)
        if len(documents) == 0:
            print("⚠️ Main parser found 0 documents, trying simple parser...")
            documents = SimpleFAQParser.parse_faq_file(settings.faq_file)
    except Exception as e:
        print(f"⚠️ Parser error: {e}, trying simple parser...")
        documents = SimpleFAQParser.parse_faq_file(settings.faq_file)
    
    if len(documents) == 0:
        raise ValueError("❌ No valid documents found after trying both parsers")
    
    print(f"📄 Successfully parsed {len(documents)} documents")
    
    # Create the database directory if it doesn't exist
    os.makedirs(settings.db_location, exist_ok=True)
    
    # Add to vector store
    vector_db.vector_store.add_documents(documents)
    print(f"✅ Added {len(documents)} documents to vector database!")
    
    # Verify the database was created
    if os.path.exists(settings.db_location):
        contents = os.listdir(settings.db_location)
        print(f"📁 Database created with {len(contents)} files")
    else:
        print("❌ Database was not created!")
        
    return True