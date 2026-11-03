# usage: first-launch-compare.ps1 -BaseDir msi-base -FixDir msi-fix -Rounds 2
# One runner, alternating clean installs: base, fix, base, fix ... then a crash drill on the fix build.
# Per variant: uninstall + wipe app data, install, launch-observe (2 launches: first and repeat), DB check. Public log: durations only.
param([string]$BaseDir = 'msi-base', [string]$FixDir = 'msi-fix', [int]$Rounds = 2, [int]$Warm = 1, [int]$SkipBase = 0, [int]$Crash = 1, [string]$Prewarm = 'off')
$ErrorActionPreference = 'Continue'
$dataRoots = @((Join-Path $env:LOCALAPPDATA 'com.sahelflow.desktop'), (Join-Path $env:APPDATA 'com.sahelflow.desktop'))
$exe = Join-Path $env:ProgramFiles 'SahelFlow\sahelflow.exe'
New-Item -ItemType Directory -Force -Path res | Out-Null

function Find-Msi([string]$dir) { (Get-ChildItem $dir -Recurse -Filter *.msi | Select-Object -First 1).FullName }

function Get-Trace {
  foreach ($r in $dataRoots) {
    $p = Join-Path $r 'startup-trace.json'
    if (Test-Path $p) { try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch {} }
  }
  return $null
}
function Get-Stages($tr) { if ($tr -and $tr.events) { return @($tr.events | ForEach-Object { $_.stage }) } else { return @() } }

function Remove-App {
  Get-Process -Name sahelflow, sahelflow-whatsapp -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  $keys = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*SahelFlow*' }
  foreach ($k in @($keys)) {
    if ($k.PSChildName -match '^\{[0-9A-Fa-f-]+\}$') {
      $p = Start-Process msiexec.exe -ArgumentList @('/x', $k.PSChildName, '/qn', '/norestart') -Wait -PassThru
      Write-Host "uninstall: exit $($p.ExitCode)"
    }
  }
  foreach ($r in $dataRoots) { if (Test-Path $r) { Remove-Item $r -Recurse -Force -ErrorAction SilentlyContinue } }
}

function Install-Fresh([string]$msi) {
  Remove-App
  if (Test-Path out) { Remove-Item out -Recurse -Force }
  New-Item -ItemType Directory -Force -Path out/assets | Out-Null
  Copy-Item $msi out/assets/
  & ./scripts/install-msi.ps1
}

function Run-Variant([string]$label, [string]$msi, [int]$launches) {
  Write-Host "variant: $label start"
  Install-Fresh $msi
  & ./scripts/disk-bench.ps1
  # F-0010 experiment (off unless runs/fl.json has "prewarm"): read the WebView2 runtime / app files before the first launch
  if ($Prewarm -ne 'off') { try { & ./scripts/prewarm.ps1 -Mode $Prewarm } catch { Write-Host "prewarm: error (ignored) $_" } }
  & ./scripts/launch-observe.ps1 -Launches $launches -SettleSeconds 8 -MaxSeconds 240
  Get-Process -Name sahelflow, sahelflow-whatsapp -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  python scripts/check-db.py $label | Out-File -Encoding utf8 out/dbcheck.json
  Remove-Item out/assets -Recurse -Force -ErrorAction SilentlyContinue
  Move-Item out "res/$label"
  Write-Host "variant: $label done"
}

function Crash-Drill([string]$msi) {
  Write-Host "variant: crash start"
  Install-Fresh $msi
  $recs = @()
  foreach ($d in @(0.05, 0.15, 0.3, 0.6, 1.0)) {
    $startMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $t0 = Get-Date
    $p = Start-Process -FilePath $exe -PassThru
    $seen = $false
    while (((Get-Date) - $t0).TotalSeconds -lt 30) {
      $tr = Get-Trace
      if ($tr -and $tr.events -and $tr.events.Count -gt 0 -and $tr.events[0].createdAtUnixMilliseconds -ge ($startMs - 2000) -and ((Get-Stages $tr) -contains 'migration-started')) { $seen = $true; break }
      Start-Sleep -Milliseconds 25
    }
    Start-Sleep -Milliseconds ([int]($d * 1000))
    Get-Process -Name sahelflow, sahelflow-whatsapp -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $files = @()
    foreach ($r in $dataRoots) {
      if (Test-Path $r) {
        $files += @(Get-ChildItem $r -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match 'shops|system|migration' -and $_.FullName -notmatch 'EBWebView' } | ForEach-Object { "$($_.Length)`t$($_.FullName.Substring($r.Length))" })
      }
    }
    $rec = [ordered]@{ delayAfterMigrationStartS = $d; sawMigrationStarted = $seen; stagesAtKill = ((Get-Stages (Get-Trace)) -join ','); files = $files }
    $recs += , $rec
    Write-Host "crash cycle: delay $d s, migration-started seen: $seen"
    Start-Sleep -Seconds 4
  }
  $recs | ConvertTo-Json -Depth 5 | Set-Content out/crash-cycles.json
  & ./scripts/launch-observe.ps1 -Launches 2 -SettleSeconds 8 -MaxSeconds 240
  Get-Process -Name sahelflow, sahelflow-whatsapp -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  python scripts/check-db.py crash | Out-File -Encoding utf8 out/dbcheck.json
  Remove-Item out/assets -Recurse -Force -ErrorAction SilentlyContinue
  Move-Item out "res/crash"
  Write-Host "variant: crash done"
}

$base = Find-Msi $BaseDir
$fix = Find-Msi $FixDir
if (-not $base -or -not $fix) { Write-Host "compare: fail (msi missing)"; exit 1 }
if (Test-Path out) { Remove-Item out -Recurse -Force }
& ./scripts/disk-bench.ps1
Move-Item out res/diskbench
# The dry run showed the same MSI taking 220 s, 37 s and 35 s on one runner (the first launch after a cold start is slow).
# So: one discarded warm-up, then rounds that swap the order (fix first, base first, fix first ...).
if ($Warm -eq 1) { Run-Variant "warm" $base 1 }
for ($i = 1; $i -le $Rounds; $i++) {
  if (($i % 2) -eq 1) {
    Run-Variant "fix$i" $fix 2
    if ($SkipBase -eq 0) { Run-Variant "base$i" $base 2 }
  } else {
    if ($SkipBase -eq 0) { Run-Variant "base$i" $base 2 }
    Run-Variant "fix$i" $fix 2
  }
}
if ($Crash -eq 1) { Crash-Drill $fix }
Remove-App
New-Item -ItemType Directory -Force -Path out | Out-Null
Get-ChildItem res | ForEach-Object { Move-Item $_.FullName (Join-Path 'out' $_.Name) }
foreach ($d in Get-ChildItem out -Directory) {
  $t = Join-Path $d.FullName 'timeline.json'
  if (Test-Path $t) {
    $j = Get-Content $t -Raw | ConvertFrom-Json
    $s = (@($j) | ForEach-Object { "L$($_.launch) " + $(if ($_.ready) { "ready at $($_.readyAtS) s" } else { 'NOT ready' }) }) -join ', '
    Write-Host "compare: $($d.Name): $s"
  }
}
Write-Host "compare: ok"
