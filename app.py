import streamlit as st
from core.retriever import enhanced_retriever
from core.llm import chatbot
from config.settings import settings
import time

# -----------------------
# Setup with Caching
# -----------------------
st.set_page_config(page_title="Business Ops Chatbot", layout="wide")

@st.cache_resource
def initialize_components():
    """Cache expensive initializations"""
    return {
        "retriever": enhanced_retriever,
        "chatbot": chatbot
    }

# Initialize with caching
components = initialize_components()

st.title("🚀 Business Operations Assistant")
st.caption("Ask me anything about IT support, HR policies, onboarding, or office facilities.")

# Sidebar with enhanced controls
with st.sidebar:
    st.header("⚙️ Settings")
    
    if st.button("🔄 Clear Chat History"):
        st.session_state.messages = []
        st.rerun()
    
    st.subheader("Performance Options")
    retrieval_limit = st.slider("Documents to retrieve", 3, 10, 6)
    show_retrieval_info = st.checkbox("Show retrieval info", False)

# Initialize session state
if "messages" not in st.session_state:
    st.session_state.messages = [
        {"role": "assistant", "content": "Hello 👋 How can I help you with business operations today?"}
    ]

# Display chat history
for msg in st.session_state.messages:
    with st.chat_message(msg["role"]):
        st.markdown(msg["content"])

# User input
if question := st.chat_input("Type your question here..."):
    # Add user message
    st.session_state.messages.append({"role": "user", "content": question})
    
    with st.chat_message("user"):
        st.markdown(question)
    
    # Retrieval with timing
    with st.spinner("🔍 Searching knowledge base..."):
        start_time = time.time()
        docs = enhanced_retriever.get_relevant_documents(question)[:retrieval_limit]
        retrieval_time = time.time() - start_time
    
    # Display retrieval info if enabled
    if show_retrieval_info:
        with st.expander("📊 Retrieval Information"):
            st.write(f"⏱️ Retrieval time: {retrieval_time:.2f}s")
            st.write(f"📄 Documents found: {len(docs)}")
            for i, doc in enumerate(docs):
                st.write(f"**Doc {i+1}:** {doc.page_content[:200]}...")
    
    # Generate response with streaming
    with st.chat_message("assistant"):
        placeholder = st.empty()
        response = ""
        
        try:
            # Stream response
            start_time = time.time()
            for chunk in chatbot.chain.stream({
                "question": question,
                "docs": "\n\n".join([doc.page_content for doc in docs]),
                "history": "\n".join([
                    f"{m['role']}: {m['content']}" 
                    for m in st.session_state.messages[-4:]
                ])
            }):
                response += chunk
                placeholder.markdown(response + "▌")
            
            generation_time = time.time() - start_time
            placeholder.markdown(response)
            
            if show_retrieval_info:
                st.caption(f"⏱️ Generation time: {generation_time:.2f}s")
                
        except Exception as e:
            error_msg = f"⚠️ Error generating response: {str(e)}"
            placeholder.error(error_msg)
            response = error_msg
    
    # Add to history
    st.session_state.messages.append({"role": "assistant", "content": response})