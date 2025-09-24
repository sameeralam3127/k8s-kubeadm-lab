# 🏢 Business Operations Chatbot

An internal AI assistant for employees. It answers questions about **IT support, HR policies, onboarding, and office facilities** using your company’s knowledge base.
Built with **Streamlit**, **LangChain**, **Ollama**, and **Chroma**.

---

## 🚀 Features

- Conversational **chat UI** powered by Streamlit
- Uses **Ollama LLM** for natural responses
- Knowledge-grounded with **Chroma vector database**
- Avoids hallucinations → if info is missing, suggests next steps
- Supports **rebuildable knowledge base** from FAQ text file

---

## 📂 Project Structure

```
.
├── app.py          # Streamlit chatbot UI
├── build.py        # Build vector DB from FAQ file
├── run.py          # Auto-build DB (if missing) & launch app
├── vector.py       # Retriever & vector store config
├── complete_internal_knowledge_base.txt  # FAQ file
├── chroma_ops_db/  # Persisted Chroma database
```

---

## ⚙️ Prerequisites

1. **Install Ollama** → [https://ollama.ai](https://ollama.ai)
   Make sure you have the models installed:

   ```bash
   ollama pull llama3.1:8b
   ollama pull mxbai-embed-large
   ```

2. **Python 3.10+**
   Recommended: use a virtual environment.

3. **Install dependencies**

   ```bash
   pip install -r requirements.txt
   ```

### Example `requirements.txt`

```txt
streamlit
langchain
langchain-ollama
langchain-chroma
```

---

## 🛠️ Setup

### 1. Prepare Knowledge Base

Edit `complete_internal_knowledge_base.txt` with your company FAQs in **Q/A format**:

```
Q: How do I request a new laptop?
A: Requests are handled through the IT Portal...

Q: How do I book a meeting room?
A: Rooms are booked via Outlook or Google Calendar...
```

### 2. Build the Vector Database

Manually:

```bash
python build.py --file complete_internal_knowledge_base.txt --rebuild
```

Or automatically (with app launch):

```bash
python run.py
```

> If the DB doesn’t exist, it will be built automatically.

---

## 💬 Run the Chatbot

Start the app:

```bash
streamlit run app.py
```

Or use the shortcut:

```bash
python run.py
```

Then open [http://localhost:8501](http://localhost:8501) in your browser.

---

## ⚡ Configuration

Set environment variables to customize behavior:

| Variable          | Default                                | Description                            |
| ----------------- | -------------------------------------- | -------------------------------------- |
| `FAQ_FILE`        | `complete_internal_knowledge_base.txt` | Path to FAQ file                       |
| `DB_LOCATION`     | `./chroma_ops_db`                      | Directory for Chroma DB                |
| `COLLECTION_NAME` | `business_ops`                         | Chroma collection name                 |
| `OLLAMA_MODEL`    | `llama3.1:8b`                          | LLM model used for answering           |
| `EMBED_MODEL`     | `mxbai-embed-large`                    | Embedding model for Chroma             |
| `RETRIEVER_K`     | `5`                                    | Number of docs to retrieve             |
| `RETRIEVER_MODE`  | `similarity`                           | Retrieval type (`similarity` or `mmr`) |
| `REBUILD_DB`      | `false`                                | Set to `true` to rebuild DB at startup |

Example:

```bash
export RETRIEVER_K=3
export REBUILD_DB=true
python run.py
```

---

## 🔮 Future Enhancements

- Support **multiple FAQ files** or knowledge sources
- Add **user authentication** for internal-only access
- Show **source references** with each answer
- Deploy on an internal server with **Docker**

---

## 👩‍💻 Author

Built for internal company use with ❤️ using **Streamlit + LangChain + Ollama + Chroma**.
