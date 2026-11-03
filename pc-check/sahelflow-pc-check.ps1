<#
=====================================================================================
 SahelFlow PC check  -  script version 2
=====================================================================================
 WHAT THIS IS
   It records how fast SahelFlow starts on THIS PC, how fast this PC's disk is, and a few
   facts that can explain why the installed app is slow or why WhatsApp messages wait. It
   writes the numbers into ONE small text file that you can send back. The first 8 lines of
   that file are a plain summary. It is read-only for everything except its own report file.

 WHAT IT READS (and nothing else)
   1. Facts that Windows gives about this PC: Windows version, processor and number of cores,
      memory, the type of the system disk (SSD or hard disk), free disk space, how long the
      PC has been on, the power plan, whether the PC runs on battery or mains power, the
      Microsoft WebView2 version, whether Windows Defender real-time protection is on, HOW MANY
      exclusions Defender has (only the number, never the list), the names of antivirus products,
      and the version of SahelFlow (from the list of installed programs and from the properties
      of C:\Program Files\SahelFlow\sahelflow.exe).
   2. Two small files that SahelFlow itself writes about its own start:
         startup-trace.json   and   runtime-ui-diagnostic.json
      in the folder  %APPDATA%\com.sahelflow.desktop  (or, if not there,
      %LOCALAPPDATA%\com.sahelflow.desktop).
   3. Sizes only (new in version 2): the script lists the SahelFlow data folders and adds up
      the size and the number of files. It reports the size of the shop database files (and of
      their -wal file), of the log files, and how many files wait in the WhatsApp spool folder
      and how old the oldest one is. It never OPENS the shop database, customers, keys,
      passwords, licence or the waiting WhatsApp files, and it writes no file name from these
      folders into the report. The only folder names written are a fixed list of the app's own
      folders (for example shops, logs, whatsapp-inbound-spool).
   4. The WhatsApp diagnostics log (new in version 2): <data folder>\logs\whatsapp-diagnostics.log
      and the older copy .log.1. SahelFlow already removes phone numbers and names from this file.
      The script reads it line by line but keeps only five things from each line: the time, the
      event name, the error code, the attempt number and the appStatus. Everything else in the
      line is thrown away at once. The report shows COUNTS only; every text is cut to 64
      characters, long digit runs and anything with an @ are replaced.
   5. The running programs for 10 seconds (new in version 2): program names, memory in use and
      processor seconds. No window titles, no command lines, no file paths are written. (The
      command line of WebView2 helper programs is looked at only to tell which of them belong
      to SahelFlow; it is not written.)
   6. ONLY if you add -ReadWebView2: every file of Microsoft's WebView2 program
      folder (under Program Files) is read once and the data is thrown away, to
      time a cold read of the disk. This takes 10 to 60 seconds.

 WHAT IT WRITES
   1. One report:  sahelflow-pc-check-<computer name>-<date>-<time>.txt
      in the folder where this script is (or on the Desktop if that folder is not
      writable). The report has the computer name but not your user name; the
      profile folder is shown as %USERPROFILE%.
   2. During the disk wait test and the disk test: temporary test files in a new
      folder inside your temporary folder (%TEMP%): 30 small writes of 4 KB in one file,
      and, in the disk test, at most about 70 MB. They are deleted at the end of
      each test. This is the only thing written outside the report.
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
   (none)          read the start-up file of the last launch + machine facts + data sizes +
                   WhatsApp log counts + running programs + disk tests
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

$ScriptVersion = '2'
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
  $spin = Get-Prop $disk 'SpindleSpeed' $null
  if ($null -ne $spin -and "$spin" -match '^\d+$') {
    $sp = [int64]$spin
    if ($sp -gt 0 -and $sp -lt 100000) { $extra += ('Windows says: spinning disk, ' + $sp + ' rpm') }
    elseif ($sp -eq 0) { $extra += 'Windows says: spindle speed 0 (no spinning)' }
  }
  $tail = ''
  if ($extra.Count -gt 0) { $tail = ' [' + ($extra -join ', ') + $sizeGb + ']' } elseif ($sizeGb) { $tail = ' [' + $sizeGb.TrimStart(', ') + ']' }
  return $kind + $tail
}

# Used only when Get-PhysicalDisk cannot say what the system disk is (old Windows, missing storage module).
function Get-SystemDiskInfoWmi {
  $dl = ("$env:SystemDrive").TrimEnd(':')
  if ($dl.Length -ne 1) { return $null }
  $ld = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='" + $dl + ":'") -ErrorAction Stop
  $part = Get-CimAssociatedInstance -InputObject $ld -Association Win32_LogicalDiskToPartition -ErrorAction Stop
  $drv = @(Get-CimAssociatedInstance -InputObject $part -Association Win32_DiskDriveToDiskPartition -ErrorAction Stop)
  if ($drv.Count -eq 0) { return $null }
  $d = $drv[0]
  $model = ("$(Get-Prop $d 'Model' '')" -replace '\s+', ' ').Trim()
  $iface = "$(Get-Prop $d 'InterfaceType' '')"
  $guess = 'the model name does not say SSD or HDD'
  if ($model -match '(?i)SSD|NVMe|Solid') { $guess = 'the model name says SSD/NVMe' }
  $sz = Get-Prop $d 'Size' $null
  $szTxt = ''
  if ($null -ne $sz) { $szTxt = ', ' + (Format-Num ([double]$sz / 1GB) 0) + ' GB' }
  return ('model ' + $model + ' [' + $iface + $szTxt + '], ' + $guess)
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
  $f['SystemDiskShort'] = ("$($f['SystemDisk'])" -replace '\s*\[.*$', '')
  if ("$($f['SystemDisk'])" -like 'unknown*') {
    $alt = Get-Safely { Get-SystemDiskInfoWmi } $null 'disk type (WMI fallback)'
    if ($null -ne $alt) { $f['SystemDisk'] = "$($f['SystemDisk'])" + ' | second source (WMI): ' + $alt; $f['SystemDiskShort'] = "$($f['SystemDiskShort'])" + ' / ' + $alt }
  }
  $f['ProcessorName'] = Get-Safely { (($cpu.Name -replace '\s+', ' ').Trim()) } 'unknown'
  $f['PhysicalCores'] = Get-Safely {
    $n = 0
    foreach ($c in @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)) { $n += [int]$c.NumberOfCores }
    if ($n -lt 1) { throw 'no core count' }
    "$n"
  } 'unknown' 'physical cores'
  $f['PowerPlan'] = Get-Safely {
    $pp = @(Get-CimInstance -Namespace 'root/cimv2/power' -ClassName Win32_PowerPlan -Filter 'IsActive=True' -ErrorAction Stop)
    if ($pp.Count -eq 0) { throw 'no active plan from WMI' }
    ("$($pp[0].ElementName)").Trim()
  } $null
  if ($null -eq $f['PowerPlan']) {
    $f['PowerPlan'] = Get-Safely {
      $o = (@(& powercfg.exe /getactivescheme 2>$null) -join ' ')
      $mm = [regex]::Match($o, '\(([^)]+)\)\s*\*?\s*$')
      if (-not $mm.Success) { throw 'powercfg gave no plan name' }
      $mm.Groups[1].Value.Trim()
    } 'unknown' 'power plan'
  }
  $f['PowerSource'] = Get-Safely {
    $b = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop)
    if ($b.Count -eq 0) { 'no battery reported (desktop PC, or Windows does not report one)' }
    else {
      $st = [int]$b[0].BatteryStatus
      $pct = ''
      try { if ($null -ne $b[0].EstimatedChargeRemaining) { $pct = ', charge ' + $b[0].EstimatedChargeRemaining + ' %' } } catch { }
      if ($st -eq 1 -or $st -eq 4 -or $st -eq 5) { 'ON BATTERY' + $pct + ' (Windows battery status ' + $st + ')' }
      else { 'plugged in (mains power)' + $pct + ' (Windows battery status ' + $st + ')' }
    }
  } 'unknown' 'power source'

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

  $f['DefenderExclusions'] = Get-Safely {
    $mp = Get-MpPreference -ErrorAction Stop
    $xp = Get-Prop $mp 'ExclusionPath' $null
    $xe = Get-Prop $mp 'ExclusionExtension' $null
    $xr = Get-Prop $mp 'ExclusionProcess' $null
    if ((Test-NotVisible $xp) -or (Test-NotVisible $xe) -or (Test-NotVisible $xr)) { 'not visible (Windows shows the exclusions only to an administrator)' }
    else { ('{0} excluded folders or files, {1} excluded file types, {2} excluded programs (only the numbers are written, never the list)' -f (Get-ItemCount $xp), (Get-ItemCount $xe), (Get-ItemCount $xr)) }
  } 'unknown (Windows did not answer)' 'Defender exclusions'
  $f['DefenderExclusionsShort'] = ("$($f['DefenderExclusions'])" -replace ' \(only the numbers.*$', '' -replace ' excluded ', ' ')

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

# ------------------------------------------------------------------ v2: app data, WhatsApp log tally, running programs, disk wait
# Everything below is read-only. Sizes come from the file system (name-less), the WhatsApp log is
# read line by line and only five facts per line are kept (time, event name, code, attempt, appStatus).

function Get-ItemCount($Value) {
  if ($null -eq $Value) { return 0 }
  $n = 0
  foreach ($x in @($Value)) { if ($null -ne $x -and "$x" -ne '') { $n++ } }
  return $n
}

function Test-NotVisible($Value) {
  foreach ($x in @($Value)) { if ($null -ne $x -and "$x" -like 'N/A*') { return $true } }
  return $false
}

# whole-number bytes with thousands separators (so no long digit run), then a short unit text
function Format-Bytes($Bytes) {
  if ($null -eq $Bytes) { return '-' }
  $b = [int64]$Bytes
  if ($b -ge 1GB) { $u = (Format-Num ($b / 1GB) 2) + ' GB' }
  elseif ($b -ge 1MB) { $u = (Format-Num ($b / 1MB) 1) + ' MB' }
  elseif ($b -ge 1KB) { $u = (Format-Num ($b / 1KB) 1) + ' KB' }
  else { return ($b.ToString('N0', $Inv) + ' bytes') }
  return ($b.ToString('N0', $Inv) + ' bytes (' + $u + ')')
}

function Format-Age([double]$Minutes) {
  if ($Minutes -lt 120) { return ((Format-Num $Minutes 0) + ' min') }
  if ($Minutes -lt 2880) { return ((Format-Num ($Minutes / 60) 1) + ' hours') }
  return ((Format-Num ($Minutes / 1440) 1) + ' days')
}

# Text that came out of a file: remove addresses and long digit runs, keep only safe characters, cut to 64.
function Protect-LogText([string]$Text, [int]$Max = 64) {
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  $t = $Text
  if ($t.Length -gt 256) { $t = $t.Substring(0, 256) }
  $t = [regex]::Replace($t, '[^\s"''<>]+@[A-Za-z0-9.-]+', 'jid-removed')
  $t = [regex]::Replace($t, '\+?\d[\d\s-]{5,}\d', 'digits-removed')
  $t = [regex]::Replace($t, '\d{8,}', 'digits-removed')
  $t = [regex]::Replace($t, '[^A-Za-z0-9_.:-]', '?')
  if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) }
  return $t
}

function Add-Count($Table, [string]$Key) {
  if ($Table.ContainsKey($Key)) { $Table[$Key] = [int]$Table[$Key] + 1 } else { $Table[$Key] = 1 }
}

function Get-FolderSizeInfo([string]$Path, [double]$MaxSeconds = 40) {
  $r = @{ Exists = $false; Bytes = [int64]0; Files = 0; Partial = $false }
  if (-not [IO.Directory]::Exists($Path)) { return $r }
  $r.Exists = $true
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $stack = New-Object System.Collections.Generic.Stack[string]
  $stack.Push($Path)
  while ($stack.Count -gt 0) {
    if ($sw.Elapsed.TotalSeconds -gt $MaxSeconds -or $r.Files -gt 400000) { $r.Partial = $true; break }
    $dir = $stack.Pop()
    try {
      $di = New-Object IO.DirectoryInfo($dir)
      foreach ($fi in $di.EnumerateFiles()) { $r.Bytes += $fi.Length; $r.Files++ }
      foreach ($sub in $di.EnumerateDirectories()) {
        if (($sub.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $stack.Push($sub.FullName)
      }
    } catch { }
  }
  return $r
}

function Get-SpoolFacts([string]$Root) {
  $s = @{ Found = $false; Pending = 0; Quarantine = 0; Temp = 0; Other = 0; Bytes = [int64]0; OldestMin = $null; NewestMin = $null }
  $dir = Join-Path $Root 'whatsapp-inbound-spool'
  if (-not [IO.Directory]::Exists($dir)) { return $s }
  $s.Found = $true
  $oldest = $null
  $newest = $null
  $di = New-Object IO.DirectoryInfo($dir)
  foreach ($fi in $di.EnumerateFiles()) {
    $s.Bytes += $fi.Length
    if ($fi.Name -match '^[0-9a-f]{64}\.json$') {
      $s.Pending++
      $t = $fi.LastWriteTimeUtc
      if ($null -eq $oldest -or $t -lt $oldest) { $oldest = $t }
      if ($null -eq $newest -or $t -gt $newest) { $newest = $t }
    } elseif ($fi.Name -like '*.tmp') { $s.Temp++ } else { $s.Other++ }
  }
  $q = Join-Path $dir 'quarantine'
  if ([IO.Directory]::Exists($q)) {
    foreach ($fi in (New-Object IO.DirectoryInfo($q)).EnumerateFiles()) { $s.Quarantine++; $s.Bytes += $fi.Length }
  }
  $now = [DateTime]::UtcNow
  if ($null -ne $oldest) { $s.OldestMin = [math]::Max(0, ($now - $oldest).TotalMinutes) }
  if ($null -ne $newest) { $s.NewestMin = [math]::Max(0, ($now - $newest).TotalMinutes) }
  return $s
}

# Known folder names of the app (from the product source); any other folder is only counted, never named.
$script:KnownDataFolders = @('shops', 'system', 'logs', 'whatsapp-inbound-spool', 'whatsapp-media', 'migration-snapshots',
  'migration-journal', 'recovery-journal', 'recovery-staging', 'recovery-rescue', 'shop-archives', 'shop-lifecycle-inbox',
  'shop-lifecycle-journal', 'installation-root-recovery', 'recovery-kit-receipts', 'EBWebView', 'node-compile-cache')

# Total size of one data folder plus one level of sub-folders (each file is visited once):
# known folder names are listed with their size, unknown ones are only added up.
function Get-FolderBreakdown([string]$Root, [double]$MaxSeconds) {
  $b = @{ Total = @{ Exists = $true; Bytes = [int64]0; Files = 0; Partial = $false }; Parts = @(); OtherFolders = 0; OtherBytes = [int64]0 }
  $parts = @()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $di = New-Object IO.DirectoryInfo($Root)
    foreach ($fi in $di.EnumerateFiles()) { $b.Total.Bytes += $fi.Length; $b.Total.Files++ }
    foreach ($d in $di.EnumerateDirectories()) {
      if (($d.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
      $left = [math]::Max(2.0, $MaxSeconds - $sw.Elapsed.TotalSeconds)
      $sz = Get-FolderSizeInfo $d.FullName $left
      $b.Total.Bytes += $sz.Bytes; $b.Total.Files += $sz.Files
      if ($sz.Partial) { $b.Total.Partial = $true }
      if ($script:KnownDataFolders -contains $d.Name) { $parts += , @{ Name = $d.Name; Bytes = $sz.Bytes; Files = $sz.Files; Partial = $sz.Partial } }
      else { $b.OtherFolders++; $b.OtherBytes += $sz.Bytes }
    }
  } catch { Add-Problem 'list data folders' $_ }
  $b.Parts = $parts
  return $b
}

function Get-AppDataFacts([string[]]$Folders) {
  $a = @{ Found = $false; Root = ''; Others = @(); Total = $null; Parts = @(); OtherFolders = 0; OtherBytes = [int64]0
          Dbs = @(); StrayDb = 0; ShopsOtherFiles = 0; Spool = $null; Logs = $null; WaLog = $null; WaLog1 = $null }
  $existing = @($Folders | Where-Object { $_ -and [IO.Directory]::Exists($_) })
  if ($existing.Count -eq 0) { return $a }
  $root = $null
  foreach ($c in $existing) { if (-not $root -and [IO.Directory]::Exists((Join-Path $c 'shops'))) { $root = $c } }
  foreach ($c in $existing) { if (-not $root -and [IO.Directory]::Exists((Join-Path $c 'logs'))) { $root = $c } }
  foreach ($c in $existing) { if (-not $root -and [IO.File]::Exists((Join-Path $c 'startup-trace.json'))) { $root = $c } }
  if (-not $root) { $root = $existing[0] }
  $a.Found = $true
  $a.Root = $root
  $main = Get-FolderBreakdown $root 40
  $a.Total = $main.Total
  $a.Parts = $main.Parts
  $a.OtherFolders = $main.OtherFolders
  $a.OtherBytes = $main.OtherBytes
  $a.Others = @()
  foreach ($o in @($existing | Where-Object { $_ -ne $root })) {
    $bd = Get-FolderBreakdown $o 25
    $a.Others += , @{ Path = $o; Total = $bd.Total; Parts = $bd.Parts; OtherFolders = $bd.OtherFolders; OtherBytes = $bd.OtherBytes }
  }

  # shop database files: sizes only, never opened, names never written
  $shops = Join-Path $root 'shops'
  if ([IO.Directory]::Exists($shops)) {
    $dbs = @()
    $di = New-Object IO.DirectoryInfo($shops)
    $files = @($di.EnumerateFiles())
    foreach ($fi in $files) {
      if ($fi.Name -like '*.db' -and -not $fi.Name.StartsWith('.')) {
        $wal = 0; $shm = 0
        foreach ($g in $files) {
          if ($g.Name -eq ($fi.Name + '-wal')) { $wal = $g.Length }
          if ($g.Name -eq ($fi.Name + '-shm')) { $shm = $g.Length }
        }
        $dbs += , @{ Db = $fi.Length; Wal = $wal; Shm = $shm }
      } elseif ($fi.Name -notlike '*.db-wal' -and $fi.Name -notlike '*.db-shm') { $a.ShopsOtherFiles++ }
    }
    $a.Dbs = $dbs
  }
  try { foreach ($fi in (New-Object IO.DirectoryInfo($root)).EnumerateFiles('*.db*')) { $a.StrayDb++ } } catch { }

  $a.Spool = Get-SpoolFacts $root
  $logs = Join-Path $root 'logs'
  if ([IO.Directory]::Exists($logs)) { $a.Logs = Get-FolderSizeInfo $logs 10 }
  return $a
}

# ---- WhatsApp diagnostics log: counts only
$script:RxAt = New-Object Text.RegularExpressions.Regex('^\{"at":"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.\d{1,6})?Z","event":"((?:[^"\\]|\\.){0,200})"')
$script:RxCode = New-Object Text.RegularExpressions.Regex('[,{]"code":"((?:[^"\\]|\\.){0,200})"')
$script:RxAttempt = New-Object Text.RegularExpressions.Regex('[,{]"attempt":(\d{1,9})[,}]')
$script:RxStatus = New-Object Text.RegularExpressions.Regex('[,{]"appStatus":(?:"((?:[^"\\]|\\.){0,200})"|(null))')
$script:RxEvent = New-Object Text.RegularExpressions.Regex('^[a-z][a-z0-9._-]{0,63}$')

function Get-Median([double[]]$Sorted) {
  $n = $Sorted.Length
  if ($n -eq 0) { return $null }
  if ($n % 2 -eq 1) { return $Sorted[[int](($n - 1) / 2)] }
  return (($Sorted[$n / 2 - 1] + $Sorted[$n / 2]) / 2.0)
}

function Get-WhatsAppTally([string[]]$Folders) {
  $w = @{ Found = $false; Where = ''; Files = @(); Lines = 0; Unreadable = 0; Oversized = 0; First = ''; Last = ''
          Events = @{}; Codes = @{}; Attempts = @{}; Status = @{}; Pairs = @{}; Note = '' }
  $dirs = @()
  foreach ($f in $Folders) { if ($f) { $dirs += (Join-Path $f 'logs') } }
  foreach ($f in $Folders) { if ($f) { $dirs += $f } }
  $fi = Find-DataFile $dirs 'whatsapp-diagnostics.log'
  $fi1 = Find-DataFile $dirs 'whatsapp-diagnostics.log.1'
  if ($null -eq $fi -and $null -eq $fi1) { return $w }
  $w.Found = $true
  $list = @()
  if ($null -ne $fi1) { $list += $fi1 }
  if ($null -ne $fi) { $list += $fi }
  $w.Where = (Hide-Private ($list[$list.Count - 1].DirectoryName))
  $seq = 0
  $sw = [Diagnostics.Stopwatch]::StartNew()
  foreach ($f in $list) {
    $info = @{ Kind = $(if ($f.Name -like '*.1') { 'rotated copy (.1)' } else { 'current file' }); Bytes = $f.Length; Lines = 0 }
    $w.Files += , $info
    if ($f.Length -gt 6291456) { $w.Note = 'a log file is unexpectedly large (over 6 MB): not read'; continue }
    $fs = $null
    try {
      $fs = New-Object IO.FileStream($f.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]'ReadWrite,Delete'))
      $sr = New-Object IO.StreamReader($fs, (New-Object Text.UTF8Encoding($false)), $true)
      while ($null -ne ($line = $sr.ReadLine())) {
        if ($sw.Elapsed.TotalSeconds -gt 90) { $w.Note = 'stopped reading after 90 seconds'; break }
        $info.Lines++
        $w.Lines++
        if ($line.Length -eq 0) { continue }
        if ($line.Length -gt 8192) { $w.Oversized++; continue }
        $m = $script:RxAt.Match($line)
        if (-not $m.Success) { $w.Unreadable++; continue }
        $seq++
        $at = $m.Groups[1].Value
        if ($w.First -eq '' -or [string]::CompareOrdinal($at, $w.First) -lt 0) { $w.First = $at }
        if ($w.Last -eq '' -or [string]::CompareOrdinal($at, $w.Last) -gt 0) { $w.Last = $at }
        $evRaw = $m.Groups[2].Value
        $ev = 'other-event'
        if ($script:RxEvent.IsMatch($evRaw)) { $ev = Protect-LogText $evRaw 64 }
        Add-Count $w.Events $ev
        $code = $null
        $cm = $script:RxCode.Match($line)
        if ($cm.Success) {
          $code = Protect-LogText $cm.Groups[1].Value 64
          if ($code -eq '') { $code = '(empty)' }
          if ($ev -eq 'inbound.delivery-failed' -or $ev -eq 'spool.flush-failed') {
            if (-not $w.Codes.ContainsKey($ev)) { $w.Codes[$ev] = @{} }
            Add-Count $w.Codes[$ev] $code
          }
          $pk = $ev + '|' + $code
          if ($w.Pairs.ContainsKey($pk)) { $w.Pairs[$pk].N++; $w.Pairs[$pk].Seq = $seq }
          else { $w.Pairs[$pk] = @{ Event = $ev; Code = $code; N = 1; Seq = $seq } }
        }
        $am = $script:RxAttempt.Match($line)
        if ($am.Success) {
          if (-not $w.Attempts.ContainsKey($ev)) { $w.Attempts[$ev] = New-Object System.Collections.Generic.List[double] }
          $w.Attempts[$ev].Add([double]$am.Groups[1].Value)
        }
        $sm = $script:RxStatus.Match($line)
        if ($sm.Success) {
          if ($sm.Groups[2].Success) { Add-Count $w.Status 'null (no answer from the app)' }
          else {
            $sv = Protect-LogText $sm.Groups[1].Value 64
            if ($sv -eq '') { $sv = '(empty)' }
            Add-Count $w.Status $sv
          }
        }
      }
    } catch { Add-Problem 'read WhatsApp log' $_ } finally { if ($null -ne $fs) { $fs.Dispose() } }
  }
  return $w
}

# ---- running programs, 10 s sample
function Get-ProcSnapshot {
  $h = @{}
  foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
    try {
      $id = [int]$p.Id
      if ($id -eq 0) { continue }
      $cpu = $null
      try { $cpu = $p.CPU } catch { }
      $path = ''
      try { $path = "$($p.Path)" } catch { }
      $ws = [int64]0
      try { $ws = [int64]$p.WorkingSet64 } catch { }
      $h[$id] = @{ Name = "$($p.ProcessName)"; Cpu = $cpu; Ws = $ws; Path = $path }
    } catch { }
  }
  return $h
}

function Get-ProcClass($Info, [int]$Id, [string]$InstallDir, $WvOwn) {
  $n = $Info.Name.ToLowerInvariant()
  if ($n -eq 'msedgewebview2') {
    if ($WvOwn.ContainsKey($Id)) { return 'msedgewebview2 (SahelFlow window)' }
    return ''
  }
  if ($n -like 'sahelflow*') { return $Info.Name }
  if ($InstallDir -and $Info.Path -and $Info.Path.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase)) { return ($Info.Name + ' (from the SahelFlow folder)') }
  return ''
}

function Test-AppRunning {
  $pn = [IO.Path]::GetFileNameWithoutExtension($script:ExeToUse)
  return (@(Get-Process -Name $pn -ErrorAction SilentlyContinue).Count -gt 0)
}

function Invoke-ProcessSample([int]$Seconds = 10, [string]$When = '') {
  $r = @{ Ran = $false; When = $When; Seconds = 0; Rows = @(); WvAllCount = 0; WvAllMb = 0; WvAllCpu = 0; Others = @(); AllCpu = 0; Logical = 0
          FreeRamGB = 'unknown'; AppRunning = $false; WvOwnKnown = $false }
  $installDir = ''
  try { $installDir = Split-Path -Parent $script:ExeToUse } catch { }
  $wvOwn = @{}
  try {
    foreach ($w in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction Stop)) {
      $cl = ''
      try { $cl = "$($w.CommandLine)" } catch { }
      if ($cl.IndexOf('com.sahelflow.desktop', [StringComparison]::OrdinalIgnoreCase) -ge 0) { $wvOwn[[int]$w.ProcessId] = $true }
    }
    $r.WvOwnKnown = $true
  } catch { }
  $r.AppRunning = Test-AppRunning
  $t0 = Get-ProcSnapshot
  $sw = [Diagnostics.Stopwatch]::StartNew()
  Start-Sleep -Milliseconds ($Seconds * 1000)
  $t1 = Get-ProcSnapshot
  $r.Seconds = $sw.Elapsed.TotalSeconds
  $r.Logical = [Environment]::ProcessorCount
  $groups = @{}
  $others = @{}
  $wvAll = @{ N = 0; Ws = [int64]0; Cpu = 0.0 }
  $all = 0.0
  foreach ($id in @($t1.Keys)) {
    $i1 = $t1[$id]
    if ($id -eq $PID) { continue }
    $d = $null
    if ($null -ne $i1.Cpu) {
      $c0 = 0.0
      if ($t0.ContainsKey($id) -and $null -ne $t0[$id].Cpu) { $c0 = [double]$t0[$id].Cpu }
      $d = [math]::Max(0.0, [double]$i1.Cpu - $c0)
      $all += $d
    }
    if ($i1.Name.ToLowerInvariant() -eq 'msedgewebview2') {
      $wvAll.N++; $wvAll.Ws += $i1.Ws
      if ($null -ne $d) { $wvAll.Cpu += $d }
    }
    $cls = Get-ProcClass $i1 $id $installDir $wvOwn
    if ($cls) {
      if (-not $groups.ContainsKey($cls)) { $groups[$cls] = @{ Label = $cls; N = 0; Ws = [int64]0; Win = 0.0; Total = 0.0 } }
      $g = $groups[$cls]
      $g.N++; $g.Ws += $i1.Ws
      if ($null -ne $d) { $g.Win += $d }
      if ($null -ne $i1.Cpu) { $g.Total += [double]$i1.Cpu }
    } elseif ($null -ne $d) {
      $nm = $i1.Name
      if (-not $others.ContainsKey($nm)) { $others[$nm] = 0.0 }
      $others[$nm] = [double]$others[$nm] + $d
    }
  }
  $r.Rows = @($groups.Values | Sort-Object @{ Expression = { $_.Ws }; Descending = $true })
  $r.Others = @($others.GetEnumerator() | Sort-Object @{ Expression = { $_.Value }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $false } | Select-Object -First 5 | ForEach-Object { @{ Name = Protect-LogText ([string]$_.Name) 40; Cpu = [double]$_.Value } })
  $r.WvAllCount = $wvAll.N
  $r.WvAllMb = $wvAll.Ws / 1MB
  $r.WvAllCpu = $wvAll.Cpu
  $r.AllCpu = $all
  $r.FreeRamGB = Get-Safely { Format-Num ([double](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB) 1 } 'unknown'
  $r.Ran = $true
  return $r
}

# ---- disk wait probe: 30 small writes, each forced through to the disk, in one file in %TEMP%
function Invoke-LatencyProbe([int]$Count = 30, [double]$MaxSeconds = 30) {
  $res = @{ Ran = $false; N = 0; Min = $null; P50 = $null; P95 = $null; Max = $null; Deleted = $false; Note = ''; Drive = '' }
  $dir = Join-Path ([IO.Path]::GetTempPath()) ('sahelflow-pc-check-probe-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
  $file = Join-Path $dir 'probe.bin'
  $res.Drive = Get-Safely { Split-Path -Qualifier $dir } 'unknown'
  $fs = $null
  try {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $buf = New-Object byte[] 4096
    (New-Object Random 5).NextBytes($buf)
    $fs = New-Object IO.FileStream($file, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    $times = New-Object System.Collections.Generic.List[double]
    $all = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $Count; $i++) {
      if ($all.Elapsed.TotalSeconds -gt $MaxSeconds) { $res.Note = 'stopped early: more than 30 seconds'; break }
      $sw = [Diagnostics.Stopwatch]::StartNew()
      $fs.Write($buf, 0, $buf.Length)
      $fs.Flush($true)
      $times.Add($sw.Elapsed.TotalMilliseconds)
    }
    $s = $times.ToArray()
    [Array]::Sort($s)
    $n = $s.Length
    if ($n -gt 0) {
      $res.N = $n
      $res.Min = $s[0]
      $res.P50 = $s[[int][math]::Floor($n * 50 / 100)]
      $res.P95 = $s[[int][math]::Floor($n * 95 / 100)]
      $res.Max = $s[$n - 1]
      $res.Ran = $true
    }
  } catch {
    Add-Problem 'disk wait probe' $_
  } finally {
    if ($null -ne $fs) { try { $fs.Dispose() } catch { } }
    try {
      if ((Split-Path -Leaf $dir) -like 'sahelflow-pc-check-probe-*' -and (Test-Path -LiteralPath $dir)) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop }
    } catch { Add-Problem 'remove probe file' $_ }
    $res.Deleted = -not (Test-Path -LiteralPath $dir)
  }
  return $res
}

# ---- report pieces for the new sections
function Add-FolderLines($Total, $Parts, [int]$OtherFolders, $OtherBytes) {
  $partial = ''
  if ($Total.Partial) { $partial = ' (counting stopped early: at least this much)' }
  Add-Line ('Size of the folder   : ' + (Format-Bytes $Total.Bytes) + ', ' + $Total.Files + ' files' + $partial)
  foreach ($p in $Parts) {
    $pp = ''
    if ($p.Partial) { $pp = ' (partial)' }
    Add-Line ('  {0,-28}: {1}, {2} files{3}' -f $p.Name, (Format-Bytes $p.Bytes), $p.Files, $pp)
  }
  if ($OtherFolders -gt 0) { Add-Line ('  {0,-28}: {1}' -f ('other folders: ' + $OtherFolders), (Format-Bytes $OtherBytes)) }
}

function Add-AppDataLines($A) {
  if ($null -eq $A -or -not $A.Found) {
    Add-Line 'No SahelFlow data folder was found (looked in the folders named in the start-up section).'
    return
  }
  Add-Line ('Data folder          : ' + (Hide-Private $A.Root))
  Add-FolderLines $A.Total $A.Parts $A.OtherFolders $A.OtherBytes
  foreach ($o in $A.Others) {
    Add-Line ('Second data folder   : ' + (Hide-Private $o.Path))
    Add-FolderLines $o.Total $o.Parts $o.OtherFolders $o.OtherBytes
  }
  $k = 0
  foreach ($d in $A.Dbs) {
    $k++
    Add-Line ('Shop database {0}      : {1}; write-ahead file (-wal) {2}; shared-memory file (-shm) {3}' -f $k, (Format-Bytes $d.Db), (Format-Bytes $d.Wal), (Format-Bytes $d.Shm))
  }
  if ($A.Dbs.Count -eq 0) { Add-Line 'Shop database        : no .db file found in the shops folder' }
  if ($A.StrayDb -gt 0) { Add-Line ('Other .db files in the data folder itself: ' + $A.StrayDb) }
  if ($null -ne $A.Logs) { Add-Line ('Log files (logs)     : ' + (Format-Bytes $A.Logs.Bytes) + ' in ' + $A.Logs.Files + ' files') }
  else { Add-Line 'Log files (logs)     : there is no logs folder' }
  $s = $A.Spool
  Add-Line ''
  Add-Line '-- WhatsApp inbound spool (messages saved on this PC that the app has not taken yet) --'
  if ($null -eq $s -or -not $s.Found) { Add-Line 'No whatsapp-inbound-spool folder found: nothing is waiting on this PC.' }
  else {
    Add-Line ('Records waiting      : ' + $s.Pending)
    if ($s.Pending -gt 0) {
      Add-Line ('Oldest file          : last written ' + (Format-Age $s.OldestMin) + ' ago; newest file last written ' + (Format-Age $s.NewestMin) + ' ago')
      Add-Line '  (the app rewrites a waiting file at every failed try, so this is the time of the last try, not the arrival time)'
    }
    Add-Line ('In quarantine        : ' + $s.Quarantine + ' files; unfinished temporary files: ' + $s.Temp + '; other files: ' + $s.Other)
    Add-Line ('Spool folder size    : ' + (Format-Bytes $s.Bytes))
    Add-Line '  (file names and contents were not read or written here)'
  }
}

function Add-WhatsAppLines($W) {
  if ($null -eq $W -or -not $W.Found) {
    Add-Line 'No whatsapp-diagnostics.log was found on this PC.'
    Add-Line 'That means the WhatsApp part has not written a log here (or SahelFlow keeps its data in another folder).'
    return
  }
  Add-Line ('Log folder           : ' + $W.Where)
  foreach ($f in $W.Files) { Add-Line ('  {0,-22}: {1}, {2} lines' -f $f.Kind, (Format-Bytes $f.Bytes), $f.Lines) }
  if ($W.Note) { Add-Line ('  note: ' + $W.Note) }
  $span = '-'
  if ($W.First -ne '') { $span = ($W.First.Replace('T', ' ') + ' to ' + $W.Last.Replace('T', ' ') + ' UTC') }
  Add-Line ('First and last entry : ' + $span)
  if ($W.Unreadable -gt 0 -or $W.Oversized -gt 0) { Add-Line ('Lines not understood  : ' + $W.Unreadable + ' (and ' + $W.Oversized + ' too long to read)') }
  Add-Line '(counts only: no message, phone number, name or other text from the log is copied here)'
  Add-Line ''
  Add-Line 'Events (how many times each event is in the log):'
  $ev = @($W.Events.GetEnumerator() | Sort-Object @{ Expression = { $_.Value }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $false })
  $shown = 0
  foreach ($e in $ev) {
    if ($shown -ge 40) { break }
    Add-Line ('  {0,-44} {1,7}' -f $e.Name, $e.Value)
    $shown++
  }
  if ($ev.Count -gt $shown) { Add-Line ('  ... and ' + ($ev.Count - $shown) + ' more events') }
  Add-Line ''
  Add-Line 'Error codes of the two failure events:'
  foreach ($en in @('inbound.delivery-failed', 'spool.flush-failed')) {
    $tot = 0
    if ($W.Events.ContainsKey($en)) { $tot = $W.Events[$en] }
    Add-Line ('  ' + $en + ': ' + $tot + ' in the log')
    if ($W.Codes.ContainsKey($en)) {
      $cs = @($W.Codes[$en].GetEnumerator() | Sort-Object @{ Expression = { $_.Value }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $false })
      $shown = 0
      foreach ($c in $cs) {
        if ($shown -ge 25) { break }
        Add-Line ('      code {0,-40} {1,7}' -f $c.Name, $c.Value)
        $shown++
      }
      if ($cs.Count -gt $shown) { Add-Line ('      ... and ' + ($cs.Count - $shown) + ' more codes') }
    }
  }
  Add-Line ''
  Add-Line 'Attempt number (minimum / median / maximum), events that carry one:'
  if (@($W.Attempts.Keys).Count -eq 0) { Add-Line '  none in the log' }
  foreach ($k in @($W.Attempts.Keys | Sort-Object)) {
    $arr = $W.Attempts[$k].ToArray()
    [Array]::Sort($arr)
    $med = Get-Median $arr
    $medTxt = $med.ToString('0.#', $Inv)
    Add-Line ('  {0,-30} n={1}: {2} / {3} / {4}' -f $k, $arr.Length, $arr[0].ToString('0', $Inv), $medTxt, $arr[$arr.Length - 1].ToString('0', $Inv))
  }
  Add-Line ''
  Add-Line 'appStatus (what the app answered), counts:'
  if (@($W.Status.Keys).Count -eq 0) { Add-Line '  none in the log' }
  foreach ($s in @($W.Status.GetEnumerator() | Sort-Object @{ Expression = { $_.Value }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $false })) {
    Add-Line ('  {0,-44} {1,7}' -f $s.Name, $s.Value)
  }
  Add-Line ''
  Add-Line 'The last 20 different (event, code) pairs, newest first, with how many times each is in the log:'
  $pairs = @($W.Pairs.Values | Sort-Object @{ Expression = { $_.Seq }; Descending = $true } | Select-Object -First 20)
  if ($pairs.Count -eq 0) { Add-Line '  no event with a code in the log' }
  foreach ($p in $pairs) { Add-Line ('  {0,-30} {1,-30} {2,7}' -f $p.Event, $p.Code, $p.N) }
}

function Add-ProcessLines($P) {
  if ($null -eq $P -or -not $P.Ran) { Add-Line 'The running-programs sample did not run (see problems below).'; return }
  Add-Line ('When                : ' + $P.When + '; window ' + (Format-Num $P.Seconds 1) + ' s on ' + $P.Logical + ' logical processors')
  if (-not $P.AppRunning) { Add-Line 'SahelFlow was NOT running at the start of the window.' }
  Add-Line ('Free memory (RAM)    : ' + $P.FreeRamGB + ' GB at the end of the window')
  Add-Line 'SahelFlow programs (memory = working set; CPU = processor seconds used inside the window; total = since the program started):'
  if ($P.Rows.Count -eq 0) { Add-Line '  none found' }
  $sumMb = 0.0; $sumCpu = 0.0
  foreach ($g in $P.Rows) {
    $mb = $g.Ws / 1MB
    $sumMb += $mb; $sumCpu += $g.Win
    Add-Line ('  {0,-40} x{1,-3} {2,8} MB   CPU {3,6} s   (total {4} s)' -f $g.Label, $g.N, (Format-Num $mb 1), (Format-Num $g.Win 2), (Format-Num $g.Total 1))
  }
  if ($P.Rows.Count -gt 1) { Add-Line ('  all SahelFlow programs together          {0,8} MB   CPU {1,6} s' -f (Format-Num $sumMb 1), (Format-Num $sumCpu 2)) }
  if (-not $P.WvOwnKnown) { Add-Line '  (Windows did not say which WebView2 processes belong to SahelFlow; see the line below)' }
  Add-Line ('All msedgewebview2 programs (any application): {0} processes, {1} MB, CPU {2} s' -f $P.WvAllCount, (Format-Num $P.WvAllMb 1), (Format-Num $P.WvAllCpu 2))
  $avail = $P.Logical * $P.Seconds
  Add-Line ('All programs together: CPU {0} s used of {1} s available in the window (only programs Windows lets us read; this script excluded)' -f (Format-Num $P.AllCpu 1), (Format-Num $avail 0))
  $o = @($P.Others | ForEach-Object { $_.Name + ' (' + (Format-Num $_.Cpu 1) + ' s)' })
  if ($o.Count -eq 0) { Add-Line 'Five busiest other programs: none used measurable CPU' }
  else { Add-Line ('Five busiest other programs (names only): ' + ($o -join ', ')) }
}

function Add-ProbeLine([string]$Label, $X) {
  if ($null -eq $X) { Add-Line ($Label + ': not run'); return }
  if (-not $X.Ran) { Add-Line ($Label + ': did not complete (see problems below)'); return }
  $note = ''
  if ($X.Note) { $note = ' (' + $X.Note + ')' }
  Add-Line ('{0}: n={1}, p50 {2} ms, p95 {3} ms, max {4} ms; probe file deleted: {5}{6}' -f $Label, $X.N, (Format-Num $X.P50 2), (Format-Num $X.P95 2), (Format-Num $X.Max 2), $(if ($X.Deleted) { 'yes' } else { 'NO' }), $note)
}

# ---- the 8-line summary at the top of the report
function Get-SummaryLines {
  $L = @()
  $f = $script:Facts
  # 1 the PC
  try {
    $bat = "$($f['PowerSource'])"
    if ($bat -like 'no battery*') { $bat = 'no battery' }
    $L += ('1) This PC        : {0}; {1} cores / {2} threads; {3} GB RAM ({4} GB free); system disk {5}; {6}; power: {7}; plan: {8}' -f $f['ProcessorName'], $f['PhysicalCores'], $f['LogicalProcessors'], $f['RamGB'], $f['RamFreeNowGB'], $f['SystemDiskShort'], $f['SystemDriveFree'], $bat, $f['PowerPlan'])
  } catch { $L += '1) This PC        : not available' }
  # 2 protection
  try {
    $L += ('2) Protection     : Windows Defender real-time {0}; exclusions: {1}; antivirus products: {2}' -f $f['DefenderRealTime'], $f['DefenderExclusionsShort'], $f['AntivirusProducts'])
  } catch { $L += '2) Protection     : not available' }
  # 3 app data
  try {
    $a = $script:AppData
    if ($null -eq $a -or -not $a.Found) { $L += '3) App data       : no SahelFlow data folder found' }
    else {
      $db = 'no shop database file found'
      if ($a.Dbs.Count -gt 0) {
        $sumDb = [int64]0; $sumWal = [int64]0
        foreach ($d in $a.Dbs) { $sumDb += $d.Db; $sumWal += $d.Wal }
        $db = ('shop database ' + (Format-Bytes $sumDb) + ', write-ahead file ' + (Format-Bytes $sumWal))
      }
      $lg = 'no logs folder'
      if ($null -ne $a.Logs) { $lg = ('logs ' + (Format-Bytes $a.Logs.Bytes)) }
      $second = ''
      foreach ($o in $a.Others) { $second += ('; second folder ' + (Format-Bytes $o.Total.Bytes)) }
      $L += ('3) App data       : data folder ' + (Format-Bytes $a.Total.Bytes) + $second + '; ' + $db + '; ' + $lg)
    }
  } catch { $L += '3) App data       : not available' }
  # 4 spool
  try {
    $a = $script:AppData
    if ($null -eq $a -or -not $a.Found -or $null -eq $a.Spool -or -not $a.Spool.Found) { $L += '4) WhatsApp queue : no inbound spool folder (nothing waiting on this PC)' }
    else {
      $s = $a.Spool
      $age = ''
      if ($s.Pending -gt 0) { $age = ', oldest file last tried ' + (Format-Age $s.OldestMin) + ' ago' }
      $L += ('4) WhatsApp queue : {0} messages saved and waiting{1}; {2} in quarantine' -f $s.Pending, $age, $s.Quarantine)
    }
  } catch { $L += '4) WhatsApp queue : not available' }
  # 5 log
  try {
    $w = $script:WaTally
    if ($null -eq $w -or -not $w.Found) { $L += '5) WhatsApp log   : no whatsapp-diagnostics.log found on this PC' }
    else {
      $fail = 0
      foreach ($en in @('inbound.delivery-failed', 'spool.flush-failed')) { if ($w.Events.ContainsKey($en)) { $fail += [int]$w.Events[$en] } }
      $top = @()
      foreach ($en in @('inbound.delivery-failed', 'spool.flush-failed')) {
        if ($w.Codes.ContainsKey($en)) {
          foreach ($c in @($w.Codes[$en].GetEnumerator() | Sort-Object @{ Expression = { $_.Value }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $false } | Select-Object -First 3)) { $top += ($c.Name + ' x' + $c.Value) }
        }
      }
      $tt = 'no failure codes'
      if ($top.Count -gt 0) { $tt = 'most frequent codes: ' + ($top -join ', ') }
      $L += ('5) WhatsApp log   : {0} lines from {1} to {2} UTC; {3} delivery or flush failures; {4}' -f $w.Lines, $w.First.Replace('T', ' '), $w.Last.Replace('T', ' '), $fail, $tt)
    }
  } catch { $L += '5) WhatsApp log   : not available' }
  # 6 load
  try {
    $p = $script:ProcSample
    if ($null -eq $p -or -not $p.Ran) { $L += '6) Load           : not measured' }
    else {
      $mb = 0.0; $cpu = 0.0
      foreach ($g in $p.Rows) { $mb += ($g.Ws / 1MB); $cpu += $g.Win }
      $oth = @($p.Others | Select-Object -First 3 | ForEach-Object { $_.Name })
      $othTxt = 'none busy'
      if ($oth.Count -gt 0) { $othTxt = ($oth -join ', ') }
      $run = ''
      if (-not $p.AppRunning) { $run = ' (SahelFlow was not running)' }
      $L += ('6) Load           : {0}: SahelFlow programs use {1} MB and {2} CPU-seconds in {3} s on {4} threads{5}; busiest others: {6}' -f $p.When, (Format-Num $mb 0), (Format-Num $cpu 1), (Format-Num $p.Seconds 0), $p.Logical, $run, $othTxt)
    }
  } catch { $L += '6) Load           : not available' }
  # 7 disk wait
  try {
    $x = $script:ProbeIdle
    $y = $script:ProbeBusy
    $t = ''
    if ($null -ne $x -and $x.Ran) { $t = ('30 forced small writes: p50 {0} ms, p95 {1} ms, max {2} ms' -f (Format-Num $x.P50 1), (Format-Num $x.P95 1), (Format-Num $x.Max 1)) }
    else { $t = 'not measured' }
    if ($null -ne $y -and $y.Ran) { $t += ('; with SahelFlow running: p50 {0} ms, p95 {1} ms, max {2} ms' -f (Format-Num $y.P50 1), (Format-Num $y.P95 1), (Format-Num $y.Max 1)) }
    $L += ('7) Disk wait      : ' + $t + ' (our datacenter test disk: p50 about 5 ms)')
  } catch { $L += '7) Disk wait      : not available' }
  # 8 start-up
  try {
    $parts = @()
    foreach ($r in $script:Recs) { $parts += ($r.Label + ': ' + $r.Verdict) }
    if ($parts.Count -eq 0) { $parts = @('no start-up record') }
    $L += ('8) Start-up       : ' + ($parts -join ' | '))
  } catch { $L += '8) Start-up       : not available' }
  return $L
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
$AppData = $null
$WaTally = $null
$ProcSample = $null
$ProbeIdle = $null
$ProbeBusy = $null
$ProbeIdleOpen = $false
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

    Tell ''
    Tell 'Step 2: size of the SahelFlow data folders and counts from the WhatsApp log (nothing is opened or copied; on a slow disk this can take a minute) ...'
    try { $AppData = Get-AppDataFacts $folders } catch { Add-Problem 'app data folders' $_ }
    try { $WaTally = Get-WhatsAppTally $folders } catch { Add-Problem 'WhatsApp log' $_ }
    Tell 'Quick disk wait test: 30 small writes forced to the disk ...'
    try { $ProbeIdleOpen = Test-AppRunning } catch { }
    try { $ProbeIdle = Invoke-LatencyProbe 30 30 } catch { Add-Problem 'disk wait probe' $_ }

    if ($Launch) {
      if (-not (Test-Path -LiteralPath $script:ExeToUse -PathType Leaf)) {
        Tell ('SahelFlow was not found at ' + $script:ExeToUse + ' - no launch test.')
        $recs = @(@{ Label = 'Launch 1'; Started = $false; Verdict = 'not started: sahelflow.exe not found'; Facts = $null; Diag = $null; Wall = $null; UptimeMin = $null; TraceFile = ''; LaunchLocal = ''; EndReason = 'no-exe' })
      } else {
        Tell ''
        Tell 'Step 3: guided launch. For the cold number the PC should have been restarted a few minutes ago.'
        $first = Invoke-GuidedLaunch 'Launch 1 (first)' $script:ExeToUse $folders
        $recs += , $first
        if ($Twice -and $first.Started) {
          $second = Invoke-GuidedLaunch 'Launch 2 (warm)' $script:ExeToUse $folders
          $recs += , $second
        }
      }
    } else {
      Tell ''
      Tell 'Step 3: reading the start-up file of the last launch (no launch; add -Launch to measure a new one) ...'
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

    # running programs for 10 seconds, taken right after the last launch while SahelFlow is still open
    $lastLaunched = $false
    if ($Launch -and $recs.Count -gt 0) { $lastLaunched = [bool]$recs[$recs.Count - 1].Started }
    $when = 'now (no launch in this run)'
    if ($lastLaunched) { $when = 'right after ' + $recs[$recs.Count - 1].Label + ' ended' }
    Tell ''
    Tell 'Step 4: watching the running programs for 10 seconds. Please do not touch the PC ...'
    try { $ProcSample = Invoke-ProcessSample 10 $when } catch { Add-Problem 'running programs sample' $_ }
    if ($null -ne $ProcSample -and $ProcSample.AppRunning) {
      Tell 'Disk wait test again, with SahelFlow open ...'
      try { $ProbeBusy = Invoke-LatencyProbe 30 30 } catch { Add-Problem 'disk wait probe (app open)' $_ }
    }

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
    Tell 'Step 5: disk speed test (about 10 to 60 seconds) ...'
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
if (-not $TraceFile) {
  Add-Line ''
  Add-Line '== SUMMARY (8 lines) =='
  foreach ($sl in (Get-SummaryLines)) { Add-Line $sl }
}
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
  Add-Line ('Cores / threads      : ' + $facts['PhysicalCores'] + ' physical cores, ' + $facts['LogicalProcessors'] + ' logical processors')
  Add-Line ('Memory (RAM)         : ' + $facts['RamGB'] + ' GB installed, ' + $facts['RamFreeNowGB'] + ' GB free when the script started')
  Add-Line ('System disk type     : ' + $facts['SystemDisk'])
  Add-Line ('System drive space   : ' + $facts['SystemDriveFree'])
  Add-Line ('Windows started at   : ' + $facts['WindowsStarted'] + ' (on for ' + $facts['PcOnForMinutes'] + ' min when the script started)')
  Add-Line ('WebView2 runtime     : ' + $facts['WebView2'])
  Add-Line ('Power plan           : ' + $facts['PowerPlan'])
  Add-Line ('Power source         : ' + $facts['PowerSource'])
  Add-Line ('Defender real-time   : ' + $facts['DefenderRealTime'])
  Add-Line ('Defender exclusions  : ' + $facts['DefenderExclusions'])
  Add-Line ('Antivirus products   : ' + $facts['AntivirusProducts'] + '  (display names only)')
  Add-Line ('SahelFlow installed  : ' + $facts['SahelFlowInstalledList'])
  Add-Line ('SahelFlow exe        : ' + $facts['SahelFlowExeVersion'])
}

if (-not $TraceFile) {
  Add-Line ''
  Add-Line '== APP DATA (sizes and counts only) =='
  Add-AppDataLines $AppData
  Add-Line ''
  Add-Line '== WHATSAPP DIAGNOSTICS LOG (counts only) =='
  Add-WhatsAppLines $WaTally
  Add-Line ''
  Add-Line '== RUNNING PROGRAMS (10 second sample) =='
  Add-ProcessLines $ProcSample
  Add-Line ''
  Add-Line '== DISK WAIT PROBE (30 small writes, each forced to the disk) =='
  $idleLabel = 'Before SahelFlow was started by this check'
  if ($ProbeIdleOpen) { $idleLabel = 'At the start (SahelFlow was ALREADY open)' }
  Add-ProbeLine $idleLabel $ProbeIdle
  if ($null -ne $ProbeBusy) { Add-ProbeLine 'With SahelFlow open (after the sample)' $ProbeBusy }
  else { Add-Line 'With SahelFlow open: not run (SahelFlow was not running after the sample)' }
  Add-Line ('Drive of the probe file: ' + $(if ($null -ne $ProbeIdle) { $ProbeIdle.Drive } else { 'unknown' }) + ' (the temporary folder); the probe file is deleted at once.')
  Add-Line 'Compare: our datacenter test disk gives p50 about 5 ms, p95 8 to 60 ms for a forced 4 KB write.'
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
