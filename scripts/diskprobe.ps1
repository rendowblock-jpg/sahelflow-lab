# usage: diskprobe.ps1 -> every 250 ms: write 4 KB with write-through + flush (an fsync) on the system drive, log latency in ms to out/disk.jsonl until out/sampler.stop exists.
$ErrorActionPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path out | Out-Null
$path = Join-Path $env:LOCALAPPDATA 'sf-diskprobe.tmp'
$buf = New-Object byte[] 4096
$fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read, 4096, [System.IO.FileOptions]::WriteThrough)
$sw = New-Object System.Diagnostics.Stopwatch
$lines = New-Object System.Collections.Generic.List[string]
$last = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
while (-not (Test-Path out/sampler.stop)) {
  $t = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $sw.Restart()
  $fs.Position = 0; $fs.Write($buf, 0, $buf.Length); $fs.Flush($true)
  $sw.Stop()
  $lines.Add("{""t"":$t,""ms"":$([math]::Round($sw.Elapsed.TotalMilliseconds, 1))}")
  if (($t - $last) -gt 5000 -or $sw.Elapsed.TotalMilliseconds -gt 500) { Add-Content out/disk.jsonl $lines; $lines.Clear(); $last = $t }
  Start-Sleep -Milliseconds 250
}
if ($lines.Count -gt 0) { Add-Content out/disk.jsonl $lines }
$fs.Dispose(); Remove-Item $path -Force
