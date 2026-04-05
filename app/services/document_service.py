from pathlib import Path

from langchain_text_splitters import RecursiveCharacterTextSplitter
from pypdf import PdfReader

from app.core.config import get_settings
from app.services.vector_store import VectorStoreService


settings = get_settings()


class DocumentService:
    def __init__(self) -> None:
        self.vector_store = VectorStoreService()
        self.splitter = RecursiveCharacterTextSplitter(
            chunk_size=settings.chunk_size,
            chunk_overlap=settings.chunk_overlap,
        )

    async def ingest_pdf(self, file_path: str) -> int:
        chunks = self._create_chunks(file_path)
        return await self.vector_store.add_documents(chunks)

    async def reindex_directory(self, rebuild: bool = False) -> tuple[int, int]:
        if rebuild:
            self.vector_store.reset()
        indexed_files = 0
        indexed_chunks = 0
        for pdf_path in sorted(Path(settings.documents_path).glob("*.pdf")):
            indexed_files += 1
            indexed_chunks += await self.ingest_pdf(str(pdf_path))
        return indexed_files, indexed_chunks

    def _create_chunks(self, file_path: str) -> list[dict]:
        reader = PdfReader(file_path)
        raw_pages: list[tuple[int, str]] = []
        for page_number, page in enumerate(reader.pages, start=1):
            text = (page.extract_text() or "").strip()
            if text:
                raw_pages.append((page_number, text))

        chunks: list[dict] = []
        for page_number, text in raw_pages:
            split_texts = self.splitter.split_text(text)
            for chunk_index, chunk in enumerate(split_texts, start=1):
                chunks.append(
                    {
                        "text": chunk,
                        "metadata": {
                            "source": Path(file_path).name,
                            "page": page_number,
                            "chunk": chunk_index,
                        },
                    }
                )
        return chunks
