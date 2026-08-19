# LLM Meter

<p align="center">
  <img src="LLMUsageApp/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png" width="160" alt="LLM Meter logo">
</p>

Privacy-first macOS menu-bar app for monitoring LLM quotas, balances, and
account freshness across multiple accounts.

## Current status

- macOS release: `v1.0.0`
- Windows preview: [`v1.2.1-windows11-tray-fix-preview`](https://github.com/plmjuio1234/llm-meter/releases/tag/v1.2.1-windows11-tray-fix-preview)
- Platform: macOS 14+ and Windows 11
- Windows support: self-contained x64 WinUI 3 EXE with a notification-area tray app
- Provider access: official APIs only

## Features

- Multiple independent provider accounts
- OpenAI and Anthropic OAuth connections
- API-key usage and balance surfaces for supported providers
- Explicit unsupported states when an official usage surface is unavailable
- Account-card ordering and per-account detail windows
- macOS menu-bar dashboard and WidgetKit snapshot

macOS credentials stay in Keychain; Windows credentials use DPAPI CurrentUser.
The widget and Windows dashboard render sanitized snapshots only. This project
does not scrape consumer pages, private console pages, browser cookies, or
prompt traffic.

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

## Windows 11

The Windows port lives under [`Windows/`](Windows/). It uses a self-contained
unpackaged x64 WinUI 3 EXE for the dashboard, stays resident in the Windows 11
taskbar notification area, and supports OpenAI/Anthropic browser PKCE OAuth.
Click the hidden tray icon to show or hide the dashboard.

See [`Windows/README.md`](Windows/README.md) for Windows 11 prerequisites and
build commands.

## Security boundary

- Never commit API keys, OAuth tokens, cookies, credential dumps, or usage
  snapshots containing private data.
- Credentials are stored by the host app in Keychain only.
- The widget never reads Keychain or calls provider APIs.
- Provider integrations must use documented, provider-owned API surfaces.

## License

LLM Meter is released under the MIT License. See [LICENSE](LICENSE).
