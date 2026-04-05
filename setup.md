# Setup Guide

## Prerequisites

- Python 3.12+
- Docker and Docker Compose
- Ollama installed locally on the host machine
- At least one local chat model and one local embedding model

## Recommended local Ollama models

- Chat model: `llama3.1:8b`
- Embedding model: `nomic-embed-text`

Pull them locally:

```bash
ollama pull llama3.1:8b
ollama pull nomic-embed-text
ollama list
```

## Environment setup

Create an environment file:

```bash
cp .env.example .env
```

Suggested values:

```env
ADMIN_TOKEN=super-secret-admin-token
OLLAMA_BASE_URL=http://host.docker.internal:11434
DEFAULT_CHAT_MODEL=llama3.1:8b
DEFAULT_EMBEDDING_MODEL=nomic-embed-text
POSTGRES_URL=postgresql+psycopg://ollama_rag_studio:ollama_rag_studio@postgres:5432/ollama_rag_studio
REDIS_URL=redis://redis:6379/0
CHROMA_PATH=/app/data/chroma
DOCUMENTS_PATH=/app/data/documents
```

## Run with Docker

```bash
docker compose up --build
```

Services:

- FastAPI: `http://localhost:8000`
- Streamlit: `http://localhost:8501`
- Postgres: `localhost:5432`
- Redis: `localhost:6379`

## Run without Docker

Backend:

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload
```

Frontend:

```bash
source .venv/bin/activate
streamlit run streamlit_app/app.py
```

For local non-Docker mode, point `.env` to:

```env
POSTGRES_URL=postgresql+psycopg://ollama_rag_studio:ollama_rag_studio@localhost:5432/ollama_rag_studio
REDIS_URL=redis://localhost:6379/0
OLLAMA_BASE_URL=http://localhost:11434
```
