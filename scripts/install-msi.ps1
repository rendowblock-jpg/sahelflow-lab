$ErrorActionPreference = 'Continue'
$msi = Get-ChildItem out/assets -Filter *.msi | Select-Object -First 1
if (-not $msi) { Write-Host "install: fail (no msi)"; exit 1 }
$t0 = Get-Date
$p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$($msi.FullName)`"", '/qn', '/norestart', '/l*v', "`"$((Resolve-Path out).Path)\msi-install.log`"") -Wait -PassThru
$sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
$dir = Join-Path $env:ProgramFiles 'SahelFlow'
$o = [ordered]@{ msi = $msi.Name; msiBytes = $msi.Length; exitCode = $p.ExitCode; seconds = $sec; installDir = $dir; exeExists = (Test-Path (Join-Path $dir 'sahelflow.exe')) }
if (Test-Path $dir) { $f = Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue; $o.files = $f.Count; $o.installedMB = [math]::Round((($f | Measure-Object Length -Sum).Sum)/1MB, 1) }
$u = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*SahelFlow*' } | Select-Object -First 1
if ($u) { $o.displayName = $u.DisplayName; $o.displayVersion = $u.DisplayVersion; $o.publisher = $u.Publisher }
$o | ConvertTo-Json | Set-Content out/install.json
if (($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) -or -not $o.exeExists) { Write-Host "install: fail (exit $($p.ExitCode))"; exit 1 }
Write-Host "install: ok ($sec s)"
