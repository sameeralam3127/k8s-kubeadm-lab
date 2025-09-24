import streamlit as st
from langchain_ollama.llms import OllamaLLM
from langchain_core.prompts import ChatPromptTemplate
from vector import retriever
import os

# -----------------------
# Setup
# -----------------------
st.set_page_config(page_title="Business Ops Chatbot", page_icon="🏢", layout="wide")

st.title("🏢 Business Operations Assistant")
st.caption("Ask me anything about IT support, HR policies, onboarding, or office facilities.")

# Sidebar controls
with st.sidebar:
    st.header("⚙️ Settings")
    if st.button("Clear Chat"):
        st.session_state["messages"] = []
        st.rerun()
    st.markdown("Adjust retriever and model settings in environment variables.")

# Initialize session state for chat history
if "messages" not in st.session_state:
    st.session_state["messages"] = [
        {"role": "assistant", "content": "Hello 👋 How can I help you today?"}
    ]

# Load model
model_name = os.getenv("OLLAMA_MODEL", "llama3.1:8b")
model = OllamaLLM(model=model_name)

# Prompt template
template = """
You are a helpful assistant for company employees.
Use ONLY the provided knowledge base documents to answer questions.
- If the question is in the knowledge base, answer directly and clearly.
- If the information is missing, do NOT make up answers. Instead:
   1. Politely say it is not in the knowledge base.
   2. Suggest where the employee can go for more help (e.g., IT Help Desk, HR, or Facilities).
   3. Encourage them to check the company intranet or contact the relevant team.

Conversation so far:
{history}

Relevant documents:
{docs}

Latest question:
{question}
"""


prompt = ChatPromptTemplate.from_template(template)
chain = prompt | model

# -----------------------
# Chat display (re-render history)
# -----------------------
for msg in st.session_state["messages"]:
    with st.chat_message(msg["role"]):
        st.markdown(msg["content"])

# -----------------------
# User input
# -----------------------
if question := st.chat_input("Type your question here..."):
    st.session_state["messages"].append({"role": "user", "content": question})

    with st.chat_message("user"):
        st.markdown(question)

    # Retrieve relevant docs
    try:
        docs = retriever.invoke(question)
    except Exception as e:
        st.error(f"⚠️ Retrieval error: {e}")
        docs = []

    if not docs:
        docs_text = "No relevant documents found."
    else:
        docs_text = "\n".join(
            [d.page_content.strip()[:500] for d in docs]
        )

    # Limit history to last 5 messages for context
    history_text = "\n".join(
        f"{m['role'].capitalize()}: {m['content']}"
        for m in st.session_state["messages"][-5:]
    )

    # Stream AI response
    with st.chat_message("assistant"):
        placeholder = st.empty()
        response = ""
        try:
            for chunk in chain.stream(
                {"docs": docs_text, "question": question, "history": history_text}
            ):
                response += chunk
                placeholder.markdown(response + "▌")
            placeholder.markdown(response)
        except Exception as e:
            response = f"⚠️ Error generating response: {e}"
            placeholder.error(response)

    st.session_state["messages"].append({"role": "assistant", "content": response})
