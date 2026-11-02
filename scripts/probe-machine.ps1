$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force -Path out | Out-Null
$o = [ordered]@{}
try { $os = Get-CimInstance Win32_OperatingSystem; $o.os = $os.Caption; $o.build = $os.BuildNumber; $o.version = $os.Version; $o.ramGB = [math]::Round($os.TotalVisibleMemorySize/1MB,1); $o.freeRamGB = [math]::Round($os.FreePhysicalMemory/1MB,1) } catch { $o.osError = "$_" }
try { $cpu = @(Get-CimInstance Win32_Processor); $o.cpuName = $cpu[0].Name; $o.logicalCpus = ($cpu | Measure-Object NumberOfLogicalProcessors -Sum).Sum } catch { $o.cpuError = "$_" }
try { $d = Get-PSDrive C; $o.diskFreeGB = [math]::Round($d.Free/1GB,1); $o.diskUsedGB = [math]::Round($d.Used/1GB,1) } catch {}
$o.psVersion = $PSVersionTable.PSVersion.ToString()
try { $o.node = (& node --version) } catch { $o.node = 'none' }
try { $o.webview2 = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -ErrorAction Stop).pv } catch { $o.webview2 = 'not-found' }
$o.timezone = (Get-TimeZone).Id
$o.culture = (Get-Culture).Name
$o.isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$o.sessionId = (Get-Process -Id $PID).SessionId
$o.user = $env:USERNAME
try { Add-Type -AssemblyName System.Windows.Forms; $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds; $o.screen = "$($b.Width)x$($b.Height)" } catch { $o.screen = "error: $_" }
try { $m = Get-MpComputerStatus -ErrorAction Stop; $o.defenderRealtime = $m.RealTimeProtectionEnabled } catch { $o.defenderRealtime = 'n/a' }
$o | ConvertTo-Json -Depth 4 | Set-Content out/probe.json
Write-Host "probe ok"
