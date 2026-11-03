# usage: sampler.ps1  -> writes out/procs.jsonl once per second until out/sampler.stop exists.
# Per sample: unix ms, for each SahelFlow node.exe / sahelflow.exe / sahelflow-whatsapp.exe: cpu seconds, working set, handles,
# and for node.exe the CPU milliseconds of EVERY thread (which thread burns CPU during a freeze: main thread, thread pool, GC helpers).
$ErrorActionPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path out | Out-Null
while (-not (Test-Path out/sampler.stop)) {
  $t = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $ps = @(Get-Process -Name node, sahelflow, sahelflow-whatsapp -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -ne 'node' -or ($_.Path -like '*SahelFlow*') })
  $procs = @($ps | ForEach-Object {
    $o = [ordered]@{ n = $_.ProcessName; id = $_.Id; cpuS = [math]::Round([double]$_.CPU, 2); wsMB = [math]::Round($_.WorkingSet64 / 1MB, 1); handles = $_.HandleCount }
    if ($_.ProcessName -eq 'node') { $o.thr = @($_.Threads | ForEach-Object { "$($_.Id):$([int]$_.TotalProcessorTime.TotalMilliseconds)" }) }
    $o })
  $io = [ordered]@{}
  try {
    $ids = @($ps | ForEach-Object { $_.Id })
    if ($ids.Count -gt 0) {
      Get-CimInstance Win32_Process -Filter ("ProcessId=" + ($ids -join " OR ProcessId=")) -ErrorAction Stop | ForEach-Object {
        $io["$($_.Name):$($_.ProcessId)"] = @([int64]$_.ReadOperationCount, [int64]$_.WriteOperationCount, [int64]$_.ReadTransferCount, [int64]$_.WriteTransferCount) }
    }
  } catch {}
  Add-Content out/procs.jsonl ((@{ t = $t; procs = $procs; io = $io } | ConvertTo-Json -Depth 5 -Compress))
  Start-Sleep -Milliseconds 700
}
