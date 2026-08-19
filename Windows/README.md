# LLM Meter for Windows 11

Windows 11 uses a WinUI 3 dashboard that stays resident in the taskbar
notification area. Click the LLM Meter icon in the hidden-icons menu to show
or hide the dashboard.

## Current implementation

- `LLMMeter.Core` validates the normalized account snapshot and produces
  the credential-free local snapshot projection, PKCE values, and OpenAI/
  Anthropic usage response parsing.
- `LLMMeter.App` renders the account cards, freshness states, progress bars,
  account details, connect actions, and the LLM Meter visual tokens in WinUI
  3. It owns the notification-area tray icon, dashboard toggle, OAuth
  loopback listener, provider refresh, DPAPI credential store, and Exit menu.
- OpenAI ChatGPT/Codex and Anthropic Claude use browser PKCE OAuth and their
  official usage endpoints. Credentials are encrypted for the current Windows
  user and sanitized usage is written to
  `%LocalAppData%\\LLMMeter\\usage-snapshot.json`.
- The Windows package no longer ships a checked-in fixture as runtime data.
  Live provider endpoint/schema behavior is not validated by CI and must be
  tested with the user's account on Windows.

## Build on Windows 11

Requirements:

- Windows 11
- Visual Studio 2022 with the Windows App SDK workload
- .NET 8 SDK
- x64 Windows target

Run from PowerShell:

```powershell
dotnet restore .\Windows\LLMMeter.Windows.sln
dotnet test .\Windows\tests\LLMMeter.Core.Tests\LLMMeter.Core.Tests.csproj
dotnet build .\Windows\src\LLMMeter.App\LLMMeter.App.csproj -c Release -p:Platform=x64
```

The release archive is a self-contained unpackaged x64 EXE bundle. Extract
the complete archive and run `LLMMeter.App.exe`; no MSIX certificate import or
PowerShell installer is required. The app starts resident in the notification
area; Windows may place it behind the taskbar hidden-icons arrow according to
the user's notification-area settings.
The app activates the dashboard window before registering the native tray icon.
If Windows rejects tray registration, the dashboard remains visible and writes
a redacted diagnostic to `%LocalAppData%\\LLMMeter\\startup.log`.

Use **Connect OpenAI** or **Connect Claude** to start browser OAuth, then
**Refresh** to request current usage. The release is unsigned, so SmartScreen
may show an unknown-publisher warning.
