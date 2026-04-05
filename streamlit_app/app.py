from uuid import uuid4
import os

import requests
import streamlit as st


BACKEND_URL = os.getenv("BACKEND_URL", "http://backend:8000")
API_PREFIX = "/api/v1"


def api_get(path: str) -> dict:
    response = requests.get(f"{BACKEND_URL}{API_PREFIX}{path}", timeout=60)
    response.raise_for_status()
    return response.json()


def api_post(path: str, json: dict | None = None, files=None, headers=None) -> dict:
    response = requests.post(
        f"{BACKEND_URL}{API_PREFIX}{path}",
        json=json,
        files=files,
        headers=headers,
        timeout=180,
    )
    response.raise_for_status()
    return response.json()


def init_state() -> None:
    if "session_id" not in st.session_state:
        st.session_state.session_id = str(uuid4())
    if "messages" not in st.session_state:
        st.session_state.messages = []


def load_ollama_models() -> list[str]:
    try:
        payload = api_get("/models/ollama")
        return [item["name"] for item in payload["models"]]
    except Exception:
        return []


st.set_page_config(page_title="Offline Ollama RAG", layout="wide")
init_state()

st.title("Offline Local RAG Chat")
st.caption("Default mode uses local Ollama. You can switch to another OpenAI-compatible provider from the sidebar.")

with st.sidebar:
    st.header("Model Provider")
    provider = st.radio(
        "Choose provider",
        options=["ollama", "openai_compatible"],
        format_func=lambda value: "Offline Ollama" if value == "ollama" else "External API",
    )

    ollama_models = load_ollama_models()
    selected_model = None
    base_url = None
    api_key = None

    if provider == "ollama":
        selected_model = st.selectbox(
            "Local model",
            options=ollama_models or ["llama3.1:8b"],
            index=0,
        )
    else:
        selected_model = st.text_input("Model name", value="gpt-4o-mini")
        base_url = st.text_input("Provider base URL", value="https://api.openai.com")
        api_key = st.text_input("API key", type="password")
        st.caption("Works with OpenAI-compatible providers such as OpenAI, Groq, Together, or OpenRouter.")

    st.divider()
    if st.button("Clear chat history", use_container_width=True):
        st.session_state.messages = []
        st.session_state.session_id = str(uuid4())
        st.rerun()

    with st.expander("Why RAG if an LLM already exists?"):
        st.write(
            "A base LLM knows general patterns, but RAG injects your own PDFs and business context at question time. "
            "That gives fresher, organization-specific answers without retraining the whole model."
        )

    with st.expander("Admin PDF upload"):
        admin_token = st.text_input("Admin token", type="password")
        upload = st.file_uploader("Upload PDF", type=["pdf"])
        if st.button("Upload and index", use_container_width=True, disabled=upload is None):
            try:
                result = api_post(
                    "/admin/documents/upload",
                    files={"file": (upload.name, upload.getvalue(), "application/pdf")},
                    headers={"X-Admin-Token": admin_token},
                )
                st.success(f"Indexed {result['chunks_indexed']} chunks from {result['filename']}.")
            except Exception as exc:
                st.error(f"Upload failed: {exc}")
        if st.button("Reindex stored PDFs", use_container_width=True):
            try:
                result = api_post(
                    "/admin/documents/reindex",
                    json={"rebuild": True},
                    headers={"X-Admin-Token": admin_token},
                )
                st.success(
                    f"Reindexed {result['indexed_files']} files into {result['indexed_chunks']} chunks."
                )
            except Exception as exc:
                st.error(f"Reindex failed: {exc}")


for item in st.session_state.messages:
    with st.chat_message(item["role"]):
        st.markdown(item["content"])
        if item.get("sources"):
            with st.expander("Sources"):
                for source in item["sources"]:
                    st.write(f"{source['source']} (page {source.get('page')})")
                    st.caption(source["preview"])


prompt = st.chat_input("Ask a question about your uploaded PDFs...")
if prompt:
    st.session_state.messages.append({"role": "user", "content": prompt})
    with st.chat_message("user"):
        st.markdown(prompt)

    provider_config = {"provider": provider, "model": selected_model}
    if provider == "openai_compatible":
        provider_config.update({"base_url": base_url, "api_key": api_key})

    with st.chat_message("assistant"):
        with st.spinner("Thinking with retrieved context..."):
            try:
                result = api_post(
                    "/chat",
                    json={
                        "session_id": st.session_state.session_id,
                        "message": prompt,
                        "provider_config": provider_config,
                    },
                )
                st.session_state.session_id = result["session_id"]
                st.markdown(result["answer"])
                with st.expander("Sources"):
                    for source in result["sources"]:
                        st.write(f"{source['source']} (page {source.get('page')})")
                        st.caption(source["preview"])
                if result["cached"]:
                    st.caption("Served from Redis cache.")
                st.session_state.messages.append(
                    {
                        "role": "assistant",
                        "content": result["answer"],
                        "sources": result["sources"],
                    }
                )
            except Exception as exc:
                st.error(f"Chat request failed: {exc}")
