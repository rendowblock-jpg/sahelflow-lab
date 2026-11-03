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
# a7 slow-disk SIMULATION (off unless runs/wp.json has "hog": N > 0): scripts/hog-sched.ps1 starts N hog writers hogStartS seconds after the request probe starts, stops them at hogStopS
$hogSched = $null
try {
  $wpCfg = Get-Content runs/wp.json -Raw | ConvertFrom-Json
  $hogN = 0; $hogStartS = 240; $hogStopS = 420
  if ($wpCfg.hog) { $hogN = [int]$wpCfg.hog }
  if ($wpCfg.hogStartS) { $hogStartS = [int]$wpCfg.hogStartS }
  if ($wpCfg.hogStopS) { $hogStopS = [int]$wpCfg.hogStopS }
  if ($hogN -gt 0) {
    $hogSched = Start-Process pwsh -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'scripts/hog-sched.ps1', '-N', "$hogN", '-StartS', "$hogStartS", '-StopS', "$hogStopS") -WindowStyle Hidden -PassThru
    Write-Host "walk: hog scheduled N=$hogN from $hogStartS s to $hogStopS s of the request probe"
  }
} catch { Write-Host "walk: hog setup error (ignored) $_" }
node scripts/stall2.mjs $Port
New-Item -ItemType File -Force -Path out/sampler.stop | Out-Null
if ($hogSched) { try { [void]$hogSched.WaitForExit(40000) } catch {} ; try { if (-not $hogSched.HasExited) { $hogSched.Kill() } } catch {} }
Start-Sleep -Seconds 3
Get-ChildItem $dataRoots[0] -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(startup-trace|runtime-ui-diagnostic).*\.json$' } | ForEach-Object { Copy-Item $_.FullName (Join-Path 'out' $_.Name) }
Get-Process -Name sahelflow, sahelflow-whatsapp -ErrorAction SilentlyContinue | ForEach-Object { [void]$_.CloseMainWindow() }
Get-Process -Name node -ErrorAction SilentlyContinue | Where-Object { $_.Path -notlike '*SahelFlow*' } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 4
Get-Process -Name sahelflow, sahelflow-whatsapp -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Remove-Item out/assets -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "walk: done"
