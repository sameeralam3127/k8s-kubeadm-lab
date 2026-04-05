# Usage Guide

## Chat flow

1. Open Streamlit at `http://localhost:8501`
2. Keep provider set to `Offline Ollama` for fully local usage
3. Choose an available local model from the sidebar
4. Ask questions about your uploaded PDFs

## Admin PDF upload

Admins can upload PDFs from the Streamlit sidebar or directly through FastAPI.

Example with `curl`:

```bash
curl -X POST "http://localhost:8000/api/v1/admin/documents/upload" \
  -H "X-Admin-Token: super-secret-admin-token" \
  -F "file=@/absolute/path/to/file.pdf"
```

Reindex all PDFs already present in `data/documents`:

```bash
curl -X POST "http://localhost:8000/api/v1/admin/documents/reindex" \
  -H "Content-Type: application/json" \
  -H "X-Admin-Token: super-secret-admin-token" \
  -d '{"rebuild": true}'
```

## Switching to another provider

The UI defaults to local Ollama. If a user wants another provider:

1. Change the sidebar provider to `External API`
2. Enter a model name
3. Enter an OpenAI-compatible base URL
4. Enter the API key

Examples of OpenAI-compatible services:

- OpenAI
- Groq
- Together
- OpenRouter

## Session history and caching

- Session history is persisted in Postgres
- Repeated prompts with the same retrieved context are cached in Redis
- The frontend also keeps the current conversation in Streamlit session state for smoother UI continuity
