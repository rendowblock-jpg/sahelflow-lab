# x11 slow-disk SIMULATION. One disk hog: loops writing 64 KB blocks to its own file under the given dir, WriteThrough + Flush($true)
# after EVERY write (a real synced write). Rewrites from offset 0 after 64 MB. Runs until <Dir>/stop.txt exists or MaxSeconds.
# Writes <Dir>/hog<Id>.json (progress every ~3 s, final at the end). Never throws.
param([int]$Id = 1, [string]$Dir = '', [int]$MaxSeconds = 2400)
$ErrorActionPreference = 'Continue'
if (-not $Dir) { $Dir = Join-Path $env:TEMP 'sfhog' }
$stop = Join-Path $Dir 'stop.txt'
$file = Join-Path $Dir "hog$Id.bin"
$stat = Join-Path $Dir "hog$Id.json"
$limit = 64MB
$buf = New-Object byte[] 65536
(New-Object Random (100 + $Id)).NextBytes($buf)
$bytes = 0L; $writes = 0L; $sumMs = 0.0; $maxMs = 0.0; $err = $null
$sw = [Diagnostics.Stopwatch]::StartNew()
$lastStat = 0.0
function Save-Stat([bool]$final) {
  try {
    $o = [ordered]@{ id = $Id; pid = $PID; final = $final; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 2); bytes = $bytes; writes = $writes; avgWriteMs = $(if ($writes -gt 0) { [math]::Round($sumMs / $writes, 2) } else { 0 }); maxWriteMs = [math]::Round($maxMs, 1); error = $err }
    $o | ConvertTo-Json | Set-Content -LiteralPath $stat -Encoding utf8
  } catch {}
}
$fs = $null
try {
  $fs = New-Object IO.FileStream($file, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
  while ($sw.Elapsed.TotalSeconds -lt $MaxSeconds) {
    if (($writes % 4) -eq 0 -and (Test-Path -LiteralPath $stop)) { break }
    $t = [Diagnostics.Stopwatch]::StartNew()
    $fs.Write($buf, 0, $buf.Length)
    $fs.Flush($true)
    $ms = $t.Elapsed.TotalMilliseconds
    $sumMs += $ms; if ($ms -gt $maxMs) { $maxMs = $ms }
    $bytes += $buf.Length; $writes++
    if ($fs.Position -ge $limit) { $fs.Position = 0 }
    if (($sw.Elapsed.TotalSeconds - $lastStat) -ge 3) { $lastStat = $sw.Elapsed.TotalSeconds; Save-Stat $false }
  }
} catch { $err = "$_" }
finally {
  try { if ($fs) { $fs.Dispose() } } catch {}
  Save-Stat $true
  try { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue } catch {}
}
