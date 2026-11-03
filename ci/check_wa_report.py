#!/usr/bin/env python3
"""Compare the WhatsApp section of a pc-check report with expected.json (made by gen_wa.py).
Usage: check_wa_report.py REPORT.txt expected.json   (exit 0 = all equal)"""
import json, re, sys

rep = open(sys.argv[1], encoding="utf-8-sig").read().replace("\r\n", "\n")
exp = json.load(open(sys.argv[2]))
sec = rep.split("== WHATSAPP DIAGNOSTICS LOG (counts only) ==")[1].split("\n== ")[0]
bad = 0


def check(name, got, want):
    global bad
    ok = got == want
    if not ok:
        bad += 1
    print(("OK   " if ok else "FAIL ") + name + ("" if ok else "\n   got : %r\n   want: %r" % (got, want)))


def block(title_re):
    m = re.search(title_re + r".*?\n(.*?)(?:\n\n|\Z)", sec, re.S)
    return m.group(1) if m else ""


# lines and files
lines = sum(int(x) for x in re.findall(r"bytes \([^)]*\), (\d+) lines", sec))
check("total lines", lines, exp["lines"])
m = re.search(r"Lines not understood\s*: (\d+) \(and (\d+) too long", sec)
check("unreadable/oversized", (int(m.group(1)), int(m.group(2))) if m else None, (exp["unreadable"], exp["oversized"]))
m = re.search(r"First and last entry : (\S+ \S+) to (\S+ \S+) UTC", sec)
check("first/last", (m.group(1).replace(" ", "T"), m.group(2).replace(" ", "T")) if m else None, (exp["first"], exp["last"]))
sizes = [int(x.replace(",", "")) for x in re.findall(r"([\d,]+) bytes \(", sec.split("Events (")[0])]
check("file sizes", sorted(sizes), sorted(exp["bytes"].values()))

# events
ev = {}
for n, c in re.findall(r"^  (\S+)\s+(\d+)$", block(r"Events \(how many"), re.M):
    ev[n] = int(c)
check("events", ev, exp["events"])

# codes
codes = {}
cur = None
for l in sec.split("Error codes of the two failure events:")[1].split("Attempt number")[0].splitlines():
    m = re.match(r"  (inbound\.delivery-failed|spool\.flush-failed): (\d+) in the log", l)
    if m:
        cur = m.group(1)
        codes.setdefault(cur, {})
        continue
    m = re.match(r"\s+code (\S+)\s+(\d+)$", l)
    if m and cur:
        codes[cur][m.group(1)] = int(m.group(2))
check("codes", codes, exp["codes"])

# attempts
att = {}
for n, cnt, mn, med, mx in re.findall(r"^  (\S+)\s+n=(\d+): (\d+) / ([\d.]+) / (\d+)$", sec, re.M):
    att[n] = {"n": int(cnt), "min": int(mn), "median": float(med), "max": int(mx)}
want = {k: {"n": v["n"], "min": v["min"], "median": float(v["median"]), "max": v["max"]} for k, v in exp["attempts"].items()}
check("attempts", att, want)

# appStatus
st = {}
blk = sec.split("appStatus (what the app answered), counts:")[1].split("\n\n")[0]
for l in blk.strip("\n").splitlines():
    m = re.match(r"  (.+?)\s+(\d+)$", l)
    if m:
        st[m.group(1)] = int(m.group(2))
check("appStatus", st, exp["appStatus"])

# last 20 pairs
pairs = []
blk = sec.split("with how many times each is in the log:")[1]
for l in blk.strip("\n").splitlines():
    m = re.match(r"  (\S+)\s+(\S+)\s+(\d+)$", l)
    if m:
        pairs.append([m.group(1), m.group(2), int(m.group(3))])
check("last 20 pairs", pairs, exp["last20"])

# nothing personal
for needle in ["TRAPNAME", "Amina", "213555010203", "99887766554433", "TRAPTEXT", "sucre", "@"]:
    check("no '%s' in whole report" % needle, needle in rep, False)
print("FAILURES:", bad)
sys.exit(1 if bad else 0)
