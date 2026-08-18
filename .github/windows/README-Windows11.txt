LLM Meter Windows 11 standalone preview

Release: https://github.com/plmjuio1234/llm-meter/releases/tag/v1.2.0-windows11-exe-preview

1. Extract the complete archive to a folder.
2. Run `LLMMeter.App.exe`.

The archive is a self-contained x64 Windows App SDK application. It is not
an MSIX package and does not require certificate installation, PowerShell
elevation, or a separate .NET runtime. Keep the extracted files together;
do not move only the EXE.

Because this preview is not code-signed, Windows SmartScreen may show an
unknown-publisher warning. Use More info and Run anyway only if you trust the
download source.

After installation:

- LLM Meter starts in the taskbar notification area's hidden-icons menu.
- Click the LLM Meter tray icon to show or hide the dashboard.
- Right-click the tray icon and choose Exit to stop the app.
- Use Connect OpenAI or Connect Claude to complete browser PKCE OAuth.
- Click Refresh to request current official provider usage.

OAuth access and refresh tokens are encrypted with the current Windows user's
DPAPI and are never written to the usage snapshot. The app does not scrape
provider pages or read browser cookies.
