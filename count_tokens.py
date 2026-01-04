import tiktoken
from langchain.text_splitter import RecursiveCharacterTextSplitter

text = open("sop.txt").read()

encoder = tiktoken.get_encoding("cl100k_base")
tokens = encoder.encode(text)

print("Total tokens:", len(tokens))
