# usage: walk-probe.ps1 -MsiDir msi-base -Port 9222. Installs an evidence MSI fresh, starts it, waits for the app's own ui-ready, runs the CDP probe.
param([string]$MsiDir = 'msi-base', [int]$Port = 9222)
$ErrorActionPreference = 'Continue'
$dataRoots = @((Join-Path $env:LOCALAPPDATA 'com.sahelflow.desktop'), (Join-Path $env:APPDATA 'com.sahelflow.desktop'))
$exe = Join-Path $env:ProgramFiles 'SahelFlow\sahelflow.exe'
function Get-Trace {
  foreach ($r in $dataRoots) {
    $p = Join-Path $r 'startup-trace.json'
    if (Test-Path $p) { try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch {} }
  }
  return $null
}
$msi = (Get-ChildItem $MsiDir -Recurse -Filter *.msi | Select-Object -First 1).FullName
if (-not $msi) { Write-Host "walk: fail (no msi)"; exit 1 }
New-Item -ItemType Directory -Force -Path out/assets, out/shots | Out-Null
Copy-Item $msi out/assets/
& ./scripts/install-msi.ps1
$issuer = Get-ChildItem $MsiDir -Recurse -Filter phase4-ci-trial-issuer.mjs | Select-Object -First 1
$issuerUp = $false
if ($issuer) {
  Start-Process node -ArgumentList @($issuer.FullName, '--serve', '8787', '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20') -WindowStyle Hidden | Out-Null
  Start-Sleep -Seconds 3
  try { $h = Invoke-RestMethod 'http://127.0.0.1:8787/health' -TimeoutSec 3; $issuerUp = [bool]$h.ok } catch {}
}
Write-Host "walk: trial issuer up $issuerUp"
$startMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$t0 = Get-Date
$p = Start-Process -FilePath $exe -PassThru
$sampler = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', 'scripts/sampler.ps1') -WindowStyle Hidden -PassThru
$diskp = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', 'scripts/diskprobe.ps1') -WindowStyle Hidden -PassThru
$mode = ''
try { $mode = [string](Get-Content runs/wp.json -Raw | ConvertFrom-Json).mode } catch {}
Write-Host "walk: mode '$mode'"
# mode pages3early: find the app's local server port, then start the early request probe (scripts/early.mjs) in its own process
$early = $null
if ($mode -eq 'pages3early') {
  $found = @()
  $tp = Get-Date
  while (((Get-Date) - $tp).TotalSeconds -lt 120 -and $found.Count -eq 0) {
    $ids = @(Get-Process -Name node -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*SahelFlow*' } | ForEach-Object { $_.Id })
    if ($ids.Count -gt 0) {
      foreach ($l in (netstat -ano -p tcp)) {
        if ($l -match 'TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$' -and ($ids -contains [int]$Matches[2])) { $found += $Matches[1] }
      }
    }
    if ($found.Count -eq 0) { Start-Sleep -Milliseconds 200 }
  }
  Write-Host "walk: early probe ports [$($found -join ',')] after $([math]::Round(((Get-Date) - $tp).TotalSeconds, 1)) s"
  if ($found.Count -gt 0) {
    $early = Start-Process node -ArgumentList @('scripts/early.mjs', ($found -join ','), '660', "$Port") -WindowStyle Hidden -PassThru -RedirectStandardOutput out/early.log -RedirectStandardError out/early.err
  }
  ([ordered]@{ launchMs = $startMs; portsFoundAfterS = [math]::Round(((Get-Date) - $t0).TotalSeconds, 2); ports = @($found) } | ConvertTo-Json -Compress) | Set-Content out/early-meta.json
}
$ready = $false
while (((Get-Date) - $t0).TotalSeconds -lt 300) {
  $tr = Get-Trace
  if ($tr -and $tr.events -and $tr.events.Count -gt 0 -and $tr.events[0].createdAtUnixMilliseconds -ge ($startMs - 5000) -and ($tr.events | Where-Object { $_.stage -eq 'ui-ready' })) { $ready = $true; break }
  if (-not (Get-Process -Name sahelflow -ErrorAction SilentlyContinue)) { break }
  Start-Sleep -Milliseconds 800
}
$uiSeenMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
Write-Host "walk: ui-ready seen at unix ms $uiSeenMs (launch $startMs)"
if ($mode -eq 'pages3early') {
  ([ordered]@{ launchMs = $startMs; uiReadySeenMs = $uiSeenMs; ready = $ready; readyAfterS = [math]::Round(((Get-Date) - $t0).TotalSeconds, 2) } | ConvertTo-Json -Compress) | Set-Content out/early-meta2.json
  $ri = 0
  foreach ($r in $dataRoots) { $p0 = Join-Path $r 'startup-trace.json'; if (Test-Path $p0) { Copy-Item $p0 "out/trace-at-ready-root$ri.json" }; $ri++ }
}
Write-Host "walk: ui-ready $ready after $([math]::Round(((Get-Date) - $t0).TotalSeconds, 1)) s"
Start-Sleep -Seconds 3
node scripts/stall2.mjs $Port
if ($early) { Wait-Process -Id $early.Id -Timeout 700 -ErrorAction SilentlyContinue }
New-Item -ItemType File -Force -Path out/sampler.stop | Out-Null
Start-Sleep -Seconds 3
Get-ChildItem $dataRoots[0] -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(startup-trace|runtime-ui-diagnostic).*\.json$' } | ForEach-Object { Copy-Item $_.FullName (Join-Path 'out' $_.Name) }
if ($mode -eq 'pages3early') {
  # the old copy above only looks in the first data folder; the trace may sit in the second one or deeper: copy from both, flattened names
  $ri = 0
  foreach ($r in $dataRoots) {
    Get-ChildItem $r -Recurse -Depth 3 -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(startup-trace|runtime-ui-diagnostic).*\.json$' } | ForEach-Object {
      $rel = $_.FullName.Substring($r.Length).TrimStart('\') -replace '[\\/]', '__'
      Copy-Item $_.FullName (Join-Path 'out' "root$ri--$rel")
    }
    $ri++
  }
}
Get-Process -Name sahelflow, sahelflow-whatsapp -ErrorAction SilentlyContinue | ForEach-Object { [void]$_.CloseMainWindow() }
Get-Process -Name node -ErrorAction SilentlyContinue | Where-Object { $_.Path -notlike '*SahelFlow*' } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 4
Get-Process -Name sahelflow, sahelflow-whatsapp -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item out/assets -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "walk: done"
