# Privacy Notes

Mnemosyne is designed for local-first personal knowledge work, but some features intentionally call external services when enabled. This document summarizes the data flows to review before publishing or using the app with sensitive material.

## Local-Only By Default

- File scanning and parsing run on the Mac.
- The knowledge database is stored locally by `KnowledgeStore`.
- Embeddings use Apple's Natural Language framework locally.
- Gemma multimodal extraction uses the configured local Ollama endpoint, normally `http://127.0.0.1:11434`.
- DeepSeek API keys saved in Settings are stored in macOS Keychain.

## External Calls

- DeepSeek chat/agent mode sends the user's question, relevant chat history, tool instructions, and retrieved source snippets to the configured DeepSeek-compatible endpoint.
- Claude CLI ingest mode can pass images, PDFs, and documents to the locally installed `claude` CLI. What leaves the Mac depends on that CLI's account and configuration.
- Codex CLI ingest mode can pass images, PDFs, and documents to the locally installed `codex` CLI. What leaves the Mac depends on that CLI's account and configuration.
- If `MNEMOSYNE_ENV_PATH` is set, Mnemosyne reads that dotenv file for development overrides.

## Logs

Mnemosyne writes an ingest debug log at:

```text
~/Library/Logs/Mnemosyne/ingest.log
```

The log is meant to show which ingest engine ran and includes file names, engine names, and status messages. It should not include file contents or API keys.

## Recommendations For Sensitive Data

- Use the default Gemma/Ollama ingest engine for private files.
- Keep Claude CLI and Codex CLI ingest modes opt-in.
- Review retrieved snippets before sending highly sensitive questions to DeepSeek.
- Do not commit `.env`, build output, local databases, Xcode DerivedData, or `PROGRESS.md`.
