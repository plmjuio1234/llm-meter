# LLM Meter for Windows 11

Windows 11 uses a native WinUI 3 dashboard and a packaged Win32 Windows
Widgets provider. Both surfaces consume the same credential-free,
versioned snapshot projection from `LLMMeter.Core`.

## Current implementation

- `LLMMeter.Core` validates the normalized account snapshot and produces
  Adaptive Card JSON for small, medium, and large widget sizes.
- `LLMMeter.App` renders the account cards, freshness states, progress bars,
  account details, and the LLM Meter visual tokens in WinUI 3.
- `LLMMeter.WidgetProvider` registers the Windows Widgets COM provider using
  the official Windows App SDK provider contract.
- The app currently reads the checked-in fixture at
  `src/LLMMeter.App/Assets/usage-snapshot.json` and mirrors the sanitized
  projection to `%LocalAppData%\\LLMMeter\\usage-snapshot.json`.
- Provider OAuth/API-key adapters and Windows Credential Manager integration
  are intentionally behind this snapshot boundary; no credential material is
  included in the fixture or widget payload.

## Build on Windows 11

Requirements:

- Windows 11
- Visual Studio 2022 with the Windows App SDK workload
- .NET 8 SDK
- x64 or ARM64 Windows target

Run from PowerShell:

```powershell
dotnet restore .\Windows\LLMMeter.Windows.sln
dotnet test .\Windows\tests\LLMMeter.Core.Tests\LLMMeter.Core.Tests.csproj
dotnet build .\Windows\src\LLMMeter.App\LLMMeter.App.csproj -c Release -p:Platform=x64
dotnet build .\Windows\src\LLMMeter.WidgetProvider\LLMMeter.WidgetProvider.csproj -c Release -p:Platform=x64
```

Install both packaged projects from Visual Studio to register the dashboard
and the Windows Widgets provider. The provider package must be installed
alongside the app package for the widget to appear in the Widgets Board.

The Windows widget provider follows Microsoft's packaged Win32 provider
contract:

<https://learn.microsoft.com/en-us/windows/apps/develop/widgets/widget-providers>
