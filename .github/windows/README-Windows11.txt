LLM Meter Windows 11 preview

1. Extract this archive.
2. Open PowerShell in the extracted folder.
3. Run:

   powershell -ExecutionPolicy Bypass -File .\Install-LLMMeter.ps1

The package is signed with the included test certificate so it can be
installed for local evaluation. This is not a Microsoft Store or Developer ID
certificate. The dashboard and widget provider are separate MSIX packages and
both are installed by the script.

After installation:

- Launch "LLM Meter" from the Start menu.
- Open the Windows 11 Widgets Board with Win+W.
- Add the "LLM Meter" widget.

This preview reads the checked-in sanitized fixture and mirrors it to
%LocalAppData%\LLMMeter\usage-snapshot.json. Provider OAuth and API-key
adapters are not included in this preview.
