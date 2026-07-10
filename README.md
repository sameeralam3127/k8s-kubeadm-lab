# Ollama RAG Studio

This project is an offline-first local Retrieval-Augmented Generation stack built around Ollama and ChromaDB. FastAPI handles document ingestion and chat APIs, Streamlit provides the user interface, Chroma stores embeddings, Postgres stores session history, and Redis caches repeated answers.

## What this project includes

- Offline-first default chat using local Ollama models
- Local embedding workflow using an Ollama embedding model
- ChromaDB vector search over uploaded PDF documents
- FastAPI admin endpoints for secure PDF ingestion and reindexing
- Streamlit chat UI with session history and cached responses
- Postgres-backed conversation history
- Redis-backed response cache
- OpenAI-compatible provider support for optional external model usage
- Compute Central website chat with a bounded public-site crawl, content-hash refreshes, and source links
- Docker Compose for frontend, backend, Postgres, and Redis

## Why use RAG if an LLM already exists?

An LLM already knows general language patterns, but it does not automatically know your latest internal PDFs, private documents, or organization-specific facts. RAG solves that gap by retrieving the most relevant chunks from your own document store at question time and injecting them into the prompt. That makes answers more grounded, more current, and easier to update without retraining the model.

## Main API endpoints

- `POST /api/v1/admin/documents/upload`
  - Admin only
  - Uploads a PDF and indexes it into Chroma
- `POST /api/v1/admin/documents/reindex`
  - Admin only
  - Reprocesses PDFs from the local documents directory
- `POST /api/v1/chat`
  - Sends a user message through the RAG pipeline
- `POST /api/v1/compute-central/chat`
  - Refreshes stale Compute Central content on demand, then answers using only the local Compute Central index
- `POST /api/v1/compute-central/refresh`
  - Manually refreshes the public `https://computecentral.in/` index
- `GET /api/v1/compute-central/status`
  - Shows the last successful site-index refresh time
- `GET /api/v1/chat/history/{session_id}`
  - Reads persisted session history
- `GET /api/v1/models/ollama`
  - Lists local Ollama models available on the machine

## Project structure

```text
app/
  api/
  core/
  db/
  models/
  services/
streamlit_app/
docker/
data/
README.md
setup.md
usage.md
train.md
```

## Quick start

1. Copy `.env.example` to `.env`
2. Start local Ollama on the host machine
3. Pull a chat model and an embedding model
4. Start Docker Compose
5. Open Streamlit on `http://localhost:8501`

Read `setup.md` for the full setup flow.

## Compute Central freshness

Compute Central is a static GitHub Pages site, so this app reads its public sitemap and homepage links rather than expecting a website API. The backend keeps a separate Chroma collection, stores page URL/title/headings/hash/HTTP validators/fetch time in `data/compute_central_state.json`, and replaces only pages whose content hash changed. It refreshes once at backend startup and at `COMPUTE_CENTRAL_REFRESH_MINUTES` intervals (30 by default); a site question also refreshes when that interval has elapsed. Use the sidebar **Refresh Compute Central content** control when you need an immediate update. Answers expose the indexed page links and fetch timestamps.
