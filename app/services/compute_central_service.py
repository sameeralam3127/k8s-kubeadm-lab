"""Small, local crawler and RAG flow for the public Compute Central site."""

import asyncio
import hashlib
import json
import re
from datetime import UTC, datetime
from html.parser import HTMLParser
from pathlib import Path
from typing import Any
from urllib.parse import urljoin, urlparse
from xml.etree import ElementTree

import httpx
from langchain_text_splitters import RecursiveCharacterTextSplitter
from sqlalchemy.orm import Session

from app.core.config import get_settings
from app.db.models import ChatMessage, ChatSession
from app.models.schemas import ChatMessageResponse, ProviderConfig
from app.services.provider_service import ProviderService
from app.services.vector_store import VectorStoreService


settings = get_settings()


class _PageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.title = ""
        self._in_title = False
        self._heading: str | None = None
        self._heading_parts: list[str] = []
        self._parts: list[str] = []
        self.headings: list[str] = []
        self.links: list[str] = []
        self._ignore_depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        if tag in {"script", "style", "noscript"}:
            self._ignore_depth += 1
        if tag == "title":
            self._in_title = True
        if tag in {"h1", "h2", "h3"}:
            self._heading = tag
            self._heading_parts = []
        if tag == "a" and attributes.get("href"):
            self.links.append(attributes["href"] or "")

    def handle_endtag(self, tag: str) -> None:
        if tag in {"script", "style", "noscript"} and self._ignore_depth:
            self._ignore_depth -= 1
        if tag == "title":
            self._in_title = False
        if tag in {"h1", "h2", "h3"} and self._heading == tag:
            heading = " ".join(self._heading_parts).strip()
            if heading:
                self.headings.append(heading)
                self._parts.append("\n\n" + heading + "\n")
            self._heading = None

    def handle_data(self, data: str) -> None:
        if self._ignore_depth:
            return
        text = re.sub(r"\s+", " ", data).strip()
        if not text:
            return
        if self._in_title:
            self.title += (" " if self.title else "") + text
        if self._heading:
            self._heading_parts.append(text)
        self._parts.append(text)

    @property
    def text(self) -> str:
        return re.sub(r"[ \t]+", " ", " ".join(self._parts)).strip()


class ComputeCentralService:
    """Crawls a bounded same-domain set of public pages and keeps a Chroma index current."""

    def __init__(self) -> None:
        self.vector_store = VectorStoreService(settings.compute_central_collection)
        self.splitter = RecursiveCharacterTextSplitter(
            chunk_size=settings.chunk_size, chunk_overlap=settings.chunk_overlap
        )
        self.state_path = Path(settings.compute_central_state_path)

    async def refresh(self) -> dict[str, Any]:
        state = self._load_state()
        urls = await self._discover_urls()
        changed_pages = 0
        chunks_indexed = 0
        now = self._timestamp()
        async with httpx.AsyncClient(
            timeout=settings.compute_central_request_timeout_seconds,
            follow_redirects=True,
            headers={"User-Agent": "Ollama-RAG-Studio/1.0 (+local development)"},
        ) as client:
            for url in urls:
                previous = state.get("documents", {}).get(url, {})
                headers = {}
                if previous.get("etag"):
                    headers["If-None-Match"] = previous["etag"]
                if previous.get("last_modified"):
                    headers["If-Modified-Since"] = previous["last_modified"]
                try:
                    response = await client.get(url, headers=headers)
                except httpx.HTTPError:
                    continue
                if response.status_code == 304:
                    previous["last_fetched"] = now
                    state.setdefault("documents", {})[url] = previous
                    continue
                if response.status_code != 200 or "html" not in response.headers.get("content-type", ""):
                    continue
                parser = _PageParser()
                parser.feed(response.text)
                content = parser.text
                if not content:
                    continue
                content_hash = hashlib.sha256(content.encode("utf-8")).hexdigest()
                record = {
                    "url": url,
                    "title": parser.title or url,
                    "headings": parser.headings,
                    "content_hash": content_hash,
                    "etag": response.headers.get("etag"),
                    "last_modified": response.headers.get("last-modified"),
                    "last_fetched": now,
                }
                if previous.get("content_hash") != content_hash:
                    self.vector_store.delete_by_url(url)
                    chunks = self._chunks(content, record)
                    chunks_indexed += await self.vector_store.add_documents(chunks)
                    changed_pages += 1
                state.setdefault("documents", {})[url] = record
        state["last_refresh"] = now
        self._save_state(state)
        return {
            "last_refresh": now,
            "pages_discovered": len(urls),
            "pages_changed": changed_pages,
            "chunks_indexed": chunks_indexed,
        }

    async def ensure_fresh(self) -> dict[str, Any]:
        state = self._load_state()
        last_refresh = state.get("last_refresh")
        if not last_refresh or self._is_stale(last_refresh):
            try:
                return await self.refresh()
            except (httpx.HTTPError, OSError):
                return self.status()
        return self.status()

    def status(self) -> dict[str, Any]:
        state = self._load_state()
        return {
            "last_refresh": state.get("last_refresh"),
            "pages_discovered": len(state.get("documents", {})),
            "pages_changed": 0,
            "chunks_indexed": 0,
        }

    async def _discover_urls(self) -> list[str]:
        root = settings.compute_central_url.rstrip("/") + "/"
        candidates = [urljoin(root, "sitemap.xml"), root]
        urls: set[str] = {root}
        async with httpx.AsyncClient(
            timeout=settings.compute_central_request_timeout_seconds, follow_redirects=True
        ) as client:
            try:
                sitemap = await client.get(candidates[0])
                if sitemap.status_code == 200:
                    root_xml = ElementTree.fromstring(sitemap.content)
                    for loc in root_xml.findall(".//{*}loc"):
                        if loc.text and self._is_site_url(loc.text):
                            urls.add(self._canonical_url(loc.text))
            except (httpx.HTTPError, ElementTree.ParseError):
                pass
            # Homepage links are a useful fallback for sites without a complete sitemap.
            try:
                home = await client.get(root)
                if home.status_code == 200:
                    parser = _PageParser()
                    parser.feed(home.text)
                    for link in parser.links:
                        url = self._canonical_url(urljoin(root, link))
                        if self._is_site_url(url):
                            urls.add(url)
            except httpx.HTTPError:
                pass
        return sorted(urls)[: settings.compute_central_max_pages]

    def _chunks(self, content: str, record: dict[str, Any]) -> list[dict[str, Any]]:
        return [
            {
                "text": text,
                "metadata": {
                    "source": record["title"],
                    "url": record["url"],
                    "title": record["title"],
                    "last_fetched": record["last_fetched"],
                    "content_hash": record["content_hash"],
                },
            }
            for text in self.splitter.split_text(content)
        ]

    def _load_state(self) -> dict[str, Any]:
        try:
            return json.loads(self.state_path.read_text())
        except (OSError, json.JSONDecodeError):
            return {"documents": {}}

    def _save_state(self, state: dict[str, Any]) -> None:
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        self.state_path.write_text(json.dumps(state, indent=2, sort_keys=True))

    def _is_stale(self, timestamp: str) -> bool:
        try:
            age = datetime.now(UTC) - datetime.fromisoformat(timestamp)
            return age.total_seconds() >= settings.compute_central_refresh_minutes * 60
        except ValueError:
            return True

    def _is_site_url(self, url: str) -> bool:
        return urlparse(url).netloc in {"computecentral.in", "www.computecentral.in"}

    def _canonical_url(self, url: str) -> str:
        parsed = urlparse(url)
        return parsed._replace(fragment="", query="").geturl()

    @staticmethod
    def _timestamp() -> str:
        return datetime.now(UTC).isoformat()


class ComputeCentralChatService:
    """Website-only chat: the LLM receives only current Compute Central chunks."""

    def __init__(self) -> None:
        self.content = ComputeCentralService()
        self.provider = ProviderService()

    async def chat(self, db: Session, *, session_id: str | None, message: str, provider_config: ProviderConfig) -> dict[str, Any]:
        freshness = await self.content.ensure_fresh()
        matches = await self.content.vector_store.similarity_search(message)
        matches = [m for m in matches if m["distance"] <= settings.site_retrieval_max_distance]
        session = self._session(db, session_id)
        if not matches:
            answer = "I could not find relevant content in the latest Compute Central index. Try a more specific site-related question."
            model_name = provider_config.model or settings.default_chat_model
        else:
            context = "\n\n".join(
                f"[{index}] URL: {item['metadata'].get('url')}\n{item['content']}"
                for index, item in enumerate(matches, 1)
            )
            answer, model_name = await self.provider.generate_answer(
                provider_config=provider_config,
                messages=[
                    {"role": "system", "content": "Answer only from the supplied current Compute Central website context. If it does not answer the question, say so plainly. Include source references such as [1]."},
                    {"role": "user", "content": f"Current site context:\n{context}\n\nQuestion: {message}"},
                ],
            )
        self._persist(db, session, "user", message, provider_config.provider, provider_config.model or "")
        self._persist(db, session, "assistant", answer, provider_config.provider, model_name)
        db.refresh(session)
        return {
            "session_id": session.id, "answer": answer, "cached": False,
            "provider": provider_config.provider, "model_name": model_name,
            "sources": [
                {"source": item["metadata"].get("title", "Compute Central"), "url": item["metadata"].get("url"), "updated_at": item["metadata"].get("last_fetched"), "preview": item["content"][:220]}
                for item in matches
            ],
            "history": [ChatMessageResponse(role=m.role, content=m.content, provider=m.provider, model_name=m.model_name) for m in session.messages],
            "freshness": freshness,
        }

    def _session(self, db: Session, session_id: str | None) -> ChatSession:
        session = db.get(ChatSession, session_id) if session_id else None
        if session:
            return session
        session = ChatSession()
        db.add(session); db.commit(); db.refresh(session)
        return session

    def _persist(self, db: Session, session: ChatSession, role: str, content: str, provider: str, model: str) -> None:
        db.add(ChatMessage(session_id=session.id, role=role, content=content, provider=provider, model_name=model))
        db.commit()


async def scheduled_compute_central_refresh() -> None:
    """One lightweight local task; failures leave the last successful index available."""
    service = ComputeCentralService()
    while True:
        try:
            await service.refresh()
        except (httpx.HTTPError, OSError):
            pass
        await asyncio.sleep(settings.compute_central_refresh_minutes * 60)
