LLM Meter Windows 11 preview

1. Extract this archive.
2. Open PowerShell in the extracted folder.
3. Run:

   powershell -ExecutionPolicy Bypass -File .\Install-LLMMeter.ps1

The package is signed with the included test certificate so it can be
installed for local evaluation. This is not a Microsoft Store or production
certificate.

After installation:

- LLM Meter starts in the taskbar notification area's hidden-icons menu.
- Click the LLM Meter tray icon to show or hide the dashboard.
- Right-click the tray icon and choose Exit to stop the app.

This preview reads the checked-in sanitized fixture and mirrors it to
%LocalAppData%\LLMMeter\usage-snapshot.json. Provider OAuth and API-key
adapters are not included in this preview.
