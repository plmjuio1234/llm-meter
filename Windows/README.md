# LLM Meter for Windows 11

Windows 11 uses a WinUI 3 dashboard that stays resident in the taskbar
notification area. Click the LLM Meter icon in the hidden-icons menu to show
or hide the dashboard.

## Current implementation

- `LLMMeter.Core` validates the normalized account snapshot and produces
  the credential-free local snapshot projection.
- `LLMMeter.App` renders the account cards, freshness states, progress bars,
  account details, and the LLM Meter visual tokens in WinUI 3. It owns the
  notification-area tray icon, dashboard toggle, and Exit menu.
- The app currently reads the checked-in fixture at
  `src/LLMMeter.App/Assets/usage-snapshot.json` and mirrors the sanitized
  projection to `%LocalAppData%\\LLMMeter\\usage-snapshot.json`.
- Provider OAuth/API-key adapters and Windows Credential Manager integration
  are intentionally behind this snapshot boundary; no credential material is
  included in the fixture or shared snapshot.

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

Install the packaged app from Visual Studio or use the release archive's
`Install-LLMMeter.ps1` script. The app starts resident in the notification
area; Windows may place it behind the taskbar hidden-icons arrow according to
the user's notification-area settings.

This preview reads fixture data only. OpenAI/Anthropic OAuth and API-key
adapters are not included in the Windows package yet.
