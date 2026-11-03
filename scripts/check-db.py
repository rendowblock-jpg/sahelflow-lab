# usage: check-db.py LABEL   -> prints JSON: integrity, journal mode, schema hash, migration-table rows for every shop DB and the template.
import glob, hashlib, json, os, sqlite3, sys
label = sys.argv[1] if len(sys.argv) > 1 else "?"
roots = [os.path.join(os.environ.get("LOCALAPPDATA", ""), "com.sahelflow.desktop"), os.path.join(os.environ.get("APPDATA", ""), "com.sahelflow.desktop")]
out = {"label": label, "dbs": []}
for root in roots:
    for pat in ("shops/*.db", "system/shop-template.db"):
        for f in sorted(glob.glob(os.path.join(root, pat))):
            rec = {"file": f[len(root):], "bytes": os.path.getsize(f)}
            try:
                c = sqlite3.connect(f, timeout=5)
                rec["integrity"] = c.execute("PRAGMA integrity_check").fetchone()[0]
                rec["journal_mode"] = c.execute("PRAGMA journal_mode").fetchone()[0]
                rows = c.execute("select type,name,sql from sqlite_master where name not like 'sqlite_%' order by type,name").fetchall()
                rec["objects"] = len(rows)
                rec["schema_sha256"] = hashlib.sha256(json.dumps(rows).encode()).hexdigest()[:16]
                rec["migration_tables"] = {}
                for (name,) in c.execute("select name from sqlite_master where type='table' and lower(name) like '%migration%'").fetchall():
                    rec["migration_tables"][name] = c.execute('select count(*) from "%s"' % name).fetchone()[0]
                c.close()
            except Exception as e:
                rec["error"] = str(e)
            out["dbs"].append(rec)
print(json.dumps(out, indent=1))
