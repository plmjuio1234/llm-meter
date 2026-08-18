# LLM Meter

Privacy-first macOS menu-bar app for monitoring LLM quotas, balances, and
account freshness across multiple accounts.

## Current status

- Release: `v1.0.0`
- Platform: macOS 14+
- Windows support: planned
- Provider access: official APIs only

## Features

- Multiple independent provider accounts
- OpenAI and Anthropic OAuth connections
- API-key usage and balance surfaces for supported providers
- Explicit unsupported states when an official usage surface is unavailable
- Account-card ordering and per-account detail windows
- macOS menu-bar dashboard and WidgetKit snapshot

Credentials stay in the macOS Keychain. The widget reads sanitized shared
snapshots only. This project does not scrape consumer pages, private console
pages, browser cookies, or prompt traffic.

## Supported provider surfaces

- OpenAI OAuth usage and quota surfaces
- Anthropic OAuth usage and quota surfaces
- Moonshot/Kimi, DeepSeek, and OpenRouter official API-key surfaces
- GLM/Zhipu, MiniMax, and Qwen API-key connections with explicit unsupported
  usage state until an official account-wide usage endpoint is available

## Build

Requirements:

- macOS 14 or later
- Xcode with Swift 6 support

Build the app:

```bash
xcodebuild \
  -project LLMUsage.xcodeproj \
  -scheme LLMUsageApp \
  -configuration Release \
  -destination 'platform=macOS' \
  build
```

Run the shared core tests:

```bash
swift test --package-path Shared/UsageCore
```

The app is generated under
`build/Build/Products/Release/LLMUsageApp.app` when using the default derived
data path. Unsigned local builds may require Finder's **Open** action on first
launch.

## Security boundary

- Never commit API keys, OAuth tokens, cookies, credential dumps, or usage
  snapshots containing private data.
- Credentials are stored by the host app in Keychain only.
- The widget never reads Keychain or calls provider APIs.
- Provider integrations must use documented, provider-owned API surfaces.

## License

LLM Meter is released under the MIT License. See [LICENSE](LICENSE).
