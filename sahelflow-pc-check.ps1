<#
=====================================================================================
 SahelFlow PC check  -  script version 1
=====================================================================================
 WHAT THIS IS
   It records how fast SahelFlow starts on THIS PC and how fast this PC's disk is,
   and writes the numbers into ONE small text file that you can send back.
   It is read-only for everything except its own report file.

 WHAT IT READS (and nothing else)
   1. Facts that Windows gives about this PC: Windows version, processor, memory,
      the type of the system disk (SSD or hard disk), free disk space, how long the
      PC has been on, the Microsoft WebView2 version, whether Windows Defender
      real-time protection is on, the names of antivirus products, and the version
      of SahelFlow (from the list of installed programs and from the properties of
      C:\Program Files\SahelFlow\sahelflow.exe).
   2. Two small files that SahelFlow itself writes about its own start:
         startup-trace.json   and   runtime-ui-diagnostic.json
      in the folder  %APPDATA%\com.sahelflow.desktop  (or, if not there,
      %LOCALAPPDATA%\com.sahelflow.desktop). The script opens only these two files
      by name. It does not list or open anything else in that folder. It never
      touches the shop database, customers, keys, passwords or the licence.
   3. ONLY if you add -ReadWebView2: every file of Microsoft's WebView2 program
      folder (under Program Files) is read once and the data is thrown away, to
      time a cold read of the disk. This takes 10 to 60 seconds.

 WHAT IT WRITES
   1. One report:  sahelflow-pc-check-<computer name>-<date>-<time>.txt
      in the folder where this script is (or on the Desktop if that folder is not
      writable). The report has the computer name but not your user name; the
      profile folder is shown as %USERPROFILE%.
   2. During the disk test: temporary test files (at most about 70 MB) in a new
      folder inside your temporary folder (%TEMP%). They are deleted at the end of
      the test. This is the only thing written outside the report.
      (Only if you start it with PowerShell 7 instead of Windows PowerShell: Windows' own
      Defender commands may also leave a small folder remoteIpMoProxy_... in %TEMP%.)

 WHAT IT STARTS
   Only with -Launch: it starts SahelFlow (like a double click) and watches the
   start-up file. It never closes, stops or kills any program. You close SahelFlow
   yourself when the script asks you to.

 WHAT IT NEVER DOES
   No internet, no network call, no upload. It changes no setting and no registry
   value. It needs no administrator rights. It deletes nothing except its own
   temporary test files.

 HOW TO RUN (see README.md): double-click  run-launch-twice.cmd  or type
   powershell -ExecutionPolicy Bypass -File sahelflow-pc-check.ps1 -Launch -Twice

 OPTIONS
   (none)          read the start-up file of the last launch + machine facts + disk test
   -Launch         ask you to close SahelFlow, start it, time the start
   -Launch -Twice  do it twice (the second start is the warm one). -Twice alone = same
   -ReadWebView2   also time a read of the WebView2 program folder (10-60 s, heavy)
   -NoPause        do not wait for Enter at the very end
=====================================================================================
#>
[CmdletBinding()]
param(
  [switch]$Launch,
  [switch]$Twice,
  [switch]$ReadWebView2,
  [switch]$NoPause,
  [Parameter(DontShow)][string]$TraceFile = '',
  [Parameter(DontShow)][string]$DiagFile = '',
  [Parameter(DontShow)][string]$OutDir = '',
  [Parameter(DontShow)][string]$ExePath = '',
  [Parameter(DontShow)][string]$DataDir = '',
  [Parameter(DontShow)][switch]$NoPrompt,
  [Parameter(DontShow)][int]$MaxWait = 240
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1'
$Inv = [Globalization.CultureInfo]::InvariantCulture
$MaxWaitSeconds = $MaxWait
$script:Epoch = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
$script:Problems = New-Object System.Collections.Generic.List[string]
$script:Report = New-Object System.Collections.Generic.List[string]

# ------------------------------------------------------------------ small helpers
function Hide-Private([string]$Text) {
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  $t = $Text
  $pairs = @(
    @($env:LOCALAPPDATA, '%LOCALAPPDATA%'),
    @($env:APPDATA, '%APPDATA%'),
    @($env:TEMP, '%TEMP%'),
    @($env:USERPROFILE, '%USERPROFILE%')
  )
  foreach ($p in $pairs) {
    if (-not [string]::IsNullOrEmpty($p[0]) -and $p[0].Length -ge 4) {
      $t = [regex]::Replace($t, [regex]::Escape($p[0]), $p[1], 'IgnoreCase')
    }
  }
  $t = [regex]::Replace($t, '(?i)[A-Z]:\\Users\\[^\\\s"'']+', '%USERPROFILE%')
  return $t
}

function Tell([string]$Text) { Write-Host (Hide-Private $Text) }

function Add-Line([string]$Text) { $script:Report.Add($Text) }

function Add-Problem([string]$What, $Err) {
  $m = ''
  try { $m = ("$Err" -replace '\s+', ' ') } catch { $m = 'error' }
  if ($m.Length -gt 160) { $m = $m.Substring(0, 160) }
  $script:Problems.Add((Hide-Private ($What + ': ' + $m)))
}

function Get-Safely([scriptblock]$Block, $Default = 'unknown', [string]$What = '') {
  try {
    $v = & $Block
    if ($null -eq $v) { return $Default }
    if (("$v").Trim() -eq '') { return $Default }
    return $v
  } catch {
    if ($What) { Add-Problem $What $_ }
    return $Default
  }
}

function Get-Prop($Obj, [string]$Name, $Default = $null) {
  if ($null -eq $Obj) { return $Default }
  $p = $Obj.PSObject.Properties[$Name]
  if ($null -eq $p) { return $Default }
  return $p.Value
}

function Format-Num($Value, [int]$Dec = 1) {
  if ($null -eq $Value) { return '-' }
  return ([double]$Value).ToString('F' + $Dec, $Inv)
}

# whole milliseconds -> seconds text, rounded half up, no floating point, same on every PC
function Format-Ms($Ms, [int]$Dec = 2) {
  if ($null -eq $Ms) { return '-' }
  $v = [int64]$Ms
  $neg = ($v -lt 0)
  if ($neg) { $v = -$v }
  if ($Dec -eq 1) {
    $r = [int64][math]::Floor(($v + 50) / 100)
    $s = ([int64][math]::Floor($r / 10)).ToString($Inv) + '.' + ($r % 10).ToString($Inv)
  } else {
    $r = [int64][math]::Floor(($v + 5) / 10)
    $s = ([int64][math]::Floor($r / 100)).ToString($Inv) + '.' + ($r % 100).ToString('00', $Inv)
  }
  if ($neg) { $s = '-' + $s }
  return $s
}

function Get-NowMs { return [int64](([DateTime]::UtcNow - $script:Epoch).TotalMilliseconds) }

function ConvertFrom-UnixMs([int64]$Ms) { return $script:Epoch.AddMilliseconds($Ms).ToLocalTime() }

function Format-Local($Dt) { return $Dt.ToString('yyyy-MM-dd HH:mm:ss', $Inv) }

function Wait-Enter([string]$Message) {
  Tell $Message
  if ($NoPrompt) { return }
  try { [void](Read-Host '(press Enter to go on)') } catch { Start-Sleep -Seconds 5 }
}

function Read-JsonSafe([string]$Path, [int]$MaxBytes = 2097152) {
  $fi = New-Object IO.FileInfo($Path)
  if (-not $fi.Exists) { return $null }
  if ($fi.Length -gt $MaxBytes) { throw 'file is unexpectedly large, not read' }
  $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]'ReadWrite,Delete'))
  try {
    $sr = New-Object IO.StreamReader($fs, (New-Object Text.UTF8Encoding($false)), $true)
    $txt = $sr.ReadToEnd()
  } finally { $fs.Dispose() }
  return ($txt | ConvertFrom-Json)
}

# ------------------------------------------------------------------ machine facts
function Get-RegValueAny($Candidates, [string]$ValueName) {
  # Candidates: array of @(hiveName, viewName, subKey). Uses the real registry views,
  # so it also works when PowerShell runs as a 32-bit program.
  foreach ($c in $Candidates) {
    try {
      $hive = [Microsoft.Win32.RegistryHive]$c[0]
      $view = [Microsoft.Win32.RegistryView]$c[1]
      $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
      $k = $base.OpenSubKey($c[2])
      if ($null -ne $k) {
        $v = $k.GetValue($ValueName)
        $k.Close()
        if ($null -ne $v -and "$v" -ne '') { return @("$v", ($c[0] + ' ' + $c[2])) }
      }
    } catch { }
  }
  return $null
}

function Get-InstalledSahelFlow {
  $found = @()
  $targets = @(@('LocalMachine', 'Registry64'), @('LocalMachine', 'Registry32'), @('CurrentUser', 'Registry64'))
  foreach ($t in $targets) {
    try {
      $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]$t[0], [Microsoft.Win32.RegistryView]$t[1])
      $u = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
      if ($null -eq $u) { continue }
      foreach ($n in $u.GetSubKeyNames()) {
        try {
          $k = $u.OpenSubKey($n)
          if ($null -eq $k) { continue }
          $dn = $k.GetValue('DisplayName')
          if ($null -ne $dn -and "$dn" -like 'SahelFlow*') {
            $dv = $k.GetValue('DisplayVersion')
            $found += ("$dn $dv").Trim()
          }
          $k.Close()
        } catch { }
      }
    } catch { }
  }
  if ($found.Count -eq 0) { return $null }
  return ($found | Select-Object -Unique) -join ' / '
}

function Get-SystemDiskInfo {
  $dl = ("$env:SystemDrive").TrimEnd(':')
  if ($dl.Length -ne 1) { return 'unknown (system drive not known)' }
  $part = Get-Partition -DriveLetter $dl
  $all = @(Get-PhysicalDisk)
  $disk = $null
  $pn = Get-Prop $part 'DiskNumber' $null
  if ($null -ne $pn) { $disk = @($all | Where-Object { "$($_.DeviceId)" -eq "$pn" }) | Select-Object -First 1 }
  if ($null -eq $disk -and $all.Count -eq 1) { $disk = $all[0] }
  if ($null -eq $disk) { return 'unknown (Windows did not say which disk)' }
  $mt = "$(Get-Prop $disk 'MediaType' '')"
  $bus = "$(Get-Prop $disk 'BusType' '')"
  $name = "$(Get-Prop $disk 'FriendlyName' '')"
  $sizeGb = ''
  $sz = Get-Prop $disk 'Size' $null
  if ($null -ne $sz) { $sizeGb = ', ' + (Format-Num ([double]$sz / 1GB) 0) + ' GB' }
  if ($mt -eq 'SSD' -or $mt -eq 'HDD') { $kind = $mt } else { $kind = 'unknown (Windows says: ' + $(if ($mt) { $mt } else { 'nothing' }) + ')' }
  $extra = @()
  if ($bus) { $extra += $bus }
  if ($name) { $extra += $name }
  $tail = ''
  if ($extra.Count -gt 0) { $tail = ' [' + ($extra -join ', ') + $sizeGb + ']' } elseif ($sizeGb) { $tail = ' [' + $sizeGb.TrimStart(', ') + ']' }
  return $kind + $tail
}

function Get-MachineFacts {
  $f = [ordered]@{}
  $os = Get-Safely { Get-CimInstance Win32_OperatingSystem } $null 'Windows info'
  $cs = Get-Safely { Get-CimInstance Win32_ComputerSystem } $null 'computer info'
  $cpu = Get-Safely { @(Get-CimInstance Win32_Processor)[0] } $null 'processor info'

  $dispVer = Get-Safely { (Get-RegValueAny @(, @('LocalMachine', 'Registry64', 'SOFTWARE\Microsoft\Windows NT\CurrentVersion')) 'DisplayVersion')[0] } ''
  $f['Windows'] = Get-Safely { ('{0}, version {1}, build {2}{3}' -f $os.Caption.Trim(), $os.Version, $os.BuildNumber, $(if ($dispVer) { ' (' + $dispVer + ')' } else { '' })) } 'unknown'
  $f['Processor'] = Get-Safely { ('{0} ({1} MHz max)' -f (($cpu.Name -replace '\s+', ' ').Trim()), $cpu.MaxClockSpeed) } 'unknown'
  $f['LogicalProcessors'] = Get-Safely { "$($cs.NumberOfLogicalProcessors)" } ("$([Environment]::ProcessorCount)")
  $f['RamGB'] = Get-Safely { Format-Num ([double]$cs.TotalPhysicalMemory / 1GB) 1 } 'unknown'
  $f['RamFreeNowGB'] = Get-Safely { Format-Num ([double]$os.FreePhysicalMemory / 1MB) 1 } 'unknown'
  $f['SystemDisk'] = Get-Safely { Get-SystemDiskInfo } 'unknown (Windows did not answer)' 'disk type'

  $f['SystemDriveFree'] = Get-Safely {
    if (-not $env:SystemDrive) { throw 'system drive not known' }
    $d = New-Object IO.DriveInfo(("$env:SystemDrive").TrimEnd('\') + '\')
    ('{0} GB free of {1} GB' -f (Format-Num ($d.AvailableFreeSpace / 1GB) 1), (Format-Num ($d.TotalSize / 1GB) 1))
  } 'unknown' 'free space'

  $script:BootTime = $null
  try { if ($null -ne $os) { $script:BootTime = $os.LastBootUpTime } } catch { }
  if ($null -ne $script:BootTime) {
    $f['PcOnForMinutes'] = Format-Num (((Get-Date) - $script:BootTime).TotalMinutes) 0
    $f['WindowsStarted'] = Format-Local $script:BootTime
  } else {
    $f['PcOnForMinutes'] = 'unknown'
    $f['WindowsStarted'] = 'unknown'
  }

  $wv = Get-RegValueAny @(
    @('LocalMachine', 'Registry64', 'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'),
    @('LocalMachine', 'Registry64', 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'),
    @('CurrentUser', 'Registry64', 'Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'),
    @('CurrentUser', 'Registry32', 'Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}')
  ) 'pv'
  if ($null -ne $wv) {
    $f['WebView2'] = $wv[0]
    $script:WebView2Pv = $wv[0]
  } else {
    $f['WebView2'] = 'not found in the registry'
    $script:WebView2Pv = ''
  }

  $rt = Get-Safely { (Get-MpComputerStatus -ErrorAction Stop).RealTimeProtectionEnabled } $null
  if ($null -eq $rt) { $rt = Get-Safely { -not (Get-MpPreference -ErrorAction Stop).DisableRealtimeMonitoring } $null 'Defender' }
  if ($null -eq $rt) { $f['DefenderRealTime'] = 'unknown (Windows did not answer)' }
  elseif ($rt) { $f['DefenderRealTime'] = 'ON' }
  else { $f['DefenderRealTime'] = 'OFF' }

  $f['AntivirusProducts'] = Get-Safely {
    $names = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct | ForEach-Object { $_.displayName } | Select-Object -Unique)
    if ($names.Count -eq 0) { 'none reported' } else { $names -join ', ' }
  } 'unknown'

  $exe = $script:ExeToUse
  $f['SahelFlowInstalledList'] = Get-Safely { Get-InstalledSahelFlow } 'not found in the list of installed programs'
  $f['SahelFlowExeVersion'] = Get-Safely {
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { 'exe not found at ' + $exe }
    else { $vi = (Get-Item -LiteralPath $exe).VersionInfo; if (-not $vi.ProductVersion -and -not $vi.FileVersion) { 'exe found, no version written in it' } else { ('product {0}, file {1}' -f $vi.ProductVersion, $vi.FileVersion) } }
  } 'unknown' 'exe version'
  $f['SahelFlowExeFound'] = (Test-Path -LiteralPath $exe -PathType Leaf)
  return $f
}

# ------------------------------------------------------------------ start-up trace
function Get-DataFolders {
  if ($DataDir) { return @($DataDir) }
  $c = @()
  if ($env:APPDATA) { $c += (Join-Path $env:APPDATA 'com.sahelflow.desktop') }
  if ($env:LOCALAPPDATA) { $c += (Join-Path $env:LOCALAPPDATA 'com.sahelflow.desktop') }
  return $c
}

function Find-DataFile([string[]]$Folders, [string]$Name) {
  $best = $null
  foreach ($d in $Folders) {
    try {
      $fi = New-Object IO.FileInfo((Join-Path $d $Name))
      if ($fi.Exists) {
        if ($null -eq $best -or $fi.LastWriteTimeUtc -gt $best.LastWriteTimeUtc) { $best = $fi }
      }
    } catch { }
  }
  return $best
}

# Same reading as the lab: seconds are counted from the FIRST event; when a stage name
# appears twice the LAST one counts (lab reader read_fl.py). The outcome is the first of
# ui-ready / ui-blocked in the file.
function Get-TraceFacts($Trace) {
  $r = @{ Ok = $false; Why = ''; FirstMs = [int64]0; Stage = @{}; Order = $null; AppVersion = ''; Attempts = 0
          Outcome = 'none'; OutcomeMs = $null; Other = ''; LastStage = ''; LastMs = $null }
  $evs = Get-Prop $Trace 'events' $null
  if ($null -eq $evs) { $r.Why = 'the file has no list of events'; return $r }
  $order = New-Object System.Collections.Generic.List[object]
  foreach ($e in @($evs)) {
    $name = [string](Get-Prop $e 'stage' '')
    $t = Get-Prop $e 'createdAtUnixMilliseconds' $null
    if ($name -eq '' -or $null -eq $t) { continue }
    $order.Add([pscustomobject]@{ Stage = $name; Ms = [int64]$t; Attempt = (Get-Prop $e 'attempt' $null) })
  }
  if ($order.Count -eq 0) { $r.Why = 'the list of events is empty'; return $r }
  $first = $order[0].Ms
  $r.FirstMs = $first
  $r.Order = $order
  $r.AppVersion = [string](Get-Prop $Trace 'appVersion' '')
  foreach ($o in $order) {
    $r.Stage[$o.Stage] = ($o.Ms - $first)
    if ($o.Stage -eq 'runtime-attempt-started') { $r.Attempts = $r.Attempts + 1 }
  }
  $last = $order[$order.Count - 1]
  $r.LastStage = $last.Stage
  $r.LastMs = ($last.Ms - $first)
  foreach ($o in $order) {
    if ($o.Stage -eq 'ui-ready' -or $o.Stage -eq 'ui-blocked') {
      if ($r.Outcome -eq 'none') {
        if ($o.Stage -eq 'ui-ready') { $r.Outcome = 'ready' } else { $r.Outcome = 'blocked' }
        $r.OutcomeMs = ($o.Ms - $first)
      } elseif ($r.Other -eq '') {
        $r.Other = ('also {0} at {1} s' -f $o.Stage, (Format-Ms ($o.Ms - $first)))
      }
    }
  }
  $r.Ok = $true
  return $r
}

function Get-StepMs($Facts, [string]$Stage) {
  if ($null -eq $Facts -or -not $Facts.Ok) { return $null }
  if ($Facts.Stage.ContainsKey($Stage)) { return $Facts.Stage[$Stage] }
  return $null
}

function Get-MigrationMs($Facts) {
  $a = Get-StepMs $Facts 'migration-started'
  $b = Get-StepMs $Facts 'migration-complete'
  if ($null -eq $a -or $null -eq $b) { return $null }
  return ($b - $a)
}

function Get-VerdictText($Facts, [string]$EndReason) {
  if ($null -eq $Facts -or -not $Facts.Ok) {
    if ($EndReason -eq 'timeout') { return 'no answer in 4 minutes (no start-up file from this launch was seen)' }
    if ($EndReason -eq 'closed') { return 'SahelFlow closed before it wrote any start-up file' }
    return 'no start-up record to read'
  }
  if ($Facts.Outcome -eq 'ready') { return ('ready in {0} s' -f (Format-Ms $Facts.OutcomeMs 1)) }
  if ($Facts.Outcome -eq 'blocked') { return ('Startup blocked screen after {0} s' -f (Format-Ms $Facts.OutcomeMs 1)) }
  $lastTxt = ('last step seen: {0} at {1} s' -f $Facts.LastStage, (Format-Ms $Facts.LastMs))
  if ($EndReason -eq 'timeout') { return ('no answer in 4 minutes (' + $lastTxt + ')') }
  if ($EndReason -eq 'closed') { return ('SahelFlow closed before it was ready (' + $lastTxt + ')') }
  return ('the last launch never reached ui-ready or ui-blocked (' + $lastTxt + ')')
}

function Get-DiagFacts($Diag, [int64]$FirstMs) {
  $d = @{ Ok = $false; Text = @() }
  if ($null -eq $Diag) { return $d }
  $created = Get-Prop $Diag 'createdAtUnixSeconds' $null
  if ($null -ne $created -and $FirstMs -gt 0 -and ([int64]$created * 1000) -lt ($FirstMs - 5000)) {
    $d.Text = @('runtime-ui-diagnostic.json is from an older launch, not used')
    return $d
  }
  $tm = Get-Prop $Diag 'uiTiming' $null
  $lines = @()
  $lines += ('state {0}, code {1}, start attempt {2}' -f (Get-Prop $Diag 'state' '?'), (Get-Prop $Diag 'code' '?'), (Get-Prop $Diag 'attempt' '?'))
  if ($null -ne $tm) {
    $lines += ('page inside the window: first paint {0} ms, largest paint {1} ms, page report at {2} ms' -f (Get-Prop $tm 'firstContentfulPaintMs' '?'), (Get-Prop $tm 'largestContentfulPaintMs' '?'), (Get-Prop $tm 'beaconMs' '?'))
    $lines += ('page files: {0} scripts, {1} resources, {2} KB transferred' -f (Get-Prop $tm 'scriptCount' '?'), (Get-Prop $tm 'resourceCount' '?'), $(if ($null -ne (Get-Prop $tm 'resourceTransferBytes' $null)) { Format-Num ([double](Get-Prop $tm 'resourceTransferBytes' 0) / 1KB) 0 } else { '?' }))
    $slow = @(Get-Prop $tm 'slowResources' @())
    $k = 0
    foreach ($s in $slow) {
      if ($k -ge 3) { break }
      $lines += ('slow page file {0}: {1} ms  {2}' -f ($k + 1), (Get-Prop $s 'ms' '?'), (Get-Prop $s 'name' '?'))
      $k++
    }
  }
  $d.Ok = $true
  $d.Text = $lines
  return $d
}

function Read-DiagFor([string[]]$Folders, [int64]$FirstMs) {
  $fi = $null
  if ($DiagFile) { $fi = New-Object IO.FileInfo($DiagFile) } else { $fi = Find-DataFile $Folders 'runtime-ui-diagnostic.json' }
  if ($null -eq $fi -or -not $fi.Exists) { return @{ Ok = $false; Text = @('runtime-ui-diagnostic.json not found') } }
  $j = Read-JsonSafe $fi.FullName
  return (Get-DiagFacts $j $FirstMs)
}

# ------------------------------------------------------------------ guided launch
function Invoke-GuidedLaunch([string]$Label, [string]$Exe, [string[]]$Folders) {
  $rec = @{ Label = $Label; Started = $false; Verdict = ''; Facts = $null; Diag = $null; Wall = $null
            UptimeMin = $null; TraceFile = ''; LaunchLocal = ''; EndReason = '' }
  $pn = [IO.Path]::GetFileNameWithoutExtension($Exe)
  Tell ''
  Tell ('=== ' + $Label + ' ===')
  Tell 'Please CLOSE SahelFlow completely now (click the X on its window).'
  Tell 'When you press Enter the clock starts and this script starts SahelFlow by itself.'
  Wait-Enter 'Press Enter when SahelFlow is closed.'
  $tries = 0
  while (@(Get-Process -Name $pn -ErrorAction SilentlyContinue).Count -gt 0) {
    $tries++
    if ($tries -gt 3) {
      $rec.Verdict = 'not started: SahelFlow was still running'
      $rec.EndReason = 'still-running'
      return $rec
    }
    Wait-Enter 'SahelFlow is still running. Close it (if it will not close: press Ctrl+Shift+Esc, find SahelFlow, End task). Then press Enter.'
    Start-Sleep -Seconds 2
  }
  if ($null -ne $script:BootTime) { $rec.UptimeMin = ((Get-Date) - $script:BootTime).TotalMinutes }
  $startMs = Get-NowMs
  $startUtc = [DateTime]::UtcNow
  $rec.LaunchLocal = Format-Local (Get-Date)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $proc = $null
  try {
    $proc = Start-Process -FilePath $Exe -PassThru -ErrorAction Stop
  } catch {
    Add-Problem 'start SahelFlow' $_
    $rec.Verdict = 'could not start SahelFlow'
    $rec.EndReason = 'no-start'
    return $rec
  }
  $rec.Started = $true
  Tell 'SahelFlow is starting. Please wait and do not touch the PC (up to 4 minutes).'

  $fresh = $null
  $lastSig = ''
  $nextNote = 10
  $deadSince = $null
  $reason = 'timeout'
  $seenFolder = ''
  while ($sw.Elapsed.TotalSeconds -lt $MaxWaitSeconds) {
    Start-Sleep -Milliseconds 600
    try {
      $fi = Find-DataFile $Folders 'startup-trace.json'
      if ($null -ne $fi) {
        $sig = '{0}|{1}|{2}' -f $fi.FullName, $fi.Length, $fi.LastWriteTimeUtc.Ticks
        if ($sig -ne $lastSig) {
          $lastSig = $sig
          $tr = Read-JsonSafe $fi.FullName
          $tf = Get-TraceFacts $tr
          if ($tf.Ok -and $tf.FirstMs -ge ($startMs - 5000)) { $fresh = $tf; $seenFolder = $fi.FullName }
        }
      }
    } catch { }
    if ($null -ne $fresh -and $fresh.Outcome -ne 'none') { $reason = 'done'; break }
    $alive = $false
    try { if ($null -ne $proc -and -not $proc.HasExited) { $alive = $true } } catch { $alive = $true }
    if (-not $alive) { if (@(Get-Process -Name $pn -ErrorAction SilentlyContinue).Count -gt 0) { $alive = $true } }
    if ($alive) { $deadSince = $null } else {
      if ($null -eq $deadSince) { $deadSince = $sw.Elapsed.TotalSeconds }
      elseif (($sw.Elapsed.TotalSeconds - $deadSince) -ge 8) { $reason = 'closed'; break }
    }
    if ($sw.Elapsed.TotalSeconds -ge $nextNote) {
      $step = 'no start-up file seen yet'
      if ($null -ne $fresh) { $step = 'last step: ' + $fresh.LastStage }
      Tell ('  {0} s ... {1}' -f ([int][math]::Floor($sw.Elapsed.TotalSeconds)), $step)
      $nextNote += 10
    }
  }
  $rec.Wall = $sw.Elapsed.TotalSeconds
  $rec.EndReason = $reason
  $rec.Facts = $fresh
  $rec.TraceFile = $seenFolder
  if ($null -ne $fresh) {
    # the diagnostic file is written right after ui-ready: give it a few seconds
    for ($i = 0; $i -lt 8; $i++) {
      try {
        $dfi = Find-DataFile $Folders 'runtime-ui-diagnostic.json'
        if ($null -ne $dfi -and $dfi.LastWriteTimeUtc -ge $startUtc.AddSeconds(-5)) { break }
      } catch { }
      if ($reason -ne 'done') { break }
      Start-Sleep -Milliseconds 800
    }
    try { $rec.Diag = Read-DiagFor $Folders $fresh.FirstMs } catch { Add-Problem 'diagnostic file' $_ }
  }
  $rec.Verdict = Get-VerdictText $fresh $reason
  Tell ('Result: ' + $rec.Verdict)
  return $rec
}

# ------------------------------------------------------------------ disk tests
function Measure-SmallWrites([string]$Dir, [string]$Prefix, [bool]$WriteThrough, [int]$Count, [double]$MaxSeconds) {
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  $buf = New-Object byte[] 4096
  (New-Object Random 7).NextBytes($buf)
  $times = New-Object System.Collections.Generic.List[double]
  $all = [Diagnostics.Stopwatch]::StartNew()
  for ($i = 0; $i -lt $Count; $i++) {
    if ($all.Elapsed.TotalSeconds -gt $MaxSeconds) { break }
    $path = Join-Path $Dir ($Prefix + $i.ToString($Inv) + '.bin')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    if ($WriteThrough) {
      $fs = New-Object IO.FileStream($path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    } else {
      $fs = [IO.File]::Open($path, 'Create', 'Write', 'None')
    }
    try { $fs.Write($buf, 0, $buf.Length); $fs.Flush($true) } finally { $fs.Dispose() }
    $times.Add($sw.Elapsed.TotalMilliseconds)
  }
  $s = $times.ToArray()
  [Array]::Sort($s)
  $n = $s.Length
  if ($n -eq 0) { return $null }
  $sum = 0.0
  foreach ($x in $s) { $sum += $x }
  return @{ N = $n; P50 = $s[[int][math]::Floor($n * 50 / 100)]; P95 = $s[[int][math]::Floor($n * 95 / 100)]; Max = $s[$n - 1]; TotalS = ($sum / 1000.0) }
}

function Measure-SeqWrite([string]$Dir, [int]$Mb, [double]$MaxSeconds) {
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  $buf = New-Object byte[] 1048576
  (New-Object Random 11).NextBytes($buf)
  $path = Join-Path $Dir 'seq64.bin'
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $fs = New-Object IO.FileStream($path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None, 1048576, [IO.FileOptions]::WriteThrough)
  $written = 0
  try {
    for ($i = 0; $i -lt $Mb; $i++) {
      if ($sw.Elapsed.TotalSeconds -gt $MaxSeconds) { break }
      $fs.Write($buf, 0, $buf.Length)
      $written++
    }
    $fs.Flush($true)
  } finally { $fs.Dispose() }
  $sec = $sw.Elapsed.TotalSeconds
  return @{ Mb = $written; Seconds = $sec; MbPerS = $(if ($sec -gt 0) { $written / $sec } else { 0 }) }
}

function Invoke-DiskTests {
  $res = @{ Ran = $false; Drive = ''; Lab = $null; Through = $null; Seq = $null; Note = '' }
  $root = Join-Path ([IO.Path]::GetTempPath()) ('sahelflow-pc-check-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
  $res.Drive = Get-Safely { Split-Path -Qualifier $root } 'unknown'
  try {
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $freeMb = Get-Safely { (New-Object IO.DriveInfo((Split-Path -Qualifier $root) + '\')).AvailableFreeSpace / 1MB } 99999
    if ([double]$freeMb -lt 300) { $res.Note = 'less than 300 MB free on the temporary drive: disk test skipped'; return $res }
    Tell 'Disk test 1 of 3: 300 small writes forced to disk (the lab method) ...'
    $res.Lab = Measure-SmallWrites (Join-Path $root 'a') 'w' $false 300 90
    Tell 'Disk test 2 of 3: the same with write-through ...'
    $res.Through = Measure-SmallWrites (Join-Path $root 'b') 'w' $true 300 90
    Tell 'Disk test 3 of 3: one 64 MB file ...'
    $res.Seq = Measure-SeqWrite (Join-Path $root 'c') 64 120
    $res.Ran = $true
  } catch {
    Add-Problem 'disk test' $_
  } finally {
    # remove only the folder this test made itself
    try {
      $leaf = Split-Path -Leaf $root
      if ($leaf -like 'sahelflow-pc-check-*' -and (Test-Path -LiteralPath $root)) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop }
    } catch { Add-Problem 'remove test files' $_ }
  }
  return $res
}

function Invoke-WebView2Read([string]$Pv) {
  $r = @{ Found = $false; Folder = ''; Files = 0; Mb = 0; Seconds = 0; MbPerS = 0; Errors = 0; Stopped = $false }
  $bases = @()
  if (${env:ProgramFiles(x86)}) { $bases += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\EdgeWebView\Application') }
  if ($env:ProgramFiles) { $bases += (Join-Path $env:ProgramFiles 'Microsoft\EdgeWebView\Application') }
  if ($env:LOCALAPPDATA) { $bases += (Join-Path $env:LOCALAPPDATA 'Microsoft\EdgeWebView\Application') }
  $dir = $null
  foreach ($b in $bases) {
    if ($Pv) {
      $d = Join-Path $b $Pv
      if (Test-Path -LiteralPath $d -PathType Container) { $dir = $d; break }
    }
  }
  if ($null -eq $dir) {
    foreach ($b in $bases) {
      try {
        $vd = @(Get-ChildItem -LiteralPath $b -Directory -ErrorAction Stop | Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } | Sort-Object { [version]$_.Name } -Descending)
        if ($vd.Count -gt 0) { $dir = $vd[0].FullName; break }
      } catch { }
    }
  }
  if ($null -eq $dir -or $dir -match 'EBWebView') { return $r }
  $r.Found = $true
  $r.Folder = $dir
  Tell 'Reading the WebView2 program folder once (10 to 60 seconds, the disk will be busy) ...'
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue)
  $buf = New-Object byte[] 1048576
  $bytes = [int64]0
  $errs = 0
  $share = [IO.FileShare]'ReadWrite,Delete'
  $next = 15
  foreach ($f in $files) {
    if ($sw.Elapsed.TotalSeconds -gt 240) { $r.Stopped = $true; break }
    try {
      $fs = New-Object IO.FileStream($f.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share, 1048576, [IO.FileOptions]::SequentialScan)
      try { while (($k = $fs.Read($buf, 0, $buf.Length)) -gt 0) { $bytes += $k } } finally { $fs.Dispose() }
    } catch { $errs++ }
    if ($sw.Elapsed.TotalSeconds -ge $next) { Tell ('  still reading ... {0} s' -f ([int]$sw.Elapsed.TotalSeconds)); $next += 15 }
  }
  $sec = $sw.Elapsed.TotalSeconds
  $r.Files = $files.Count
  $r.Mb = $bytes / 1MB
  $r.Seconds = $sec
  $r.Errors = $errs
  if ($sec -gt 0) { $r.MbPerS = ($bytes / 1MB) / $sec }
  return $r
}

# ------------------------------------------------------------------ report pieces
function Add-StartupTable($Recs) {
  $w = 14
  $head = ('{0,-34}' -f 'Seconds after the first event')
  foreach ($r in $Recs) { $head += (($r.Label -replace ' \(.*$', '').PadRight($w)) }
  Add-Line $head
  $rows = @(
    @('splash shown', 'splash-painted'),
    @('migration step (length)', 'MIG'),
    @('runtime ready', 'runtime-ready'),
    @('window created', 'workspace-window-created'),
    @('page loading started', 'ui-navigation-started'),
    @('UI ready (or BLOCKED)', 'UI'),
    @('wall clock, click to detected', 'WALL')
  )
  if (@($Recs | Where-Object { $null -ne $_.Wall }).Count -eq 0) { $rows = @($rows | Where-Object { $_[1] -ne 'WALL' }) }
  foreach ($row in $rows) {
    $line = ('{0,-34}' -f $row[0])
    foreach ($r in $Recs) {
      $cell = '-'
      $f = $r.Facts
      if ($row[1] -eq 'MIG') { $cell = Format-Ms (Get-MigrationMs $f) }
      elseif ($row[1] -eq 'UI') {
        if ($null -ne $f -and $f.Ok) {
          if ($f.Outcome -eq 'ready') { $cell = Format-Ms $f.OutcomeMs }
          elseif ($f.Outcome -eq 'blocked') { $cell = 'BLOCKED ' + (Format-Ms $f.OutcomeMs) }
          else { $cell = 'not reached' }
        }
      }
      elseif ($row[1] -eq 'WALL') { if ($null -ne $r.Wall) { $cell = Format-Num $r.Wall 1 } }
      else { $cell = Format-Ms (Get-StepMs $f $row[1]) }
      $line += ([string]$cell).PadRight($w)
    }
    Add-Line $line
  }
}

function Add-LaunchDetails($Recs) {
  foreach ($r in $Recs) {
    $f = $r.Facts
    Add-Line ''
    Add-Line ($r.Label + ':')
    Add-Line ('  verdict: ' + $r.Verdict)
    if ($r.LaunchLocal) { Add-Line ('  started by this script at: ' + $r.LaunchLocal + ' (PC clock)') }
    if ($null -ne $f -and $f.Ok) {
      $t0 = ConvertFrom-UnixMs $f.FirstMs
      Add-Line ('  first event of the app (process-started) at: ' + (Format-Local $t0) + ' (PC clock)')
      if ($null -ne $script:BootTime) {
        $mins = ($t0 - $script:BootTime).TotalMinutes
        if ($mins -ge 0) { Add-Line ('  Windows had been on for {0} minutes when the app started' -f (Format-Num $mins 0)) }
        else { Add-Line '  this record is from before the last Windows start' }
      }
      Add-Line ('  app version written in the trace: ' + $(if ($f.AppVersion) { $f.AppVersion } else { 'not written' }))
      Add-Line ('  runtime start attempts: ' + $f.Attempts)
      if ($f.Other) { Add-Line ('  note: ' + $f.Other) }
      if ($f.Outcome -eq 'none') { Add-Line ('  last step seen: {0} at {1} s' -f $f.LastStage, (Format-Ms $f.LastMs)) }
    }
    if ($null -ne $r.UptimeMin) { Add-Line ('  PC had been on for {0} minutes when this launch began' -f (Format-Num $r.UptimeMin 0)) }
    if ($null -ne $r.Diag) { foreach ($l in $r.Diag.Text) { Add-Line ('  ' + $l) } }
  }
}

function Add-DiskLines($Disk) {
  Add-Line ('Where the test ran: temporary folder on drive ' + $Disk.Drive)
  if ($Disk.Note) { Add-Line ('  ' + $Disk.Note) }
  if (-not $Disk.Ran) { if (-not $Disk.Note) { Add-Line '  disk test did not complete (see problems below)' } }
  if ($null -ne $Disk.Lab) {
    $x = $Disk.Lab
    Add-Line ('4 KB write forced to disk, lab method (n={0}): p50 {1} ms, p95 {2} ms, max {3} ms, total {4} s' -f $x.N, (Format-Num $x.P50 2), (Format-Num $x.P95 2), (Format-Num $x.Max 2), (Format-Num $x.TotalS 2))
  }
  if ($null -ne $Disk.Through) {
    $x = $Disk.Through
    Add-Line ('4 KB write, write-through + forced (n={0}): p50 {1} ms, p95 {2} ms, max {3} ms, total {4} s' -f $x.N, (Format-Num $x.P50 2), (Format-Num $x.P95 2), (Format-Num $x.Max 2), (Format-Num $x.TotalS 2))
  }
  if ($null -ne $Disk.Seq) {
    $x = $Disk.Seq
    $partial = ''
    if ($x.Mb -lt 64) { $partial = ' (stopped early)' }
    Add-Line ('sequential write {0} MB: {1} s = {2} MB/s{3}' -f $x.Mb, (Format-Num $x.Seconds 2), (Format-Num $x.MbPerS 1), $partial)
  }
}

function Save-ReportFile([string[]]$Lines, [string]$ComputerName) {
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmm', $Inv)
  $cn = [regex]::Replace($ComputerName, '[^A-Za-z0-9._-]', '_')
  $baseName = 'sahelflow-pc-check-' + $cn + '-' + $stamp
  $dirs = @()
  if ($OutDir) {
    $dirs += $OutDir
  } else {
    $sd = ''
    try { $sd = $PSScriptRoot } catch { }
    if (-not $sd) { try { $sd = Split-Path -Parent $MyInvocation.MyCommand.Path } catch { } }
    if ($sd) { $dirs += $sd }
    try { $dirs += [Environment]::GetFolderPath('Desktop') } catch { }
    $dirs += [IO.Path]::GetTempPath()
  }
  $text = ($Lines -join "`r`n") + "`r`n"
  $enc = New-Object Text.UTF8Encoding($true)
  foreach ($d in $dirs) {
    try {
      if (-not $d) { continue }
      if ($OutDir -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
      if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
      $n = 1
      $path = Join-Path $d ($baseName + '.txt')
      while (Test-Path -LiteralPath $path) { $n++; $path = Join-Path $d ($baseName + '-' + $n + '.txt') }
      [IO.File]::WriteAllText($path, $text, $enc)
      return $path
    } catch { }
  }
  return $null
}

# ------------------------------------------------------------------ main
$computer = 'unknown-pc'
try { $computer = [Environment]::MachineName } catch { }
$script:BootTime = $null
$script:WebView2Pv = ''
$pfDir = $env:ProgramW6432
if (-not $pfDir) { $pfDir = $env:ProgramFiles }
if (-not $pfDir) { $pfDir = 'C:\Program Files' }
$script:ExeToUse = $(if ($ExePath) { $ExePath } else { $pfDir.TrimEnd('\') + '\SahelFlow\sahelflow.exe' })
if ($Twice) { $Launch = [switch]$true }

$options = @()
if ($Launch) { $options += '-Launch' }
if ($Twice) { $options += '-Twice' }
if ($ReadWebView2) { $options += '-ReadWebView2' }
if ($TraceFile) { $options += '-TraceFile (test)' }
if ($options.Count -eq 0) { $options += '(none: read last launch)' }

$facts = $null
$recs = @()
$disk = $null
$wvRead = $null
$wvAfterLaunch = $false
$folders = Get-DataFolders
$traceUsed = ''
$readOnlyNote = ''

Write-Host ''
Write-Host ('SahelFlow PC check, script version ' + $ScriptVersion)
Write-Host 'It only reads and measures. It sends nothing anywhere. Details are at the top of the script file.'

try {
  if ($TraceFile) {
    # test mode: only analyse one given trace file, no machine checks
    $label = 'Trace file'
    $rec = @{ Label = $label; Started = $false; Verdict = ''; Facts = $null; Diag = $null; Wall = $null; UptimeMin = $null; TraceFile = $TraceFile; LaunchLocal = ''; EndReason = '' }
    try {
      $tf = Get-TraceFacts (Read-JsonSafe $TraceFile)
      $rec.Facts = $tf
      if ($tf.Ok) {
        try { $rec.Diag = $(if ($DiagFile) { Read-DiagFor @() $tf.FirstMs } else { $null }) } catch { Add-Problem 'diagnostic file' $_ }
      } else { $readOnlyNote = 'cannot use the trace: ' + $tf.Why }
    } catch { Add-Problem 'read trace' $_; $readOnlyNote = 'cannot read the trace file' }
    $rec.Verdict = Get-VerdictText $rec.Facts ''
    $recs = @($rec)
  } else {
    Tell ''
    Tell 'Step 1: facts about this PC (on a slow PC this can take a minute) ...'
    $facts = Get-MachineFacts

    if ($Launch) {
      if (-not (Test-Path -LiteralPath $script:ExeToUse -PathType Leaf)) {
        Tell ('SahelFlow was not found at ' + $script:ExeToUse + ' - no launch test.')
        $recs = @(@{ Label = 'Launch 1'; Started = $false; Verdict = 'not started: sahelflow.exe not found'; Facts = $null; Diag = $null; Wall = $null; UptimeMin = $null; TraceFile = ''; LaunchLocal = ''; EndReason = 'no-exe' })
      } else {
        Tell ''
        Tell 'Step 2: guided launch. For the cold number the PC should have been restarted a few minutes ago.'
        $first = Invoke-GuidedLaunch 'Launch 1 (first)' $script:ExeToUse $folders
        $recs += , $first
        if ($Twice -and $first.Started) {
          $second = Invoke-GuidedLaunch 'Launch 2 (warm)' $script:ExeToUse $folders
          $recs += , $second
        }
      }
    } else {
      Tell ''
      Tell 'Step 2: reading the start-up file of the last launch (no launch; add -Launch to measure a new one) ...'
      $rec = @{ Label = 'Last launch'; Started = $false; Verdict = ''; Facts = $null; Diag = $null; Wall = $null; UptimeMin = $null; TraceFile = ''; LaunchLocal = ''; EndReason = '' }
      $fi = Find-DataFile $folders 'startup-trace.json'
      if ($null -eq $fi) {
        $readOnlyNote = 'No startup-trace.json found. Start SahelFlow once, wait until it is open, then run this check again (or use -Launch).'
        $rec.Verdict = 'no start-up record found - start SahelFlow once first'
      } else {
        $rec.TraceFile = $fi.FullName
        try {
          $tf = Get-TraceFacts (Read-JsonSafe $fi.FullName)
          $rec.Facts = $tf
          if ($tf.Ok) {
            try { $rec.Diag = Read-DiagFor $folders $tf.FirstMs } catch { Add-Problem 'diagnostic file' $_ }
            $readOnlyNote = 'This is the trace of the last launch only; the file was last written at ' + (Format-Local $fi.LastWriteTime) + ' (PC clock).'
          } else { $readOnlyNote = 'The trace file could not be used: ' + $tf.Why }
        } catch { Add-Problem 'read trace' $_; $readOnlyNote = 'The trace file could not be read.' }
        $rec.Verdict = Get-VerdictText $rec.Facts ''
      }
      $recs = @($rec)
    }

    foreach ($r in $recs) { if ($r.TraceFile -and -not $traceUsed) { $traceUsed = $r.TraceFile } }

    if ($ReadWebView2) {
      $wvAfterLaunch = [bool]($Launch -and @($recs | Where-Object { $_.Started }).Count -gt 0)
      if ($wvAfterLaunch) { Wait-Enter 'Before the WebView2 read: close SahelFlow if it is open.' }
      try { $wvRead = Invoke-WebView2Read $script:WebView2Pv } catch { Add-Problem 'WebView2 read' $_ }
    }

    $anyStarted = (@($recs | Where-Object { $_.Started }).Count -gt 0)
    $appOpenForDisk = $false
    if ($anyStarted) {
      Wait-Enter 'Now the disk test. Please CLOSE SahelFlow so the disk is quiet.'
      Start-Sleep -Seconds 3
      $appOpenForDisk = (@(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($script:ExeToUse)) -ErrorAction SilentlyContinue).Count -gt 0)
    }
    Tell ''
    Tell 'Step 3: disk speed test (about 10 to 60 seconds) ...'
    $disk = Invoke-DiskTests
    if ($appOpenForDisk) { $disk.Note = ($disk.Note + ' SahelFlow was still open during the disk test.').Trim() }
  }
} catch {
  Add-Problem 'unexpected error' $_
}

# ---- build the report (screen and file are the same text)
Add-Line 'SahelFlow PC check'
Add-Line ('Script version     : ' + $ScriptVersion + '   options: ' + ($options -join ' '))
Add-Line ('Computer name      : ' + $computer)
Add-Line ('Run at (PC clock)  : ' + (Format-Local (Get-Date)))
Add-Line ''
Add-Line '== RESULT =='
foreach ($r in $recs) { Add-Line ('{0,-20}: {1}' -f $r.Label, $r.Verdict) }
if ($readOnlyNote) { Add-Line $readOnlyNote }
if ($recs.Count -gt 0 -and $recs[0].Label -like 'Launch 1*' -and $recs[0].Started) {
  Add-Line 'Launch 1 is the COLD number only if Windows was restarted a few minutes before.'
  if ($recs.Count -gt 1) { Add-Line 'Launch 2 is the WARM number (files already in memory).' }
}
Add-Line ''
Add-Line '== START-UP TIMES =='
if (@($recs | Where-Object { $null -ne $_.Facts }).Count -gt 0) { Add-StartupTable $recs } else { Add-Line '(no start-up times: no start-up record was read)' }
if ($traceUsed) { Add-Line ('Start-up file used: ' + (Hide-Private $traceUsed)) }
elseif (-not $TraceFile) { Add-Line ('Start-up file looked for in: ' + ((@($folders) | ForEach-Object { Hide-Private $_ }) -join ' , ')) }
Add-LaunchDetails $recs

if ($null -ne $facts) {
  Add-Line ''
  Add-Line '== THIS PC =='
  Add-Line ('Windows              : ' + $facts['Windows'])
  Add-Line ('Processor            : ' + $facts['Processor'])
  Add-Line ('Logical processors   : ' + $facts['LogicalProcessors'])
  Add-Line ('Memory (RAM)         : ' + $facts['RamGB'] + ' GB installed, ' + $facts['RamFreeNowGB'] + ' GB free when the script started')
  Add-Line ('System disk type     : ' + $facts['SystemDisk'])
  Add-Line ('System drive space   : ' + $facts['SystemDriveFree'])
  Add-Line ('Windows started at   : ' + $facts['WindowsStarted'] + ' (on for ' + $facts['PcOnForMinutes'] + ' min when the script started)')
  Add-Line ('WebView2 runtime     : ' + $facts['WebView2'])
  Add-Line ('Defender real-time   : ' + $facts['DefenderRealTime'])
  Add-Line ('Antivirus products   : ' + $facts['AntivirusProducts'])
  Add-Line ('SahelFlow installed  : ' + $facts['SahelFlowInstalledList'])
  Add-Line ('SahelFlow exe        : ' + $facts['SahelFlowExeVersion'])
}

if ($null -ne $disk) {
  Add-Line ''
  Add-Line '== DISK SPEED =='
  Add-DiskLines $disk
}
if ($ReadWebView2) {
  Add-Line ''
  Add-Line '== WEBVIEW2 PROGRAM FOLDER READ =='
  if ($null -eq $wvRead -or -not $wvRead.Found) { Add-Line 'WebView2 program folder not found: not measured.' }
  else {
    Add-Line ('Folder: ' + (Hide-Private $wvRead.Folder))
    Add-Line ('{0} files, {1} MB read in {2} s = {3} MB/s{4}' -f $wvRead.Files, (Format-Num $wvRead.Mb 0), (Format-Num $wvRead.Seconds 1), (Format-Num $wvRead.MbPerS 1), $(if ($wvRead.Stopped) { ' (stopped after 240 s)' } else { '' }))
    if ($wvRead.Errors -gt 0) { Add-Line ('{0} files could not be read' -f $wvRead.Errors) }
    if ($wvAfterLaunch) { Add-Line 'SahelFlow had been started before this read, so this is a WARM read, not the cold number.' }
    else { Add-Line 'This is a cold read only if Windows was restarted a few minutes before and SahelFlow was not opened.' }
  }
}

Add-Line ''
Add-Line '== LAB REFERENCE (datacenter machine with an SSD, not a real PC) =='
Add-Line '4 KB forced write: p50 about 5 ms (3.4 to 9 ms), p95 8 to 60 ms.'
Add-Line 'WebView2 program folder read: 871 MB in 13 to 27 s (47 to 66 MB/s).'
Add-Line 'First launch in the lab (build final2, 3 runs): UI ready after 10.8 to 18.4 s.'
Add-Line ''
Add-Line '== NOT MEASURED =='
Add-Line 'This check sees only the START of the app. It does not see the real work of a seller'
Add-Line '(sales, stock, printing, WhatsApp, a big shop database, a power cut). It is one PC,'
Add-Line 'one or two launches; the numbers change a little from one run to the next.'
if ($script:Problems.Count -gt 0) {
  Add-Line ''
  Add-Line '== PROBLEMS DURING THE CHECK (the rest still ran) =='
  foreach ($p in $script:Problems) { Add-Line ('- ' + $p) }
}

$finalLines = @($script:Report | ForEach-Object { Hide-Private $_ })
Write-Host ''
Write-Host '=================================================================='
foreach ($l in $finalLines) { Write-Host $l }
Write-Host '=================================================================='

$saved = $null
try {
  if ($TraceFile -and -not $OutDir) { $saved = $null } else { $saved = Save-ReportFile $finalLines $computer }
} catch { $saved = $null }
Write-Host ''
if ($saved) {
  Write-Host 'The report was saved in this file (send ONLY this file):'
  Write-Host ('  ' + $saved)
} elseif (-not ($TraceFile -and -not $OutDir)) {
  Write-Host 'The report could not be saved to a file. Please take a photo of this screen.'
}

if (-not $NoPause -and -not $NoPrompt -and -not $TraceFile) {
  try { [void](Read-Host 'Press Enter to close this window') } catch { }
}
