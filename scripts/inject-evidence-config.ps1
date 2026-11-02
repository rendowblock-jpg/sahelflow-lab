# Writes .sf-lab-tauri.json = the checked-in tauri.conf.json + a WebView2 debug port + no updater artifacts.
# These are the ONLY declared differences between the lab's evidence MSI and the release MSI (plus CI trial keys, loopback issuer URL).
param([Parameter(Mandatory = $true)][string]$ProductDir, [int]$DebugPort = 9222)
$ErrorActionPreference = 'Stop'
$conf = Get-Content -LiteralPath (Join-Path $ProductDir 'src-tauri/tauri.conf.json') -Raw | ConvertFrom-Json
$checked = $conf.app.windows[0].additionalBrowserArgs
$base = if ([string]::IsNullOrWhiteSpace($checked)) { '--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection' } else { "$($checked.Trim())" }
$args2 = "$base --remote-debugging-port=$DebugPort --remote-allow-origins=http://127.0.0.1:$DebugPort"
$conf.app.windows[0] | Add-Member -NotePropertyName additionalBrowserArgs -NotePropertyValue $args2 -Force
$conf.bundle.createUpdaterArtifacts = $false
$conf | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $ProductDir '.sf-lab-tauri.json') -Encoding UTF8
Write-Host "inject: ok (debug port $DebugPort)"
