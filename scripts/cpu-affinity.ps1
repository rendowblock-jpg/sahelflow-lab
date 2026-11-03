# x14 low-end CPU SIMULATION helper. Watches for the app's processes (sahelflow, sahelflow-whatsapp, node from SahelFlow, msedgewebview2, msedge)
# that started after the launch and sets their CPU affinity to the mask (safety net: children normally inherit it). Every 200 ms for the first 30 s,
# then every 1 s, until <Dir>/cpu-stop-L<Launch> exists or -Seconds. Writes <Dir>/cpu-L<Launch>.json (at +10 s, +30 s and at the end). Never throws.
param([int]$Mask = 0, [int]$Launch = 1, [int64]$StartMs = 0, [int]$Seconds = 120, [string]$Dir = 'out')
$ErrorActionPreference = 'Continue'
if ($Mask -le 0) { exit 0 }
$names = @('sahelflow', 'sahelflow-whatsapp', 'node', 'msedgewebview2', 'msedge')
$since = [DateTimeOffset]::FromUnixTimeMilliseconds($StartMs).LocalDateTime.AddSeconds(-2)
$stop = Join-Path $Dir "cpu-stop-L$Launch"
$outFile = Join-Path $Dir "cpu-L$Launch.json"
$seen = @{}
$s10 = $null; $s30 = $null
$sw = [Diagnostics.Stopwatch]::StartNew()
function Snap {
  $r = @()
  foreach ($p in @(Get-Process -Name $names -ErrorAction SilentlyContinue)) {
    try {
      if ($p.ProcessName -eq 'node') { $path = $null; try { $path = $p.Path } catch {}; if ($path -and $path -notlike '*SahelFlow*') { continue } }
      $r += , ([ordered]@{ Id = $p.Id; ProcessName = $p.ProcessName; ProcessorAffinity = [int64]$p.ProcessorAffinity })
    } catch {}
  }
  return , $r
}
function Write-Out([string]$why) {
  try {
    $recs = @($seen.Values)
    $final = @()
    foreach ($x in $recs) { try { $q = Get-Process -Id $x.id -ErrorAction Stop; $final += , ([int64]$q.ProcessorAffinity) } catch { $final += , $null } }
    $byName = [ordered]@{}
    foreach ($x in $recs) { if (-not $byName.Contains($x.name)) { $byName[$x.name] = 0 }; $byName[$x.name]++ }
    $o = [ordered]@{ launch = $Launch; mask = $Mask; why = $why; watchedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
      processesSeen = $recs.Count; alreadyMaskedByInheritance = @($recs | Where-Object { -not $_.changed -and -not $_.error }).Count
      setByLoop = @($recs | Where-Object { $_.changed -and -not $_.error }).Count; errors = @($recs | Where-Object { $_.error }).Count
      stillAliveWithMask = @($final | Where-Object { $_ -eq $Mask }).Count; stillAliveWithOtherMask = @($final | Where-Object { $null -ne $_ -and $_ -ne $Mask }).Count
      seenByName = $byName; sampleAt10s = $s10; sampleAt30s = $s30; processes = $recs }
    $o | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $outFile -Encoding utf8
  } catch {}
}
while ($sw.Elapsed.TotalSeconds -lt $Seconds -and -not (Test-Path $stop)) {
  foreach ($p in @(Get-Process -Name $names -ErrorAction SilentlyContinue)) {
    try {
      if ($seen.ContainsKey($p.Id)) { continue }
      if ($p.StartTime -lt $since) { continue }
      if ($p.ProcessName -eq 'node') { $path = $null; try { $path = $p.Path } catch {}; if ($path -and $path -notlike '*SahelFlow*') { continue } }
      $rec = [ordered]@{ id = $p.Id; name = $p.ProcessName; firstSeenS = [math]::Round(([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $StartMs) / 1000, 2); before = [int64]$p.ProcessorAffinity; changed = $false; after = $null; error = $null }
      try {
        if ($rec.before -ne $Mask) { $p.ProcessorAffinity = [IntPtr]([int64]$Mask); $rec.changed = $true }
        $rec.after = [int64](Get-Process -Id $p.Id -ErrorAction Stop).ProcessorAffinity
      } catch { $rec.error = "$_" }
      $seen[$p.Id] = $rec
    } catch {}
  }
  if ($null -eq $s10 -and $sw.Elapsed.TotalSeconds -ge 10) { $s10 = [ordered]@{ atLaunchS = [math]::Round(([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $StartMs) / 1000, 1); procs = @(Snap) }; Write-Out 'at10s' }
  if ($null -eq $s30 -and $sw.Elapsed.TotalSeconds -ge 30) { $s30 = [ordered]@{ atLaunchS = [math]::Round(([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $StartMs) / 1000, 1); procs = @(Snap) }; Write-Out 'at30s' }
  if ($sw.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 200 } else { Start-Sleep -Milliseconds 1000 }
}
Write-Out $(if (Test-Path $stop) { 'stopped' } else { 'timeout' })
