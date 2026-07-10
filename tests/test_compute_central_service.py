import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

from app.services.compute_central_service import ComputeCentralService, _PageParser


class _Response:
    def __init__(self, status_code=200, text="", headers=None):
        self.status_code = status_code
        self.text = text
        self.headers = headers or {"content-type": "text/html"}


class _Client:
    def __init__(self, responses):
        self.responses = responses
        self.requests = []

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        return None

    async def get(self, url, headers=None):
        self.requests.append((url, headers or {}))
        return self.responses[url]


class _VectorStore:
    def __init__(self):
        self.deleted = []
        self.added = []

    def delete_by_url(self, url):
        self.deleted.append(url)

    async def add_documents(self, chunks):
        self.added.extend(chunks)
        return len(chunks)


class ComputeCentralServiceTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.service = ComputeCentralService()
        self.service.state_path = Path(self.tempdir.name) / "state.json"
        self.service.vector_store = _VectorStore()
        self.url = "https://computecentral.in/guide/"

    def tearDown(self):
        self.tempdir.cleanup()

    def test_parser_removes_script_content_and_keeps_heading(self):
        parser = _PageParser()
        parser.feed("<title>Guide</title><h1>Getting Started</h1><p>Use the guide.</p><script>secret()</script>")
        self.assertEqual(parser.title, "Guide")
        self.assertIn("Getting Started", parser.headings)
        self.assertIn("Use the guide.", parser.text)
        self.assertNotIn("secret", parser.text)

    async def test_refresh_replaces_changed_page_and_uses_conditional_headers(self):
        first = _Client({self.url: _Response(text="<title>Guide</title><h1>Install</h1><p>Version one</p>", headers={"content-type": "text/html", "etag": "v1"})})
        with patch.object(self.service, "_discover_urls", AsyncMock(return_value=[self.url])), patch(
            "app.services.compute_central_service.httpx.AsyncClient", return_value=first
        ):
            result = await self.service.refresh()
        self.assertEqual(result["pages_changed"], 1)
        self.assertGreater(result["chunks_indexed"], 0)
        self.assertEqual(self.service.vector_store.deleted, [self.url])

        second = _Client({self.url: _Response(status_code=304, headers={})})
        with patch.object(self.service, "_discover_urls", AsyncMock(return_value=[self.url])), patch(
            "app.services.compute_central_service.httpx.AsyncClient", return_value=second
        ):
            result = await self.service.refresh()
        self.assertEqual(result["pages_changed"], 0)
        self.assertEqual(second.requests[0][1]["If-None-Match"], "v1")

