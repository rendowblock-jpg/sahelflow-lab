# usage: fsevents.ps1 -> records file-change events (FileSystemWatcher) of the SahelFlow data roots, install dir, Downloads, Documents,
# and a filtered view of TEMP, into out/fsevents.jsonl until out/sampler.stop exists. One line per event; t = unix ms.
$ErrorActionPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path out | Out-Null
$src = @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
public static class FsRec {
  static readonly ConcurrentQueue<string> Q = new ConcurrentQueue<string>();
  static readonly ConcurrentDictionary<string,int> Quiet = new ConcurrentDictionary<string,int>();
  static readonly Dictionary<string,long> Last = new Dictionary<string,long>();
  static readonly Dictionary<string,int> Dups = new Dictionary<string,int>();
  static readonly List<FileSystemWatcher> Ws = new List<FileSystemWatcher>();
  static readonly HashSet<string> Roots = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
  public static long Events, Dupes, Dropped, Written, Errors;
  public static long CapBytes = 50L * 1024 * 1024;
  static Regex Ebw = new Regex(@"\\EBWebView\\", RegexOptions.IgnoreCase);
  static Regex TempKeep = new Regex(@"sahelflow|etilqs|sqlite|backup|\.sfo|\.sfb|\.db|journal|\.wal|\.shm|\.tmp$", RegexOptions.IgnoreCase);
  static string TempDir = "";
  static volatile bool StopFlag;
  static Thread Writer;
  static string OutPath;
  static long Now() { return DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(); }
  static string J(string s) { return s == null ? "" : s.Replace("\\", "\\\\").Replace("\"", "\\\""); }
  public static void Start(string outPath, string tempDir) {
    OutPath = outPath; TempDir = tempDir ?? "";
    Writer = new Thread(WriteLoop); Writer.IsBackground = true; Writer.Start();
  }
  public static string[] RootList() { lock (Roots) { var a = new string[Roots.Count]; Roots.CopyTo(a); return a; } }
  public static bool Add(string root) {
    lock (Roots) { if (!Directory.Exists(root) || !Roots.Add(root)) return false; }
    try {
      var w = new FileSystemWatcher(root);
      w.IncludeSubdirectories = true; w.InternalBufferSize = 65536;
      w.NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.FileName | NotifyFilters.DirectoryName;
      w.Created += (s, e) => On("Created", e.FullPath, null);
      w.Changed += (s, e) => On("Changed", e.FullPath, null);
      w.Deleted += (s, e) => On("Deleted", e.FullPath, null);
      w.Renamed += (s, e) => On("Renamed", e.FullPath, e.OldFullPath);
      w.Error += (s, e) => { Interlocked.Increment(ref Errors); Q.Enqueue("{\"t\":" + Now() + ",\"err\":\"" + J(e.GetException().Message) + "\",\"root\":\"" + J(root) + "\"}"); };
      w.EnableRaisingEvents = true;
      lock (Ws) Ws.Add(w);
      Q.Enqueue("{\"t\":" + Now() + ",\"root\":\"" + J(root) + "\"}");
      return true;
    } catch (Exception ex) { Q.Enqueue("{\"t\":" + Now() + ",\"addfail\":\"" + J(root) + "\",\"msg\":\"" + J(ex.Message) + "\"}"); return false; }
  }
  static void On(string ct, string path, string old) {
    long t = Now();
    Interlocked.Increment(ref Events);
    if (path == null) return;
    if (Ebw.IsMatch(path)) { Quiet.AddOrUpdate((t / 1000) + "|ebw", 1, (k, v) => v + 1); return; }
    if (TempDir.Length > 0 && path.StartsWith(TempDir, StringComparison.OrdinalIgnoreCase) && !TempKeep.IsMatch(path)) { Quiet.AddOrUpdate((t / 1000) + "|tmp", 1, (k, v) => v + 1); return; }
    string key = ct + "|" + path; int dup = 0;
    lock (Last) {
      long lt;
      if (Last.TryGetValue(key, out lt) && t - lt < 50) { int d; Dups.TryGetValue(key, out d); Dups[key] = d + 1; Interlocked.Increment(ref Dupes); return; }
      Last[key] = t;
      if (Dups.TryGetValue(key, out dup)) Dups.Remove(key);
      if (Last.Count > 200000) Last.Clear();
    }
    long size = -1;
    if (ct == "Created" || ct == "Changed" || ct == "Renamed") { try { var fi = new FileInfo(path); if (fi.Exists) size = fi.Length; } catch { } }
    var sb = new StringBuilder(160);
    sb.Append("{\"t\":").Append(t).Append(",\"c\":\"").Append(ct).Append("\",\"p\":\"").Append(J(path)).Append("\"");
    if (size >= 0) sb.Append(",\"s\":").Append(size);
    if (old != null) sb.Append(",\"o\":\"").Append(J(old)).Append("\"");
    if (dup > 0) sb.Append(",\"dup\":").Append(dup);
    sb.Append("}");
    Q.Enqueue(sb.ToString());
  }
  static void FlushQuiet(long nowSec, StreamWriter sw) {
    foreach (var kv in Quiet) {
      int bar = kv.Key.IndexOf('|'); long sec = long.Parse(kv.Key.Substring(0, bar));
      if (sec < nowSec) { int n; if (Quiet.TryRemove(kv.Key, out n)) sw.WriteLine("{\"t\":" + (sec * 1000) + ",\"q\":\"" + kv.Key.Substring(bar + 1) + "\",\"n\":" + n + "}"); }
    }
  }
  static void WriteLoop() {
    var fs = new FileStream(OutPath, FileMode.Create, FileAccess.Write, FileShare.ReadWrite);
    var sw = new StreamWriter(fs, new UTF8Encoding(false)); long lastFlush = Now();
    while (true) {
      string line; bool any = false;
      while (Q.TryDequeue(out line)) {
        any = true;
        if (Written > CapBytes) { Interlocked.Increment(ref Dropped); continue; }
        sw.WriteLine(line); Written += line.Length + 2;
      }
      long n = Now();
      if (n - lastFlush > 250) { FlushQuiet(n / 1000, sw); sw.Flush(); lastFlush = n; }
      if (StopFlag && !any && Q.IsEmpty) break;
      if (!any) Thread.Sleep(20);
    }
    FlushQuiet(long.MaxValue, sw);
    sw.WriteLine("{\"t\":" + Now() + ",\"sum\":1,\"events\":" + Events + ",\"dupes\":" + Dupes + ",\"dropped\":" + Dropped + ",\"errors\":" + Errors + ",\"written\":" + Written + "}");
    sw.Flush(); sw.Dispose();
  }
  public static void Stop() {
    lock (Ws) { foreach (var w in Ws) { try { w.EnableRaisingEvents = false; w.Dispose(); } catch { } } }
    StopFlag = true; if (Writer != null) Writer.Join(8000);
  }
}
'@
try { Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop } catch { Set-Content out/fsrec.err ($_ | Out-String); New-Item -ItemType File -Force -Path out/fsrec.ready | Out-Null; exit 1 }
[FsRec]::Start((Join-Path (Get-Location).Path 'out/fsevents.jsonl'), $env:TEMP)
$docs = [Environment]::GetFolderPath('MyDocuments')
function Scan {
  foreach ($p in @($env:APPDATA, $env:LOCALAPPDATA, $env:ProgramData, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if ($p) { Get-ChildItem -LiteralPath $p -Directory -Force | Where-Object { $_.Name -match 'sahelflow' } | ForEach-Object { [void][FsRec]::Add($_.FullName) } }
  }
  [void][FsRec]::Add((Join-Path $env:USERPROFILE 'Downloads'))
  if ($docs) { [void][FsRec]::Add($docs) }
  [void][FsRec]::Add($env:TEMP)
}
Scan
New-Item -ItemType File -Force -Path out/fsrec.ready | Out-Null
while (-not (Test-Path out/sampler.stop)) { Scan; Start-Sleep -Milliseconds 400 }
$roots = [FsRec]::RootList()
[FsRec]::Stop()
# final listing of the data roots (not the install dir, not TEMP, not WebView2)
$lines = New-Object System.Collections.Generic.List[string]
foreach ($r in $roots) {
  if ($r -like "$env:ProgramFiles*" -or $r -like "$env:TEMP*") { continue }
  Get-ChildItem -LiteralPath $r -Recurse -File -Force | Where-Object { $_.FullName -notmatch '\\EBWebView\\' } | Select-Object -First 20000 | ForEach-Object {
    $lines.Add((@{ p = $_.FullName; s = $_.Length; m = [DateTimeOffset]::new($_.LastWriteTimeUtc).ToUnixTimeMilliseconds() } | ConvertTo-Json -Compress)) }
}
Set-Content out/fsfinal.jsonl $lines
