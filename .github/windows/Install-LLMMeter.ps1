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
if ($packages.Count -lt 2) {
    throw "Expected dashboard and widget provider packages in $PackageDirectory."
}

$dashboard = $packages |
    Where-Object { $_.BaseName -match "App" -and $_.BaseName -notmatch "WidgetProvider" } |
    Select-Object -First 1
$widgetProvider = $packages |
    Where-Object { $_.BaseName -match "WidgetProvider" } |
    Select-Object -First 1
$dependencies = @(
    $packages |
        Where-Object { $_.FullName -ne $dashboard.FullName -and $_.FullName -ne $widgetProvider.FullName } |
        ForEach-Object FullName
)

foreach ($package in @($dashboard, $widgetProvider)) {
    if ($null -eq $package) {
        continue
    }

    $arguments = @{
        Path = $package.FullName
        ForceApplicationShutdown = $true
    }
    if ($dependencies.Count -gt 0) {
        $arguments.DependencyPath = $dependencies
    }
    Add-AppxPackage @arguments
}

Write-Host "LLM Meter Windows 11 packages installed."
Write-Host "Open LLM Meter from the Start menu, then add the LLM Meter widget from the Widgets Board."
