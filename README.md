# LireAI

LireAI is a standalone EPUB reader for iPhone with AI-assisted reading features. It is built with **SwiftUI**, **Readium Swift Toolkit**, and **Metal**.

The app does **not** depend on a developer-operated backend or account system. Books, reading progress, and local caches stay on the device. AI features use the user's own Mistral API key and communicate directly with the Mistral API.

## Features

- EPUB reading with Readium
- Custom Metal page-curl animation
- Local library, reading progress, and page cache
- French-to-Chinese translation and vocabulary explanations
- Contextual follow-up questions
- Optional web search for current or external information
- Mistral API key stored in the iOS Keychain

## Install with Xcode

1. Clone the repository and open `LireAI.xcodeproj` in Xcode.
2. In **Signing & Capabilities**, select your own Apple Developer Team, change the Bundle Identifier if needed, and keep **Automatically manage signing** enabled.
3. Connect your iPhone, choose it as the run destination, and press **Run**.
4. Open LireAI and enter your own Mistral API key in Settings.

## Install with iLoader

A prebuilt `LireAI.ipa` is required.

1. Download `LireAI.ipa` from the GitHub Releases page.
2. Open iLoader, connect your iPhone, and sign in with your Apple ID.
3. Import the IPA and let iLoader sign and install it automatically.
4. Open LireAI and enter your own Mistral API key in Settings.

## Requirements

- iOS 18.4+
- Xcode for building from source
- A Mistral API key for AI features

## Privacy

LireAI has no developer-operated backend, telemetry service, or remote account system. EPUB files and reading state remain local. When an AI feature is used, the selected text, questions, and relevant conversation context are sent directly to Mistral using the API key configured by the user.

## License

MIT
