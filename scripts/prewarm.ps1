# F-0010 experiment. Reads every file under the WebView2 runtime folder and/or the installed app folder completely
# (1 MB buffer, data discarded) BEFORE the first launch, and records how long that took. Never fails the run.
# usage: prewarm.ps1 -Mode none|webview2|app|both     -> out/prewarm.json   (mode none = context only, no file reads)
param([string]$Mode = 'none')
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path out | Out-Null
$o = [ordered]@{ mode = $Mode; startedUtc = (Get-Date).ToUniversalTime().ToString('o') }

function Find-WebView2 {
  $res = [ordered]@{ pv = $null; dir = $null; how = $null }
  $guid = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
  foreach ($k in @("HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$guid", "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$guid")) {
    try { $v = (Get-ItemProperty $k -ErrorAction Stop).pv; if ($v) { $res.pv = "$v"; break } } catch {}
  }
  $base = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\EdgeWebView\Application'
  if ($res.pv) {
    $d = Join-Path $base $res.pv
    if (Test-Path -LiteralPath $d) { $res.dir = $d; $res.how = 'registry'; return $res }
  }
  # fallback: newest version folder, then any folder that holds msedgewebview2.exe
  try {
    $vd = @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction Stop | Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } | Sort-Object { [version]$_.Name } -Descending)
    if ($vd.Count -gt 0) { $res.dir = $vd[0].FullName; $res.how = 'newest-version-folder'; if (-not $res.pv) { $res.pv = $vd[0].Name }; return $res }
  } catch {}
  foreach ($pf in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
    try {
      $e = Get-ChildItem -LiteralPath (Join-Path $pf 'Microsoft') -Recurse -Filter msedgewebview2.exe -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($e) { $res.dir = $e.DirectoryName; $res.how = 'search'; return $res }
    } catch {}
  }
  return $res
}

# One full read pass over a folder. Returns an ordered record.
function Read-Tree([string]$name, [string]$root, [bool]$detail) {
  $r = [ordered]@{ name = $name; folder = $root; found = $false }
  if (-not $root -or -not (Test-Path -LiteralPath $root)) { return $r }
  $r.found = $true
  $total = [Diagnostics.Stopwatch]::StartNew()
  $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)
  $r.enumerateSeconds = [math]::Round($total.Elapsed.TotalSeconds, 2)
  $buf = New-Object byte[] 1048576
  $bytes = [int64]0
  $errs = 0
  $per = New-Object System.Collections.Generic.List[object]
  $share = [IO.FileShare]'ReadWrite,Delete'
  foreach ($f in $files) {
    $fsw = [Diagnostics.Stopwatch]::StartNew()
    $n = [int64]0
    try {
      $fs = New-Object IO.FileStream($f.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share, 1048576, [IO.FileOptions]::SequentialScan)
      try { while (($k = $fs.Read($buf, 0, $buf.Length)) -gt 0) { $n += $k } } finally { $fs.Dispose() }
    } catch { $errs++ }
    $bytes += $n
    if ($detail) { $per.Add([pscustomobject]@{ p = $f.FullName.Substring($root.Length).TrimStart('\'); b = $n; s = $fsw.Elapsed.TotalSeconds }) }
  }
  $sec = $total.Elapsed.TotalSeconds
  $r.files = $files.Count
  $r.bytes = $bytes
  $r.mb = [math]::Round($bytes / 1MB, 1)
  $r.readErrors = $errs
  $r.elapsedSeconds = [math]::Round($sec, 2)
  $r.readSecondsExclEnumerate = [math]::Round($sec - $r.enumerateSeconds, 2)
  $r.mbPerS = if ($sec -gt 0) { [math]::Round(($bytes / 1MB) / $sec, 1) } else { $null }
  if ($detail) {
    $r.slowest10 = @($per | Sort-Object s -Descending | Select-Object -First 10 | ForEach-Object { [ordered]@{ file = $_.p; bytes = $_.b; seconds = [math]::Round($_.s, 3) } })
    $r.sumOfTop10Seconds = [math]::Round([double](@($per | Sort-Object s -Descending | Select-Object -First 10 | Measure-Object s -Sum).Sum), 2)
  }
  return $r
}

try {
  # context (also written for mode none, so controls can be compared)
  try { $os = Get-CimInstance Win32_OperatingSystem; $o.uptimeMinutesAtStart = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalMinutes, 1) } catch { $o.uptimeError = "$_" }
  $o.webview2ProcessesAtStart = @(Get-Process -Name msedgewebview2 -ErrorAction SilentlyContinue).Count
  $wv = Find-WebView2
  $o.webview2Version = $wv.pv
  $o.webview2Folder = $wv.dir
  $o.webview2FoundBy = $wv.how
  $o.passes = @()
  if ($Mode -eq 'webview2' -or $Mode -eq 'both') {
    $a = Read-Tree 'webview2-first-pass' $wv.dir $true
    $b = Read-Tree 'webview2-second-pass' $wv.dir $false
    $o.passes += , $a
    $o.passes += , $b
  }
  if ($Mode -eq 'app' -or $Mode -eq 'both') {
    $appDir = Join-Path $env:ProgramFiles 'SahelFlow'
    $a = Read-Tree 'app-first-pass' $appDir $true
    $b = Read-Tree 'app-second-pass' $appDir $false
    $o.passes += , $a
    $o.passes += , $b
  }
  $first = @($o.passes | Where-Object { $_.name -like '*first-pass' -and $_.found })
  $o.totalFirstPassSeconds = [math]::Round([double](($first | ForEach-Object { $_.elapsedSeconds } | Measure-Object -Sum).Sum), 2)
  $o.totalFirstPassMB = [math]::Round([double](($first | ForEach-Object { $_.mb } | Measure-Object -Sum).Sum), 1)
  $o.endedUtc = (Get-Date).ToUniversalTime().ToString('o')
  $o | ConvertTo-Json -Depth 6 | Set-Content out/prewarm.json
  $line = (@($o.passes | ForEach-Object { "$($_.name) files=$($_.files) mb=$($_.mb) s=$($_.elapsedSeconds) mbps=$($_.mbPerS)" }) -join '; ')
  Write-Host "prewarm: ok mode=$Mode uptimeMin=$($o.uptimeMinutesAtStart) $line"
} catch {
  try { $o.error = "$_"; $o | ConvertTo-Json -Depth 6 | Set-Content out/prewarm.json } catch {}
  Write-Host "prewarm: error (ignored) $_"
}
exit 0
