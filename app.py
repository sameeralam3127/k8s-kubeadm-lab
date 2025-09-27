import streamlit as st
from core.retriever import retriever
from core.llm import chatbot
from config.settings import settings
import time

# Page configuration
st.set_page_config(
    page_title="Business Ops Chatbot",
    page_icon="💼",
    layout="wide"
)

st.title("💼 Business Operations Assistant")
st.caption("Ask me about IT support, HR policies, onboarding, or office facilities")

# Sidebar
with st.sidebar:
    st.header("⚙️ Settings")
    
    if st.button("🗑️ Clear Chat History"):
        st.session_state.messages = []
        st.rerun()
    
    st.markdown("---")
    st.subheader("Debug Info")
    if st.checkbox("Show retrieval details"):
        st.session_state.show_debug = True
    else:
        st.session_state.show_debug = False

# Initialize chat history
if "messages" not in st.session_state:
    st.session_state.messages = [
        {"role": "assistant", "content": "Hello! I'm here to help with business operations. What can I assist you with today?"}
    ]

# Display chat messages
for message in st.session_state.messages:
    with st.chat_message(message["role"]):
        st.markdown(message["content"])

# Chat input
if prompt := st.chat_input("Ask about IT, HR, facilities, or onboarding..."):
    # Add user message to chat history
    st.session_state.messages.append({"role": "user", "content": prompt})
    
    # Display user message
    with st.chat_message("user"):
        st.markdown(prompt)
    
    # Retrieve relevant documents
    with st.spinner("🔍 Searching knowledge base..."):
        start_time = time.time()
        try:
            documents = retriever.invoke(prompt)
            retrieval_time = time.time() - start_time
        except Exception as e:
            st.error(f"Retrieval error: {e}")
            documents = []
            retrieval_time = 0
    
    # Show debug info if enabled
    if st.session_state.get("show_debug", False):
        with st.expander("📊 Retrieval Details"):
            st.write(f"⏱️ Retrieval time: {retrieval_time:.2f}s")
            st.write(f"📄 Documents found: {len(documents)}")
            for i, doc in enumerate(documents):
                st.write(f"**Doc {i+1}:** {doc.page_content[:150]}...")
    
    # Generate assistant response
    with st.chat_message("assistant"):
        message_placeholder = st.empty()
        full_response = ""
        
        try:
            # Stream the response
            start_time = time.time()
            response = chatbot.generate_response(prompt, documents, st.session_state.messages)
            
            # Simulate streaming
            for chunk in response.split():
                full_response += chunk + " "
                message_placeholder.markdown(full_response + "▌")
                time.sleep(0.05)
            
            generation_time = time.time() - start_time
            message_placeholder.markdown(full_response)
            
            if st.session_state.get("show_debug", False):
                st.caption(f"⏱️ Generation time: {generation_time:.2f}s")
                
        except Exception as e:
            error_msg = f"Sorry, I encountered an error: {str(e)}"
            message_placeholder.error(error_msg)
            full_response = error_msg
    
    # Add assistant response to chat history
    st.session_state.messages.append({"role": "assistant", "content": full_response})