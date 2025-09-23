import streamlit as st
from langchain_ollama.llms import OllamaLLM
from langchain_core.prompts import ChatPromptTemplate
from vector import retriever

# Load model
model = OllamaLLM(model="llama3.1:8b")

# Prompt template
template = """
You are a helpful assistant for company employees.
Answer questions about IT, HR, onboarding, and office policies
based only on the provided knowledge base.

Relevant documents:
{docs}

Question:
{question}
"""
prompt = ChatPromptTemplate.from_template(template)
chain = prompt | model

# Streamlit UI setup
st.set_page_config(page_title="Business Ops Chatbot", page_icon="🏢", layout="centered")

st.title("🏢 Business Operations Assistant")
st.write("Ask me anything about IT support, HR policies, onboarding, or office facilities.")

# Input box
question = st.text_input("Enter your question:")

if question:
    with st.spinner("Looking up the knowledge base..."):
        # Retrieve top documents
        docs = retriever.invoke(question)
        docs_text = "\n".join([d.page_content[:500] for d in docs])  # truncate to keep prompt small

        # Stream output cleanly in one box
        placeholder = st.empty()
        response = ""

        for chunk in chain.stream({"docs": docs_text, "question": question}):
            response += chunk
            placeholder.write(response)  # updates text in place (typing effect)

        st.success("Done!")
