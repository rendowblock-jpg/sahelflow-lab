# a7 slow-disk SIMULATION scheduler. Started by walk-probe.ps1 only when runs/wp.json has "hog": N > 0.
# Waits for out/stall.t0 (epoch ms, written by stall2.mjs when the request probe starts), then at t0+StartS seconds starts N hog writers
# (scripts/hog.ps1, same code as the x11 first-launch hog), at t0+StopS seconds stops them. Writes out/hog.json (N, start/stop epoch ms, MB written).
# Never throws; exits early when out/sampler.stop appears.
param([int]$N = 16, [int]$StartS = 240, [int]$StopS = 420, [int]$MaxWaitS = 1500)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path out | Out-Null
function Now-Ms { return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function Wait-Until([long]$epochMs) {
  while ($true) {
    if (Test-Path out/sampler.stop) { return $false }
    $left = $epochMs - (Now-Ms)
    if ($left -le 0) { return $true }
    Start-Sleep -Milliseconds ([int][math]::Min($left, 500))
  }
}
$info = [ordered]@{ hogRequested = $N; hogStartS = $StartS; hogStopS = $StopS; state = 'waiting-for-t0'; t0Ms = 0; startEpochMs = 0; allStartedEpochMs = 0; stopEpochMs = 0 }
function Save-Info { try { $info | ConvertTo-Json -Depth 5 | Set-Content out/hog.json } catch {} }
Save-Info
$t0 = 0L
$waited = 0
while ($waited -lt ($MaxWaitS * 2)) {
  if (Test-Path out/stall.t0) { try { $t0 = [int64]((Get-Content out/stall.t0 -Raw).Trim()) } catch { $t0 = 0L }; if ($t0 -gt 0) { break } }
  if (Test-Path out/sampler.stop) { break }
  Start-Sleep -Milliseconds 500; $waited++
}
if ($t0 -le 0) { $info.state = 'no-t0'; Save-Info; Write-Host "hog-sched: no t0, nothing started"; exit 0 }
$info.t0Ms = $t0
Write-Host "hog-sched: t0 $t0, start at +$StartS s, stop at +$StopS s, N=$N"
$info.state = 'waiting-for-start'; Save-Info
if (-not (Wait-Until ($t0 + $StartS * 1000))) { $info.state = 'probe-ended-before-start'; Save-Info; exit 0 }

$hogDir = Join-Path $env:TEMP 'sfhog'
$procs = @()
try {
  if (Test-Path $hogDir) { Remove-Item $hogDir -Recurse -Force -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Force -Path $hogDir | Out-Null
  $hostExe = (Get-Process -Id $PID).Path
  $worker = (Resolve-Path ./scripts/hog.ps1).Path
  $maxSec = [int]($StopS - $StartS + 90)
  $info.startEpochMs = Now-Ms
  for ($i = 1; $i -le $N; $i++) {
    try {
      $p = Start-Process -FilePath $hostExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$worker`"", '-Id', "$i", '-Dir', "`"$hogDir`"", '-MaxSeconds', "$maxSec") -WindowStyle Hidden -PassThru
      $procs += $p
    } catch { Write-Host "hog-sched: start $i error (ignored) $_" }
  }
  $info.allStartedEpochMs = Now-Ms
  $info.state = 'running'; $info.started = @($procs).Count; Save-Info
  Write-Host "hog-sched: started $(@($procs).Count) of $N (launch took $($info.allStartedEpochMs - $info.startEpochMs) ms)"
} catch { Write-Host "hog-sched: start error (ignored) $_" }

[void](Wait-Until ($t0 + $StopS * 1000))

try {
  $alive = 0
  foreach ($p in $procs) { try { if (-not $p.HasExited) { $alive++ } } catch {} }
  Set-Content -LiteralPath (Join-Path $hogDir 'stop.txt') -Value 'stop'
  $info.stopEpochMs = Now-Ms
  $w0 = Get-Date
  while ((((Get-Date) - $w0).TotalSeconds -lt 20)) {
    $left = 0
    foreach ($p in $procs) { try { if (-not $p.HasExited) { $left++ } } catch {} }
    if ($left -eq 0) { break }
    Start-Sleep -Milliseconds 500
  }
  $killed = 0
  foreach ($p in $procs) { try { if (-not $p.HasExited) { $p.Kill(); $killed++ } } catch {} }
  $per = @(); $bytes = 0L; $writes = 0L
  foreach ($f in @(Get-ChildItem -LiteralPath $hogDir -Filter 'hog*.json' -ErrorAction SilentlyContinue)) {
    try { $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json; $per += , $j; $bytes += [int64]$j.bytes; $writes += [int64]$j.writes } catch {}
  }
  $secs = [math]::Round(($info.stopEpochMs - $info.startEpochMs) / 1000.0, 1)
  $info.state = 'stopped'; $info.aliveBeforeStop = $alive; $info.killedAtStop = $killed; $info.hogRunningSeconds = $secs
  $info.totalBytes = $bytes; $info.totalMB = [math]::Round($bytes / 1MB, 1); $info.totalWrites = $writes
  $info.avgMBps = $(if ($secs -gt 0) { [math]::Round($bytes / 1MB / $secs, 2) } else { 0 })
  $info.perHog = $per
  Save-Info
  Write-Host "hog-sched: stopped (alive at stop $alive, killed $killed, $($info.totalMB) MB written in $secs s)"
} catch { Write-Host "hog-sched: stop error (ignored) $_" }
