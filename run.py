# run.py - UPDATED
import os
import subprocess
import shutil
from config.settings import settings

def build_database(force_rebuild: bool = False):
    """Build or rebuild the vector database - FIXED"""
    
    # Check if we need to rebuild
    needs_rebuild = force_rebuild or not os.path.exists(settings.db_location)
    
    if not needs_rebuild:
        # Check if database has content
        try:
            from core.database import vector_db
            count = vector_db.get_document_count()
            if count > 0:
                print(f"✅ Database exists with {count} documents")
                return True
            else:
                print("⚠️ Database exists but is empty, rebuilding...")
                needs_rebuild = True
        except:
            needs_rebuild = True
    
    if needs_rebuild:
        print("🏗️ Building database...")
        
        # Use the standalone builder
        from build_database import build_database_standalone
        count = build_database_standalone()
        
        if count > 0:
            print(f"🎉 Database built successfully with {count} documents")
            return True
        else:
            raise ValueError("Failed to build database")
    
    return True

def main():
    """Main application entry point"""
    import argparse
    
    parser = argparse.ArgumentParser(description="Business Operations Chatbot")
    parser.add_argument("--rebuild", action="store_true", help="Rebuild the vector database")
    parser.add_argument("--port", type=int, default=8501, help="Streamlit port")
    
    args = parser.parse_args()
    
    # Build database if needed
    if build_database(force_rebuild=args.rebuild):
        # Launch Streamlit app
        print("🚀 Starting Business Operations Chatbot...")
        subprocess.run([
            "streamlit", "run", "app.py",
            "--server.port", str(args.port),
            "--server.headless", "true"
        ], check=True)

if __name__ == "__main__":
    main()