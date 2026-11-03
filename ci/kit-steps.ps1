param([Parameter(Mandatory = $true)][string]$Step, [string]$MsiDir = 'msi')
# kit lab harness: runs sahelflow-pc-check.ps1 in a child process of the SAME PowerShell (5.1 or 7) and saves everything to kitout/.
$ErrorActionPreference = 'Continue'
$root = (Get-Location).Path
$out = Join-Path $root 'kitout'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$pcDir = Join-Path $root 'pc-check'
$script = Join-Path $pcDir 'sahelflow-pc-check.ps1'
$psExe = (Get-Process -Id $PID).Path
$tag = 'ps51'
if ($PSVersionTable.PSVersion.Major -ge 6) { $tag = 'pwsh' }
$utf8 = New-Object Text.UTF8Encoding($false)

function Save-Text([string]$Name, [string]$Text) { [IO.File]::WriteAllText((Join-Path $out $Name), $Text, $utf8) }
function Add-Summary([string]$Text) { [IO.File]::AppendAllText((Join-Path $out 'summary.txt'), ($Text + "`r`n"), $utf8) }

function Get-TempNames { return @(Get-ChildItem -LiteralPath $env:TEMP -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object) }
function Get-PcDirNames { return @(Get-ChildItem -LiteralPath $pcDir -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Substring($pcDir.Length) } | Sort-Object) }

function Copy-NewReports([string]$Name, [string[]]$Before) {
  $now = @(Get-ChildItem -LiteralPath $pcDir -Filter 'sahelflow-pc-check-*.txt' -ErrorAction SilentlyContinue)
  $k = 0
  foreach ($f in $now) {
    if ($Before -notcontains $f.Name) {
      $k++
      Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $out ($Name + '.report' + $k + '.txt'))
      Add-Summary ($Name + ' report file next to script: ' + $f.Name + ' (' + $f.Length + ' bytes)')
    }
  }
  if ($k -eq 0) { Add-Summary ($Name + ' NO report file appeared next to the script') }
}

function Invoke-Check([string]$Name, [string]$ScriptArgs, [int]$TimeoutSec = 600, [string]$Script2 = '') {
  $s = $script
  if ($Script2) { $s = $Script2 }
  $so = Join-Path $out ($Name + '.stdout.txt')
  $se = Join-Path $out ($Name + '.stderr.txt')
  $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $s + '" ' + $ScriptArgs
  $before = @(Get-ChildItem -LiteralPath $pcDir -Filter 'sahelflow-pc-check-*.txt' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $p = Start-Process -FilePath $psExe -ArgumentList $argLine -PassThru -NoNewWindow -RedirectStandardOutput $so -RedirectStandardError $se
  $h = $p.Handle
  $done = $p.WaitForExit($TimeoutSec * 1000)
  if (-not $done) { try { $p.Kill() } catch { } }
  $code = 'timeout'
  if ($done) { $code = "$($p.ExitCode)" }
  $sec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
  $ob = (Get-Item -LiteralPath $so).Length
  $eb = (Get-Item -LiteralPath $se).Length
  Add-Summary ("{0} [{1}] args: {2} | exit {3} | {4} s | stdout {5} bytes | stderr {6} bytes" -f $Name, $tag, $ScriptArgs, $code, $sec, $ob, $eb)
  Write-Host ('===== ' + $Name + ' stdout (' + $ob + ' bytes) =====')
  Get-Content -LiteralPath $so -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
  Write-Host ('===== ' + $Name + ' stderr (' + $eb + ' bytes) =====')
  Get-Content -LiteralPath $se -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
  Copy-NewReports $Name $before
}

$watch = {
  param([int]$MaxSec, [int64]$StartMs)
  $roots = @((Join-Path $env:LOCALAPPDATA 'com.sahelflow.desktop'), (Join-Path $env:APPDATA 'com.sahelflow.desktop'))
  $seen = @{}
  $closed = 0
  $log = @()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $MaxSec -and $closed -lt 2) {
    foreach ($r in $roots) {
      $p = Join-Path $r 'startup-trace.json'
      if (Test-Path -LiteralPath $p) {
        try {
          $j = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
          $ev = @($j.events)
          if ($ev.Count -gt 0 -and [int64]$ev[0].createdAtUnixMilliseconds -ge $StartMs) {
            $first = [string]$ev[0].createdAtUnixMilliseconds
            $ready = (@($ev | Where-Object { $_.stage -eq 'ui-ready' -or $_.stage -eq 'ui-blocked' }).Count -gt 0)
            if ($ready -and -not $seen.ContainsKey($first)) {
              $seen[$first] = $true
              Start-Sleep -Seconds 2
              Get-Process -Name sahelflow, sahelflow-whatsapp -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
              $closed++
              $log += ('watcher: closed the app after launch with first event ' + $first + ', watcher clock ' + [math]::Round($sw.Elapsed.TotalSeconds, 1) + ' s')
            }
          }
        } catch { }
      }
    }
    Start-Sleep -Milliseconds 500
  }
  $log += ('watcher: ended, closed ' + $closed)
  return $log
}

Write-Host ("step {0}, shell {1}, PowerShell {2}" -f $Step, $tag, $PSVersionTable.PSVersion)

if ($Step -eq 's0') {
  Save-Text ($tag + '-inventory-before-temp.txt') ((Get-TempNames) -join "`r`n")
  Save-Text ($tag + '-inventory-before-pcdir.txt') ((Get-PcDirNames) -join "`r`n")
  Add-Summary ("shell {0}; PowerShell {1}; edition {2}" -f $tag, $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
}

if ($Step -eq 's1') {
  Save-Text ($tag + '-s1-psversiontable.txt') ($PSVersionTable | Out-String)
  $e = $null; $t = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$t, [ref]$e)
  $bytes = [IO.File]::ReadAllBytes($script)
  $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count
  $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  $crlf = 0; $lf = 0
  for ($i = 0; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -eq 10) { if ($i -gt 0 -and $bytes[$i - 1] -eq 13) { $crlf++ } else { $lf++ } } }
  $msg = "parse errors: $(@($e).Count); non-ASCII bytes: $nonAscii; BOM: $bom; CRLF lines: $crlf; bare LF: $lf; size: $($bytes.Length)"
  foreach ($x in @($e)) { $msg += "`r`n  " + $x.Message + ' line ' + $x.Extent.StartLineNumber }
  Write-Host $msg
  Save-Text ($tag + '-s1-parse.txt') $msg
  Add-Summary ($tag + ' S1 ' + $msg)
}

if ($Step -eq 's2') {
  foreach ($n in 'a', 'b', 'c') {
    $tf = Join-Path $root ('testdata\' + $n + '.json')
    $od = Join-Path $out ('s2' + $n + '-reportdir')
    Invoke-Check ('s2' + $n) ('-TraceFile "' + $tf + '" -OutDir "' + $od + '" -NoPause -NoPrompt') 120
  }
}

if ($Step -eq 's3') { Invoke-Check 's3-default' '-NoPause -NoPrompt' 600 }
if ($Step -eq 's3b') { Invoke-Check 's3b-launch-notinstalled' '-Launch -Twice -NoPause -NoPrompt' 600 }
if ($Step -eq 's4') { Invoke-Check 's4-readwebview2' '-ReadWebView2 -NoPause -NoPrompt' 900 }

if ($Step -eq 's5') {
  $msi = Get-ChildItem -LiteralPath $MsiDir -Recurse -Filter *.msi -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $msi) { Add-Summary 'S5 SKIPPED: no msi downloaded'; Write-Host 'no msi'; exit 0 }
  $t0 = Get-Date
  $ip = Start-Process msiexec.exe -ArgumentList @('/i', ('"' + $msi.FullName + '"'), '/qn', '/norestart', '/l*v', ('"' + (Join-Path $env:RUNNER_TEMP 'kit-msi-install.log') + '"')) -Wait -PassThru
  Add-Summary ('S5 msi install exit ' + $ip.ExitCode + ' in ' + [math]::Round(((Get-Date) - $t0).TotalSeconds, 1) + ' s; msi ' + $msi.Name + ' ' + $msi.Length + ' bytes')
  $exe = Join-Path $env:ProgramFiles 'SahelFlow\sahelflow.exe'
  if (-not (Test-Path -LiteralPath $exe)) { Add-Summary 'S5 FAILED: exe missing after install'; exit 0 }
  $issuer = Get-ChildItem -LiteralPath $MsiDir -Recurse -Filter phase4-ci-trial-issuer.mjs -ErrorAction SilentlyContinue | Select-Object -First 1
  $issuerUp = $false
  if ($issuer) {
    Start-Process node -ArgumentList @($issuer.FullName, '--serve', '8787', '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20') -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 3
    try { $hh = Invoke-RestMethod 'http://127.0.0.1:8787/health' -TimeoutSec 3; $issuerUp = [bool]$hh.ok } catch { }
  }
  Add-Summary ('S5 trial issuer file found: ' + [bool]$issuer + '; issuer up: ' + $issuerUp)
  $startMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $job = Start-Job -ScriptBlock $watch -ArgumentList 700, $startMs
  Invoke-Check 's5-launch-twice' '-Launch -Twice -NoPause -NoPrompt' 720
  Start-Sleep -Seconds 3
  $wl = @(Receive-Job -Job $job -Wait -AutoRemoveJob -ErrorAction SilentlyContinue)
  Save-Text 's5-watcher-log.txt' ($wl -join "`r`n")
  Write-Host ($wl -join "`r`n")
  foreach ($r in @((Join-Path $env:LOCALAPPDATA 'com.sahelflow.desktop'), (Join-Path $env:APPDATA 'com.sahelflow.desktop'))) {
    $tp = Join-Path $r 'startup-trace.json'
    if (Test-Path -LiteralPath $tp) { Copy-Item -LiteralPath $tp -Destination (Join-Path $out ('s5-' + (Split-Path -Leaf $r) + '-' + (Split-Path -Leaf (Split-Path -Parent $r)) + '-startup-trace.json')) -ErrorAction SilentlyContinue }
  }
  $left = @(Get-Process -Name sahelflow, sahelflow-whatsapp -ErrorAction SilentlyContinue)
  Add-Summary ('S5 processes still running after the run: ' + $left.Count)
  $left | Stop-Process -Force -ErrorAction SilentlyContinue
}

if ($Step -eq 's6') {
  $cmdFile = Join-Path $pcDir 'run-launch-twice.cmd'
  $before = @(Get-ChildItem -LiteralPath $pcDir -Filter 'sahelflow-pc-check-*.txt' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
  $startMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $job = Start-Job -ScriptBlock $watch -ArgumentList 400, $startMs
  $so = Join-Path $out 's6-cmd.stdout.txt'
  $se = Join-Path $out 's6-cmd.stderr.txt'
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $p = Start-Process -FilePath 'cmd.exe' -ArgumentList ('/d /s /c ""' + $cmdFile + '" < NUL"') -PassThru -NoNewWindow -RedirectStandardOutput $so -RedirectStandardError $se
  $h = $p.Handle
  $done = $p.WaitForExit(420000)
  if (-not $done) { try { $p.Kill() } catch { } }
  $code = 'timeout'
  if ($done) { $code = "$($p.ExitCode)" }
  Add-Summary ('S6 run-launch-twice.cmd (stdin NUL, powershell.exe 5.1 inside) exit ' + $code + ' | ' + [math]::Round($sw.Elapsed.TotalSeconds, 1) + ' s | stdout ' + (Get-Item -LiteralPath $so).Length + ' bytes | stderr ' + (Get-Item -LiteralPath $se).Length + ' bytes')
  Write-Host '===== s6 cmd stdout ====='
  Get-Content -LiteralPath $so -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
  Write-Host '===== s6 cmd stderr ====='
  Get-Content -LiteralPath $se -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
  Copy-NewReports 's6-cmd' $before
  Start-Sleep -Seconds 3
  $wl = @(Receive-Job -Job $job -Wait -AutoRemoveJob -ErrorAction SilentlyContinue)
  Save-Text 's6-watcher-log.txt' ($wl -join "`r`n")
  Write-Host ($wl -join "`r`n")
  $left = @(Get-Process -Name sahelflow, sahelflow-whatsapp -ErrorAction SilentlyContinue)
  Add-Summary ('S6 processes still running after the run: ' + $left.Count)
  $left | Stop-Process -Force -ErrorAction SilentlyContinue
}

if ($Step -eq 's9') {
  $tb = @(); $pb = @()
  $f1 = Join-Path $out ($tag + '-inventory-before-temp.txt'); if (Test-Path -LiteralPath $f1) { $tb = @(Get-Content -LiteralPath $f1) }
  $f2 = Join-Path $out ($tag + '-inventory-before-pcdir.txt'); if (Test-Path -LiteralPath $f2) { $pb = @(Get-Content -LiteralPath $f2) }
  $ta = Get-TempNames
  $pa = Get-PcDirNames
  $newT = @($ta | Where-Object { $tb -notcontains $_ })
  $newP = @($pa | Where-Object { $pb -notcontains $_ })
  $tmpDirs = @(Get-ChildItem -LiteralPath $env:TEMP -Force -Filter 'sahelflow-pc-check-*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
  $msg = "new names in the temp folder since the start: $($newT.Count)`r`n" + ($newT -join "`r`n") + "`r`nleftover sahelflow-pc-check-* in temp: $($tmpDirs.Count) $($tmpDirs -join ',')`r`nnew files next to the script (pc-check folder):`r`n" + ($newP -join "`r`n")
  Save-Text ($tag + '-s9-inventory-after.txt') $msg
  Write-Host $msg
  Add-Summary ("S9 [{0}] temp leftover dirs: {1}; new names in temp: {2}; new files in pc-check: {3}" -f $tag, $tmpDirs.Count, $newT.Count, $newP.Count)
  $needles = @($env:USERNAME, $env:USERPROFILE, 'runneradmin', 'C:\Users', 'ghp_', 'github_pat', 'ghs_')
  $hits = @()
  foreach ($f in @(Get-ChildItem -LiteralPath $out -Recurse -File | Where-Object { $_.Name -match 'stdout|stderr|report' })) {
    $txt = [IO.File]::ReadAllText($f.FullName)
    foreach ($n in $needles) {
      if ($n -and $n.Length -ge 4 -and $txt.IndexOf($n, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hits += ($f.Name + ' contains a private-looking text (length ' + $n.Length + ', first chars ' + $n.Substring(0, 3) + ')') }
    }
  }
  Save-Text ($tag + '-s9-privacy.txt') ("hits: $($hits.Count)`r`n" + ($hits -join "`r`n"))
  Add-Summary ("S9 [{0}] privacy scan hits in stdout/stderr/report files: {1}" -f $tag, $hits.Count)
  Write-Host ("privacy scan hits: " + $hits.Count)
}
