# 🏢 Business Operations Chatbot

An **AI-powered chatbot** for employees to ask questions about **IT support, HR, onboarding, and office facilities** using your company’s internal FAQ knowledge base.
Built with **LangChain**, **Ollama**, **ChromaDB**, and **Streamlit**.

---

## 📂 Project Structure

```
.
├── run.py                 # Entry point (builds DB + runs app)
├── build_db.py            # (Optional) standalone script to rebuild DB
├── vector.py              # Loads the Chroma retriever
├── app.py                 # Streamlit chatbot UI
├── f2442acc-5c9d-46ed...  # Internal FAQ text file
└── README.md              # Documentation
```

---

## 🚀 Features

- Uses **`llama3.1:8b`** for answering questions.
- Uses **`mxbai-embed-large`** for embeddings.
- Stores FAQ knowledge base in **Chroma vector DB**.
- Runs a **Streamlit app** for chatting.
- Auto-builds database if not already created.

---

## 🛠️ Installation

### 1. Clone the repo

```bash
git clone https://github.com/your-org/business-ops-chatbot.git
cd business-ops-chatbot
```

### 2. Install dependencies

Make sure you have **Python 3.10+**. Then:

```bash
pip install -r requirements.txt
```

Example `requirements.txt`:

```
streamlit
langchain
langchain-ollama
langchain-chroma
pandas
```

### 3. Install & run Ollama

Follow [Ollama installation](https://ollama.ai) for your system.
Pull the required models:

```bash
ollama pull llama3.1:8b
ollama pull mxbai-embed-large
```

---

## ▶️ Usage

Run everything in one command:

```bash
python run.py
```

This will:

1. Build the Chroma vector DB from your FAQ file (if it doesn’t already exist).
2. Launch the chatbot UI in Streamlit.

Open [http://localhost:8501](http://localhost:8501) in your browser.

---

## 💡 Example Questions

- _How do I reset my password?_
- _What is the work from home policy?_
- _How do I request a new laptop?_
- _Where can I find the onboarding checklist?_

---

## 🔄 Rebuilding the Database

If your FAQ file changes, you can force rebuild with:

```bash
rm -rf chroma_ops_db
python run.py
```

(or extend `run.py` to support a `--rebuild` flag).

---
