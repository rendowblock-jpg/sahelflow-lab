# Launches the installed app (twice), samples processes/IO/network, waits for the app's own "ui-ready" trace stage,
# takes OS screenshots, closes it like a user, checks leftovers. Public log: ok/fail + durations only.
param([int]$Port = 9222, [int]$MaxSeconds = 300, [int]$SettleSeconds = 30, [int]$Launches = 2, [int]$Cpu = 0)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path out/shots, out/launch | Out-Null
$exe = Join-Path $env:ProgramFiles 'SahelFlow\sahelflow.exe'
if (-not (Test-Path $exe)) { Write-Host "launch: fail (no exe)"; exit 1 }
$names = @('sahelflow', 'node', 'sahelflow-whatsapp', 'msedgewebview2')
$dataRoots = @((Join-Path $env:LOCALAPPDATA 'com.sahelflow.desktop'), (Join-Path $env:APPDATA 'com.sahelflow.desktop'))
$script:tick = 0
$script:shot = @{}

# x14 low-end CPU SIMULATION (off unless -Cpu <affinity bitmask> > 0, e.g. 3 = logical CPUs 0+1). The app is started while this script's own
# affinity is the mask (a child inherits it, so the host and everything it spawns are limited from the first instruction); this script and
# scripts/cpu-affinity.ps1 run on the OTHER logical CPUs so the harness does not take CPU from the app. Out: out/cpu.json.
$script:cpuMask = 0
$script:harnessMask = 0
$script:selfOrig = $null
$script:cpuErr = @()
$script:cpuLaunches = @()
function Set-SelfAffinity($m) { try { (Get-Process -Id $PID).ProcessorAffinity = [IntPtr]([int64]$m) } catch { $script:cpuErr += "set-self $m : $_" } }
if ($Cpu -gt 0) {
  try {
    $allMask = (1 -shl [Environment]::ProcessorCount) - 1
    $script:selfOrig = [int64](Get-Process -Id $PID).ProcessorAffinity
    $script:cpuMask = [int]($Cpu -band $allMask)
    if ($script:cpuMask -le 0) { $script:cpuErr += "mask $Cpu has no CPU among $allMask"; $script:cpuMask = 0 }
    else {
      $script:harnessMask = [int]($allMask -band (-bnot $script:cpuMask))
      if ($script:harnessMask -ne 0) { Set-SelfAffinity $script:harnessMask }
    }
    Write-Host "cpu: mask=$($script:cpuMask) harnessMask=$($script:harnessMask) logicalCpus=$([Environment]::ProcessorCount)"
  } catch { $script:cpuErr += "setup: $_" }
}

function Save-Screen($path) {
  try {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose(); return $true
  } catch { return "$_" }
}
function Get-Trace {
  foreach ($r in $dataRoots) {
    $p = Join-Path $r 'startup-trace.json'
    if (Test-Path $p) { try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch {} }
  }
  return $null
}
function Sample($t0, $label) {
  $el = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
  $ps = @(Get-Process -Name $names -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -ne 'node' -or ($_.Path -like '*SahelFlow*') })
  $procs = @($ps | ForEach-Object {
    $o = [ordered]@{ n = $_.ProcessName; id = $_.Id; wsMB = [math]::Round($_.WorkingSet64 / 1MB, 1); privMB = [math]::Round($_.PrivateMemorySize64 / 1MB, 1); handles = $_.HandleCount; threads = $_.Threads.Count; cpuS = [math]::Round([double]$_.CPU, 2) }
    if ($script:cpuMask -gt 0) { try { $o.aff = [int64]$_.ProcessorAffinity } catch { $o.aff = -1 } }
    $o })
  $io = [ordered]@{}
  try {
    Get-CimInstance Win32_Process -Filter "Name='sahelflow.exe' OR Name='node.exe' OR Name='sahelflow-whatsapp.exe'" -ErrorAction Stop | ForEach-Object {
      $io["$($_.Name):$($_.ProcessId)"] = @([int64]$_.ReadOperationCount, [int64]$_.WriteOperationCount, [int64]$_.ReadTransferCount, [int64]$_.WriteTransferCount) }
  } catch {}
  $net = @()
  if (($script:tick % 4) -eq 0) {
    try {
      $ids = @($ps | Where-Object { $_.ProcessName -in 'sahelflow', 'node', 'sahelflow-whatsapp' } | ForEach-Object { $_.Id })
      $net = @(Get-NetTCPConnection -ErrorAction Stop | Where-Object { $ids -contains $_.OwningProcess } | ForEach-Object { "$($_.OwningProcess) $($_.State) $($_.LocalPort)->$($_.RemoteAddress):$($_.RemotePort)" })
    } catch {}
  }
  $script:tick++
  Add-Content out/procs.jsonl ((@{ l = $label; t = $el; procs = $procs; io = $io; net = $net } | ConvertTo-Json -Depth 5 -Compress))
  return $el
}
function Wait-Ready($t0, $startMs, $label, $max) {
  while (((Get-Date) - $t0).TotalSeconds -lt $max) {
    $el = Sample $t0 $label
    if ($label -eq 'L1') {
      foreach ($at in 5, 35) { if ($el -ge $at -and -not $script:shot.ContainsKey($at)) { $script:shot[$at] = Save-Screen "out/shots/l1-at$at.png" } }
    }
    $tr = Get-Trace
    if ($tr -and $tr.events -and $tr.events.Count -gt 0 -and $tr.events[0].createdAtUnixMilliseconds -ge ($startMs - 5000)) {
      if ($tr.events | Where-Object { $_.stage -eq 'ui-ready' }) { return $true }
    }
    if (-not (Get-Process -Name sahelflow -ErrorAction SilentlyContinue)) { return $false }
    Start-Sleep -Milliseconds 800
  }
  return $false
}

$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=$Port --remote-allow-origins=*"
$allStart = Get-Date
$records = @()
$okCount = 0
for ($n = 1; $n -le $Launches; $n++) {
  $label = "L$n"
  $startMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $t0 = Get-Date
  $enf = $null
  if ($script:cpuMask -gt 0) {
    try {
      $enfArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$((Resolve-Path ./scripts/cpu-affinity.ps1).Path)`"", '-Mask', "$($script:cpuMask)", '-Launch', "$n", '-StartMs', "$startMs", '-Seconds', '150', '-Dir', "`"$((Resolve-Path out).Path)`"")
      $enf = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $enfArgs -WindowStyle Hidden -PassThru
    } catch { $script:cpuErr += "enforcer start L$n : $_" }
    Set-SelfAffinity $script:cpuMask
  }
  $p = Start-Process -FilePath $exe -PassThru
  $rec = [ordered]@{ launch = $n; startedUtc = $t0.ToUniversalTime().ToString('o'); pid = $p.Id }
  if ($script:cpuMask -gt 0) {
    if ($script:harnessMask -ne 0) { Set-SelfAffinity $script:harnessMask } else { Set-SelfAffinity $script:selfOrig }
    try {
      $rec.appAffinityRightAfterStart = [int64](Get-Process -Id $p.Id).ProcessorAffinity
      $p.ProcessorAffinity = [IntPtr]([int64]$script:cpuMask)
      $rec.appAffinityAfterSet = [int64](Get-Process -Id $p.Id).ProcessorAffinity
    } catch { $script:cpuErr += "main set L$n : $_" }
  }
  $ready = Wait-Ready $t0 $startMs $label $MaxSeconds
  $rec.ready = $ready
  $rec.readyAtS = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
  $w = Get-Process -Name sahelflow -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  $rec.windowTitle = if ($w) { $w.MainWindowTitle } else { $null }
  $rec.screenReady = Save-Screen "out/shots/l$n-ready.png"
  try { $v = Invoke-RestMethod "http://127.0.0.1:$Port/json/version" -TimeoutSec 2; $rec.cdpUp = $true; $rec.cdpBrowser = $v.Browser } catch { $rec.cdpUp = $false }
  $s0 = Get-Date
  while (((Get-Date) - $s0).TotalSeconds -lt $SettleSeconds) { [void](Sample $t0 $label); Start-Sleep -Seconds 2 }
  $rec.screenSettled = Save-Screen "out/shots/l$n-settled.png"
  foreach ($r in $dataRoots) {
    if (Test-Path $r) {
      Get-ChildItem $r -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(startup-trace|runtime-ui-diagnostic).*\.json$' } | ForEach-Object { Copy-Item $_.FullName (Join-Path 'out/launch' "l$n-$($_.Name)") -ErrorAction SilentlyContinue }
    }
  }
  # close like a user would
  $c0 = Get-Date
  $rec.closeRequested = (@(Get-Process -Name sahelflow -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() }) -contains $true)
  $exited = $false
  while (((Get-Date) - $c0).TotalSeconds -lt 40) { if (-not (Get-Process -Name sahelflow -ErrorAction SilentlyContinue)) { $exited = $true; break }; Start-Sleep -Milliseconds 500 }
  $rec.closeSeconds = [math]::Round(((Get-Date) - $c0).TotalSeconds, 1)
  $rec.exitedAfterClose = $exited
  Start-Sleep -Seconds 5
  $left = @(Get-Process -Name sahelflow, sahelflow-whatsapp, msedgewebview2 -ErrorAction SilentlyContinue) + @(Get-Process -Name node -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*SahelFlow*' })
  $rec.leftoverAfterClose = @($left | ForEach-Object { $_.ProcessName })
  Get-Process -Name sahelflow, sahelflow-whatsapp -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  if ($script:cpuMask -gt 0) {
    try {
      Set-Content -LiteralPath "out/cpu-stop-L$n" -Value 'stop'
      if ($enf) { [void]$enf.WaitForExit(8000); if (-not $enf.HasExited) { $enf.Kill() } }
      if (Test-Path "out/cpu-L$n.json") {
        $cj = Get-Content "out/cpu-L$n.json" -Raw | ConvertFrom-Json
        $script:cpuLaunches += , $cj
        Write-Host "cpu: L$n seen=$($cj.processesSeen) inherited=$($cj.alreadyMaskedByInheritance) setByLoop=$($cj.setByLoop) errors=$($cj.errors)"
      } else { $script:cpuErr += "no out/cpu-L$n.json" }
    } catch { $script:cpuErr += "enforcer collect L$n : $_" }
  }
  if ($ready) { $okCount++ }
  $records += , $rec
  Start-Sleep -Seconds 3
}
$records | ConvertTo-Json -Depth 5 | Set-Content out/timeline.json
if ($Cpu -gt 0) { if ($script:selfOrig) { Set-SelfAffinity $script:selfOrig } }
$cpuOut = [ordered]@{ requestedMask = $Cpu; mask = $script:cpuMask; harnessMask = $script:harnessMask; logicalCpus = [Environment]::ProcessorCount; applied = ($script:cpuMask -gt 0); errors = $script:cpuErr; launches = $script:cpuLaunches }
$cpuOut | ConvertTo-Json -Depth 8 | Set-Content out/cpu.json -Encoding utf8

# app data: names and sizes of everything (no content except an allow-list of diagnostics)
$tree = New-Object System.Collections.Generic.List[string]
foreach ($root in $dataRoots) {
  if (Test-Path $root) {
    Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch 'node-compile-cache|EBWebView' } | ForEach-Object {
      $rel = $_.FullName.Substring($root.Length); $tree.Add("$($_.Length)`t$rel")
      if ($rel -match 'migration-journal' -and $_.Name -like '*.json' -and $_.Length -lt 200KB) {
        New-Item -ItemType Directory -Force -Path out/appdata | Out-Null
        Copy-Item $_.FullName (Join-Path 'out/appdata' ($rel.TrimStart('\') -replace '[\\/:]', '_')) -ErrorAction SilentlyContinue
      }
    }
  }
}
$tree | Set-Content out/appdata-tree.txt
$ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $allStart } -ErrorAction SilentlyContinue | Where-Object { $_.LevelDisplayName -in 'Error', 'Warning' } | Select-Object -First 80 TimeCreated, ProviderName, Id, LevelDisplayName, @{ n = 'Msg'; e = { $m = ($_.Message -replace '\s+', ' '); $m.Substring(0, [math]::Min(300, $m.Length)) } })
if ($ev.Count -eq 0) { '[]' | Set-Content out/eventlog.json } else { $ev | ConvertTo-Json | Set-Content out/eventlog.json }

$summary = ($records | ForEach-Object { "L$($_.launch) " + $(if ($_.ready) { "ready at $($_.readyAtS) s" } else { 'NOT ready' }) }) -join ', '
if ($okCount -ge 1) { Write-Host "launch: ok ($summary)" } else { Write-Host "launch: fail ($summary)"; exit 1 }
