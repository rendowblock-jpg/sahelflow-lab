# Launches the installed app, samples processes, tries the WebView2 debug port, closes it and checks for leftovers.
# Public log: only ok/fail lines. All detail goes to out/*.json (encrypted later).
param([int]$Port = 9222, [int]$MaxSeconds = 240, [int]$SettleSeconds = 60)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path out/shots | Out-Null
$exe = Join-Path $env:ProgramFiles 'SahelFlow\sahelflow.exe'
if (-not (Test-Path $exe)) { Write-Host "launch: fail (no exe)"; exit 1 }
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
function Sample($t0) {
  $el = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
  $procs = @(Get-Process -Name sahelflow, node, sahelflow-whatsapp, msedgewebview2 -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -ne 'node' -or ($_.Path -like '*SahelFlow*') } | ForEach-Object {
    [ordered]@{ n = $_.ProcessName; id = $_.Id; wsMB = [math]::Round($_.WorkingSet64/1MB, 1); privMB = [math]::Round($_.PrivateMemorySize64/1MB, 1); handles = $_.HandleCount; threads = $_.Threads.Count; cpuS = [math]::Round([double]$_.CPU, 2) } })
  Add-Content out/procs.jsonl ((@{ t = $el; procs = $procs } | ConvertTo-Json -Depth 4 -Compress))
  return $el
}
$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=$Port --remote-allow-origins=*"
$t0 = Get-Date
$p = Start-Process -FilePath $exe -PassThru
$tl = [ordered]@{ startedUtc = $t0.ToUniversalTime().ToString('o'); pid = $p.Id }
$cdp = $false; $pageSeen = $false
while (((Get-Date) - $t0).TotalSeconds -lt $MaxSeconds) {
  $el = Sample $t0
  if (-not $tl.Contains('windowAt')) { $m = Get-Process -Name sahelflow -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1; if ($m) { $tl.windowAt = $el; $tl.windowTitle = $m.MainWindowTitle } }
  if (-not $cdp) { try { $v = Invoke-RestMethod "http://127.0.0.1:$Port/json/version" -TimeoutSec 2; $cdp = $true; $tl.cdpAt = $el; $tl.cdpBrowser = $v.Browser } catch {} }
  if ($cdp -and -not $pageSeen) { try { $l = Invoke-RestMethod "http://127.0.0.1:$Port/json/list" -TimeoutSec 2; $pg = $l | Where-Object { $_.type -eq 'page' -and $_.url -like 'http://127.0.0.1:*' } | Select-Object -First 1; if ($pg) { $pageSeen = $true; $tl.pageAt = $el; $tl.pageUrl = ($pg.url -replace '\?.*', ''); $tl.pageTitle = $pg.title } } catch {} }
  if ($pageSeen) { break }
  if ($p.HasExited -and -not (Get-Process -Name sahelflow -ErrorAction SilentlyContinue)) { $tl.exitedEarlyAt = $el; break }
  Start-Sleep -Seconds 1
}
$tl.cdpUp = $cdp; $tl.pageSeen = $pageSeen
# settle: keep sampling memory every 2 s
$s0 = Get-Date
while (((Get-Date) - $s0).TotalSeconds -lt $SettleSeconds) { [void](Sample $t0); Start-Sleep -Seconds 2 }
$tl.screenOs = Save-Screen 'out/shots/os-desktop.png'
if ($cdp) { & node scripts/cdp-probe.mjs $Port 2>&1 | Out-Null } else { '{"ok":false,"error":"cdp-not-up"}' | Set-Content out/cdp.json }
[void](Sample $t0)
# app data: names/sizes of everything, content only of an allow-list (never databases, keys, whatsapp auth)
$tree = New-Object System.Collections.Generic.List[string]
foreach ($root in @((Join-Path $env:LOCALAPPDATA 'com.sahelflow.desktop'), (Join-Path $env:APPDATA 'com.sahelflow.desktop'))) {
  if (Test-Path $root) {
    Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
      $rel = $_.FullName.Substring($root.Length); $tree.Add("$($_.Length)`t$rel")
      if ($_.Name -match '^(startup-trace|runtime-ui-diagnostic).*\.json$|\.log$' -and $_.Length -lt 2MB -and $rel -notmatch 'whatsapp|auth|secret|key') {
        $dest = Join-Path 'out/appdata' ($rel.TrimStart('\') -replace '[\\/:]', '_'); New-Item -ItemType Directory -Force -Path out/appdata | Out-Null; Copy-Item $_.FullName $dest -ErrorAction SilentlyContinue
      }
    }
  }
}
$tree | Set-Content out/appdata-tree.txt
try { Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $t0 } -ErrorAction Stop | Where-Object { $_.LevelDisplayName -in 'Error', 'Warning' } | Select-Object -First 60 TimeCreated, ProviderName, Id, LevelDisplayName, @{n = 'Msg'; e = { ($_.Message -replace '\s+', ' ').Substring(0, [math]::Min(400, $_.Message.Length)) } } | ConvertTo-Json | Set-Content out/eventlog.json } catch { "none: $_" | Set-Content out/eventlog.json }
# close like a user would, then look for leftovers (child containment)
$tl.closeRequested = (Get-Process -Name sahelflow -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() }) -contains $true
Start-Sleep -Seconds 20
$left = @(Get-Process -Name sahelflow, sahelflow-whatsapp, msedgewebview2 -ErrorAction SilentlyContinue) + @(Get-Process -Name node -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*SahelFlow*' })
$tl.leftoverAfterClose = @($left | ForEach-Object { $_.ProcessName })
$tl | ConvertTo-Json -Depth 4 | Set-Content out/timeline.json
Get-Process -Name sahelflow, sahelflow-whatsapp -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
if ($pageSeen) { Write-Host "launch: ok (page at $($tl.pageAt) s)" } elseif ($tl.Contains('windowAt')) { Write-Host "launch: partial (window at $($tl.windowAt) s, no page via debug port)" } else { Write-Host "launch: fail (no window)"; exit 1 }
