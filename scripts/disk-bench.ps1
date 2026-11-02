# Small disk benchmark: fsync'd writes and cold-ish file opens. Public log: ok only. Detail -> out/diskbench.json
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path out | Out-Null
$o = [ordered]@{}
$dir = Join-Path $env:TEMP 'sfbench'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
$buf = New-Object byte[] 4096; (New-Object Random 7).NextBytes($buf)
$ms = New-Object System.Collections.Generic.List[double]
for ($i = 0; $i -lt 300; $i++) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $fs = [IO.File]::Open((Join-Path $dir "w$i.bin"), 'Create', 'Write', 'None'); $fs.Write($buf, 0, $buf.Length); $fs.Flush($true); $fs.Dispose()
  $ms.Add($sw.Elapsed.TotalMilliseconds)
}
$s = $ms | Sort-Object
$o.fsyncWrite = [ordered]@{ n = 300; p50ms = [math]::Round($s[150], 2); p95ms = [math]::Round($s[285], 2); maxms = [math]::Round($s[299], 2); totalS = [math]::Round(($ms | Measure-Object -Sum).Sum / 1000, 2) }
$root = Join-Path $env:ProgramFiles 'SahelFlow'
if (Test-Path $root) {
  $files = Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 4000
  $rb = New-Object byte[] 1
  $oms = New-Object System.Collections.Generic.List[double]
  $t0 = Get-Date
  foreach ($f in $files) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite'); [void]$fs.Read($rb, 0, 1); $fs.Dispose() } catch {}
    $oms.Add($sw.Elapsed.TotalMilliseconds)
  }
  $s2 = $oms | Sort-Object
  $o.fileOpen = [ordered]@{ n = $oms.Count; p50ms = [math]::Round($s2[[int]($oms.Count * 0.5)], 3); p95ms = [math]::Round($s2[[int]($oms.Count * 0.95)], 3); maxms = [math]::Round($s2[$oms.Count - 1], 2); totalS = [math]::Round(((Get-Date) - $t0).TotalSeconds, 2) }
}
Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
$o | ConvertTo-Json -Depth 4 | Set-Content out/diskbench.json
Write-Host "diskbench: ok"
