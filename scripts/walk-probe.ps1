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
$ready = $false
while (((Get-Date) - $t0).TotalSeconds -lt 300) {
  $tr = Get-Trace
  if ($tr -and $tr.events -and $tr.events.Count -gt 0 -and $tr.events[0].createdAtUnixMilliseconds -ge ($startMs - 5000) -and ($tr.events | Where-Object { $_.stage -eq 'ui-ready' })) { $ready = $true; break }
  if (-not (Get-Process -Name sahelflow -ErrorAction SilentlyContinue)) { break }
  Start-Sleep -Milliseconds 800
}
Write-Host "walk: ui-ready $ready after $([math]::Round(((Get-Date) - $t0).TotalSeconds, 1)) s"
Start-Sleep -Seconds 3
node scripts/stall2.mjs $Port
New-Item -ItemType File -Force -Path out/sampler.stop | Out-Null
Start-Sleep -Seconds 3
Get-ChildItem $dataRoots[0] -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(startup-trace|runtime-ui-diagnostic).*\.json$' } | ForEach-Object { Copy-Item $_.FullName (Join-Path 'out' $_.Name) }
Get-Process -Name sahelflow, sahelflow-whatsapp -ErrorAction SilentlyContinue | ForEach-Object { [void]$_.CloseMainWindow() }
Get-Process -Name node -ErrorAction SilentlyContinue | Where-Object { $_.Path -notlike '*SahelFlow*' } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 4
Get-Process -Name sahelflow, sahelflow-whatsapp -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
# bk2 (x15) only: integrity of the live shop DB(s) after the run, and the size of what the backups left in Downloads\SahelFlow Backups
$cfgMode = ''; try { $cfgMode = (Get-Content runs/wp.json -Raw | ConvertFrom-Json).mode } catch {}
if ($cfgMode -eq 'bk2') {
  try { python scripts/check-db.py bk2 | Out-File -Encoding utf8 out/dbcheck.json } catch { Write-Host "dbcheck: error $_" }
  try {
    $bd = Join-Path $env:USERPROFILE 'Downloads\SahelFlow Backups'
    $rows = @()
    if (Test-Path $bd) { $rows = @(Get-ChildItem $bd -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ rel = $_.FullName.Substring($bd.Length + 1); bytes = $_.Length; last = $_.LastWriteTimeUtc.ToString('o') } }) }
    ConvertTo-Json -InputObject $rows -Depth 3 | Out-File -Encoding utf8 out/backups.json
    Write-Host "bk2: backup files $($rows.Count)"
  } catch { Write-Host "backups listing: error $_" }
}
Remove-Item out/assets -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "walk: done"
