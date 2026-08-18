param(
    [string]$PackageDirectory = (Join-Path $PSScriptRoot "Packages")
)

$ErrorActionPreference = "Stop"

$certificate = Get-ChildItem -Path $PackageDirectory -Filter "*.cer" -File | Select-Object -First 1
if ($null -eq $certificate) {
    throw "LLM Meter test certificate was not found in $PackageDirectory."
}

Import-Certificate `
    -FilePath $certificate.FullName `
    -CertStoreLocation "Cert:\CurrentUser\TrustedPeople" | Out-Null

$packages = Get-ChildItem -Path $PackageDirectory -File |
    Where-Object { $_.Extension -in ".msix", ".msixbundle", ".appx", ".appxbundle" }
if ($packages.Count -lt 1) {
    throw "Expected the LLM Meter package in $PackageDirectory."
}

$application = $packages |
    Where-Object { $_.BaseName -match "LLMMeter.App" } |
    Select-Object -First 1
if ($null -eq $application) {
    throw "The LLM Meter application package was not found in $PackageDirectory."
}

$dependencies = @(
    $packages |
        Where-Object { $_.FullName -ne $application.FullName } |
        ForEach-Object FullName
)

$arguments = @{
    Path = $application.FullName
    ForceApplicationShutdown = $true
}
if ($dependencies.Count -gt 0) {
    $arguments.DependencyPath = $dependencies
}
Add-AppxPackage @arguments

Write-Host "LLM Meter Windows 11 packages installed."
Write-Host "LLM Meter is now resident in the taskbar notification area."
Write-Host "Click the LLM Meter tray icon to open the dashboard."
