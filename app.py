import streamlit as st
from langchain_ollama.llms import OllamaLLM
from langchain_core.prompts import ChatPromptTemplate
from vector import retriever

# -----------------------
# Setup
# -----------------------
st.set_page_config(page_title="Business Ops Chatbot", page_icon="🏢", layout="wide")

st.title("🏢 Business Operations Assistant")
st.caption("Ask me anything about IT support, HR policies, onboarding, or office facilities.")

# Initialize session state for chat history
if "messages" not in st.session_state:
    st.session_state["messages"] = [
        {"role": "assistant", "content": "Hello 👋 How can I help you today?"}
    ]

# Load model
model = OllamaLLM(model="llama3.1:8b")

# Prompt template
template = """
You are a helpful assistant for company employees.
Answer questions about IT, HR, onboarding, and office policies
based only on the provided knowledge base.

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
    # Add user message to history
    st.session_state["messages"].append({"role": "user", "content": question})

    # Show user message
    with st.chat_message("user"):
        st.markdown(question)

    # Retrieve relevant docs
    docs = retriever.invoke(question)
    docs_text = "\n".join([d.page_content[:500] for d in docs])  # truncate long docs

    # Build history text for context
    history_text = "\n".join([f"{m['role'].capitalize()}: {m['content']}" for m in st.session_state["messages"]])

    # Stream AI response
    with st.chat_message("assistant"):
        placeholder = st.empty()
        response = ""

        for chunk in chain.stream({"docs": docs_text, "question": question, "history": history_text}):
            response += chunk
            placeholder.markdown(response + "▌")  # typing effect

        placeholder.markdown(response)

    # Save AI response to history
    st.session_state["messages"].append({"role": "assistant", "content": response})
