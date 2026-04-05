from pathlib import Path

from fastapi import APIRouter, Depends, File, HTTPException, UploadFile
from sqlalchemy.orm import Session

from app.api.deps import get_db, require_admin
from app.core.config import get_settings
from app.models.schemas import (
    ChatRequest,
    ChatResponse,
    DocumentUploadResponse,
    HealthResponse,
    OllamaModelItem,
    OllamaModelsResponse,
    ReindexRequest,
    ReindexResponse,
    SessionHistoryResponse,
)
from app.services.chat_service import ChatService
from app.services.document_service import DocumentService
from app.services.provider_service import ProviderService


router = APIRouter()
settings = get_settings()


@router.get("/health", response_model=HealthResponse)
async def health() -> HealthResponse:
    return HealthResponse(
        status="ok",
        ollama_base_url=settings.ollama_base_url,
        chroma_collection=settings.chroma_collection,
    )


@router.get("/models/ollama", response_model=OllamaModelsResponse)
async def list_ollama_models() -> OllamaModelsResponse:
    models = await ProviderService().list_ollama_models()
    return OllamaModelsResponse(
        models=[
            OllamaModelItem(
                name=model.get("name", ""),
                size=model.get("size"),
                modified_at=model.get("modified_at"),
            )
            for model in models
        ]
    )


@router.post(
    "/admin/documents/upload",
    response_model=DocumentUploadResponse,
    dependencies=[Depends(require_admin)],
)
async def upload_document(file: UploadFile = File(...)) -> DocumentUploadResponse:
    if not file.filename.lower().endswith(".pdf"):
        raise HTTPException(status_code=400, detail="Only PDF uploads are supported.")
    destination = Path(settings.documents_path) / Path(file.filename).name
    destination.write_bytes(await file.read())
    chunks = await DocumentService().ingest_pdf(str(destination))
    return DocumentUploadResponse(
        filename=destination.name,
        chunks_indexed=chunks,
        collection_name=settings.chroma_collection,
    )


@router.post(
    "/admin/documents/reindex",
    response_model=ReindexResponse,
    dependencies=[Depends(require_admin)],
)
async def reindex_documents(payload: ReindexRequest) -> ReindexResponse:
    indexed_files, indexed_chunks = await DocumentService().reindex_directory(rebuild=payload.rebuild)
    return ReindexResponse(indexed_files=indexed_files, indexed_chunks=indexed_chunks)


@router.post("/chat", response_model=ChatResponse)
async def chat(payload: ChatRequest, db: Session = Depends(get_db)) -> ChatResponse:
    response = await ChatService().chat(
        db,
        session_id=payload.session_id,
        message=payload.message,
        provider_config=payload.provider_config,
    )
    return ChatResponse(**response)


@router.get("/chat/history/{session_id}", response_model=SessionHistoryResponse)
async def chat_history(session_id: str, db: Session = Depends(get_db)) -> SessionHistoryResponse:
    history = ChatService().get_history(db, session_id)
    return SessionHistoryResponse(session_id=session_id, history=history)
