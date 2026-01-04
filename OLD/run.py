# run.py - INTEGRATED VERSION
import os
import subprocess
import shutil
from config.settings import settings

def build_database(force_rebuild: bool = False):
    """Build or rebuild the vector database - PROPERLY INTEGRATED"""
    
    # Check if database exists and has content
    db_exists = os.path.exists(settings.db_location) and os.path.isdir(settings.db_location)
    has_content = False
    
    if db_exists:
        try:
            # Import here to avoid circular imports
            from core.database import vector_db
            count = vector_db.get_document_count()
            has_content = count > 0
            print(f"📊 Current database status: {count} documents")
        except Exception as e:
            print(f"⚠️ Error checking database: {e}")
            has_content = False
    
    # Determine if rebuild is needed
    needs_rebuild = force_rebuild or not db_exists or not has_content
    
    if not needs_rebuild:
        print("✅ Database is ready, skipping build.")
        return True
    
    # Rebuild needed
    print("🏗️ Database build required...")
    
    # Remove existing database if it exists
    if db_exists:
        print("🧹 Removing existing database...")
        shutil.rmtree(settings.db_location)
    
    # Build using the standalone builder
    try:
        from build_database import build_database_standalone
        print("📦 Building new database...")
        count = build_database_standalone()
        
        if count > 0:
            print(f"🎉 Database built successfully with {count} documents")
            
            # Reinitialize the database connection to ensure fresh state
            from core.database import vector_db
            vector_db._initialize_db()
            
            # Verify the connection works
            verified_count = vector_db.get_document_count()
            print(f"🔍 Verification: Database now has {verified_count} documents")
            
            return True
        else:
            raise ValueError("Database build returned 0 documents")
            
    except Exception as e:
        print(f"❌ Database build failed: {e}")
        return False

def check_database_health():
    """Quick health check of the database"""
    try:
        from core.database import vector_db
        count = vector_db.get_document_count()
        print(f"🏥 Database health check: {count} documents")
        
        # Test a simple search
        test_results = vector_db.vector_store.similarity_search("test", k=1)
        print(f"🔍 Search test: {len(test_results)} results")
        
        return count > 0
    except Exception as e:
        print(f"❌ Database health check failed: {e}")
        return False

def main():
    """Main application entry point"""
    import argparse
    
    parser = argparse.ArgumentParser(description="Business Operations Chatbot")
    parser.add_argument("--rebuild", action="store_true", help="Force rebuild the vector database")
    parser.add_argument("--port", type=int, default=8501, help="Streamlit port")
    parser.add_argument("--check", action="store_true", help="Check database health only")
    
    args = parser.parse_args()
    
    if args.check:
        # Just check database health and exit
        check_database_health()
        return
    
    # Build database if needed
    success = build_database(force_rebuild=args.rebuild)
    
    if not success:
        print("❌ Failed to build database. Exiting.")
        return
    
    # Final health check before starting app
    if not check_database_health():
        print("❌ Database health check failed. Cannot start app.")
        return
    
    # Launch Streamlit app
    print("🚀 Starting Business Operations Chatbot...")
    try:
        subprocess.run([
            "streamlit", "run", "app.py",
            "--server.port", str(args.port),
            "--server.headless", "true"
        ], check=True)
    except KeyboardInterrupt:
        print("\n👋 App stopped by user")
    except Exception as e:
        print(f"❌ Error starting app: {e}")

if __name__ == "__main__":
    main()