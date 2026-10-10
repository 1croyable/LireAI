# LireAI

LireAI is a standalone EPUB reader for iPhone with AI-assisted reading features. It is built with **SwiftUI**, **Readium Swift Toolkit**, and **Metal**.

The app does **not** depend on a developer-operated backend or account system. Books, reading progress, and local caches stay on the device. AI features communicate directly with the selected provider using the user's own API key. Supported providers are Gemini, Groq, OpenRouter, and Mistral.

<p align="center">
  <img src="Imgs/reading_page.png" alt="EPUB reading view" width="45%" />
  &nbsp;&nbsp;
  <img src="Imgs/word_search.png" alt="AI lookup view" width="45%" />
</p>

## Features

- EPUB reading with Readium
- Custom Metal page-curl animation
- Local library, reading progress, and page cache
- French-to-Chinese translation and vocabulary explanations
- Contextual follow-up questions
- Optional web search for current or external information
- Provider API keys stored in the iOS Keychain

## Install with Xcode

1. Clone the repository and open `LireAI.xcodeproj` in Xcode.
2. In **Signing & Capabilities**, select your own Apple Developer Team, change the Bundle Identifier if needed, and keep **Automatically manage signing** enabled.
3. Connect your iPhone, choose it as the run destination, and press **Run**.
4. Open LireAI, select an AI provider in Settings, save your API key, choose a model, and set that key as active. For Gemini, use a Google AI Studio key; the default model is Gemini 3.8 Flash. OpenRouter's model directory shows currently available free versions among the three supported candidates.

## Install with iLoader

A prebuilt `LireAI.ipa` is required.

1. Download `LireAI.ipa` from the GitHub Releases page.
2. Open iLoader, connect your iPhone, and sign in with your Apple ID.
3. Import the IPA and let iLoader sign and install it automatically.
4. Open LireAI and configure your chosen provider's API key and model in Settings.

## Requirements

- iOS 18.4+
- Xcode for building from source
- An API key for one of the supported AI providers
- An optional Brave Search API key for questions requiring web verification

## Privacy

LireAI has no developer-operated backend, telemetry service, or remote account system. EPUB files and reading state remain local. When an AI feature is used, the selected text, questions, and relevant conversation context are sent directly to the selected provider using the API key configured by the user. When web verification is needed, a search query is sent to Brave Search and the retrieved evidence is included in the AI request.

## License

MIT
