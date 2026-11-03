# usage: inflate.py MB  -> inflates the largest shops/*.db of the app by MB megabytes (table zz_filler, ~1 KB random rows, 20 MB batches).
# Prints ONE json line at the end. MB 0 = only report file sizes. Busy timeout 30 s, commit per batch (journal_mode=delete: no checkpoint needed).
import glob, json, os, sqlite3, sys, time
mb = int(sys.argv[1]) if len(sys.argv) > 1 else 0
roots = [os.path.join(os.environ.get("LOCALAPPDATA", ""), "com.sahelflow.desktop"), os.path.join(os.environ.get("APPDATA", ""), "com.sahelflow.desktop")]
cands = []
for r in roots:
    for f in glob.glob(os.path.join(r, "shops", "*.db")):
        cands.append((os.path.getsize(f), f))
res = {"python": sys.version.split()[0], "candidates": [{"file": f, "bytes": b} for b, f in sorted(cands)], "mb": mb}
if not cands:
    res["error"] = "no shops/*.db found"; print(json.dumps(res)); sys.exit(0)
f = max(cands)[1]
res["file"] = f
res["before"] = os.path.getsize(f)
t0 = time.time()
batches = []
if mb > 0:
    try:
        c = sqlite3.connect(f, timeout=30, isolation_level=None)
        c.execute("PRAGMA busy_timeout=30000")
        res["journal_mode"] = c.execute("PRAGMA journal_mode").fetchone()[0]
        res["page_size"] = c.execute("PRAGMA page_size").fetchone()[0]
        c.execute("CREATE TABLE IF NOT EXISTS zz_filler(id INTEGER PRIMARY KEY, a TEXT, b BLOB)")
        target = res["before"] + mb * 1048576
        n = 0
        while os.path.getsize(f) < target:
            tb = time.time()
            c.execute("BEGIN IMMEDIATE")
            c.executemany("INSERT INTO zz_filler(a, b) VALUES (?, ?)", ((os.urandom(24).hex(), os.urandom(1000)) for _ in range(20000)))
            c.execute("COMMIT")
            n += 20000
            batches.append(round(time.time() - tb, 2))
            if time.time() - t0 > 780:
                res["error"] = "stopped: 780 s limit"; break
        res["rows"] = n
        res["filler_rows_total"] = c.execute("SELECT count(*) FROM zz_filler").fetchone()[0]
        c.close()
    except Exception as e:
        res["error"] = repr(e)[:300]
res["after"] = os.path.getsize(f)
res["seconds"] = round(time.time() - t0, 1)
res["batch_s_first_last_max"] = [batches[0], batches[-1], max(batches)] if batches else []
res["batches"] = len(batches)
print(json.dumps(res))
