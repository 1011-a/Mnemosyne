# Mnemosyne

Mnemosyne is a macOS personal-knowledge app. It ingests local files into a searchable knowledge base, keeps embeddings on-device with Apple's Natural Language framework, and uses a configurable agent brain to answer questions with citations.

## What It Does

- Ingests folders, dragged files, and Safari bookmark exports.
- Extracts text from Markdown, code, PDFs, images, HTML/RTF/Word documents, CSV/JSON, email, contacts, calendar files, subtitles, OPML, and web location files.
- Uses local embeddings for semantic search and hybrid keyword search.
- Answers with source citations through DeepSeek chat or agentic tool-calling mode.
- Uses local Ollama/Gemma for image and scanned-PDF understanding by default.
- Optionally uses Claude CLI or Codex CLI for richer image/PDF/document extraction.

## Requirements

- macOS 14 or newer.
- Swift 6 toolchain / recent Xcode.
- Optional: [XcodeGen](https://github.com/yonaskolb/XcodeGen) for regenerating the UI-test Xcode project.
- Optional: Ollama with `gemma3:12b` for local multimodal ingest.
- Optional: DeepSeek API key for chat/agent answers.
- Optional: authenticated `claude` or `codex` CLI for external multimodal ingest.

## Quick Start

```bash
swift test
./scripts/make-app.sh
open build/Mnemosyne.app
```

Then open Settings and add a DeepSeek API key. The key is stored in macOS Keychain.

For development overrides, copy `.env.example` to `.env` and launch with:

```bash
MNEMOSYNE_ENV_PATH=.env swift run Mnemosyne
```

Environment variables override Settings/Keychain. The app intentionally has no personal default env-file path.

## Building

SwiftPM is the source of truth:

```bash
swift build
swift test
```

To create a double-clickable app bundle:

```bash
./scripts/make-app.sh
```

The script accepts optional metadata overrides:

```bash
MNEMOSYNE_BUNDLE_ID=org.example.mnemosyne MNEMOSYNE_VERSION=1.0.0 ./scripts/make-app.sh
```

To regenerate and run UI tests:

```bash
./scripts/uitest.sh
```

## Live Tests

Normal tests do not spend API or CLI quota. Live tests require explicit opt-in:

```bash
MNEMO_LIVE_DEEPSEEK=1 swift test --filter Live
MNEMO_LIVE_CLAUDE=1 swift test --filter ClaudeVisionLiveTests
MNEMO_LIVE_CODEX=1 swift test --filter CodexVisionLiveTests
```

## Codex Pet

This repository includes the matching Memo Codex Pet under [`codex-pet/memo`](codex-pet/memo). To install it locally:

```bash
mkdir -p "${CODEX_HOME:-$HOME/.codex}/pets/memo"
cp codex-pet/memo/pet.json codex-pet/memo/spritesheet.webp "${CODEX_HOME:-$HOME/.codex}/pets/memo/"
```

## Privacy

By default, file parsing, embeddings, and Gemma/Ollama multimodal extraction run locally. DeepSeek answers send the question, selected conversation context, and retrieved snippets to the configured DeepSeek-compatible endpoint. Claude CLI and Codex CLI ingest modes may send selected files or rendered images/PDFs through those tools according to the user's local CLI configuration.

See [PRIVACY.md](PRIVACY.md) for the full data-flow notes.

## Project Layout

- `Sources/Mnemosyne`: app, extraction, ingestion, search, agents, and SwiftUI views.
- `Tests/MnemosyneTests`: unit and integration tests.
- `UITests`: XCUITest coverage.
- `DesignKit`: design-system reference cards and tokens.
- `codex-pet`: packaged Codex Pet assets for Memo.
- `scripts`: app bundling, icon generation, and UI-test helpers.

## License

Mnemosyne source code and documentation are licensed under the Apache License 2.0. See [LICENSE](LICENSE).

The Memo Codex Pet artwork and media files under `codex-pet/memo` are licensed under Creative Commons Attribution 4.0 International. See [codex-pet/memo/LICENSE](codex-pet/memo/LICENSE).
