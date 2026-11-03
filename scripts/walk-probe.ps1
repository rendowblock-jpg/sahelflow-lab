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
$ready = $false
while (((Get-Date) - $t0).TotalSeconds -lt 300) {
  $tr = Get-Trace
  if ($tr -and $tr.events -and $tr.events.Count -gt 0 -and $tr.events[0].createdAtUnixMilliseconds -ge ($startMs - 5000) -and ($tr.events | Where-Object { $_.stage -eq 'ui-ready' })) { $ready = $true; break }
  if (-not (Get-Process -Name sahelflow -ErrorAction SilentlyContinue)) { break }
  Start-Sleep -Milliseconds 800
}
Write-Host "walk: ui-ready $ready after $([math]::Round(((Get-Date) - $t0).TotalSeconds, 1)) s"
Start-Sleep -Seconds 3
node scripts/walk3.mjs $Port
Start-Sleep -Seconds 3
# lag (F-0016): copy the lag recorder file from either data root (the host puts SF_DATA_DIR = %APPDATA%\com.sahelflow.desktop)
foreach ($lr in $dataRoots) { $lp = Join-Path $lr 'lagrec.jsonl'; if (Test-Path $lp) { $tag = if ($lr -eq $dataRoots[0]) { 'local' } else { 'roaming' }; Copy-Item $lp (Join-Path 'out' "lagrec-$tag.jsonl") -ErrorAction SilentlyContinue; Write-Host "walk: lagrec copied from $lr ($((Get-Item $lp).Length) bytes)" } else { Write-Host "walk: no lagrec.jsonl in $lr" } }
# qlog (F-0016): copy the query log
foreach ($lr in $dataRoots) { $lp = Join-Path $lr 'qlog.jsonl'; if (Test-Path $lp) { $tag = if ($lr -eq $dataRoots[0]) { 'local' } else { 'roaming' }; Copy-Item $lp (Join-Path 'out' "qlog-$tag.jsonl") -ErrorAction SilentlyContinue; Write-Host "walk: qlog copied from $lr ($((Get-Item $lp).Length) bytes)" } else { Write-Host "walk: no qlog.jsonl in $lr" } }
Get-ChildItem $dataRoots[0] -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(startup-trace|runtime-ui-diagnostic).*\.json$' } | ForEach-Object { Copy-Item $_.FullName (Join-Path 'out' $_.Name) }
Get-Process -Name sahelflow, sahelflow-whatsapp -ErrorAction SilentlyContinue | ForEach-Object { [void]$_.CloseMainWindow() }
Get-Process -Name node -ErrorAction SilentlyContinue | Where-Object { $_.Path -notlike '*SahelFlow*' } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 4
Get-Process -Name sahelflow, sahelflow-whatsapp -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item out/assets -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "walk: done"
