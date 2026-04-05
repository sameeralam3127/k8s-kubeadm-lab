# Document Training and RAG Notes

## Important clarification

This project does not fine-tune the model. Instead, it performs document ingestion for RAG.

## How document ingestion works

1. Admin uploads a PDF
2. The backend extracts PDF text
3. Text is split into chunks
4. Each chunk is embedded with the local Ollama embedding model
5. Embeddings and metadata are stored in ChromaDB
6. At chat time, the most relevant chunks are retrieved and attached to the prompt

## Why this is usually better than retraining

- Faster updates when documents change
- Lower infrastructure cost
- Keeps private knowledge local
- No retraining cycle for every PDF revision
- Easier to audit which source informed an answer

## Suggested ingestion workflow

- Keep clean PDFs in `data/documents`
- Reindex after replacing or adding documents
- Use high-quality text PDFs when possible
- Prefer a dedicated embedding model such as `nomic-embed-text`

## Recommended local model pairing

- Chat: `llama3.1:8b`
- Embeddings: `nomic-embed-text`

## Retrieval tuning ideas

- Increase `retrieval_k` if answers need more context
- Reduce `chunk_size` for dense technical manuals
- Increase `chunk_overlap` when section continuity matters
- Add metadata filters later for department, document type, or date
