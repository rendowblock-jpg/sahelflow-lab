#!/usr/bin/env python3
"""Synthetic WhatsApp diagnostics log for testing the PC check (NO real data).

Usage: gen_wa.py OUTDIR            -> writes OUTDIR/logs/whatsapp-diagnostics.log(.1) + expected.json
       gen_wa.py OUTDIR --full     -> also plants shops/, whatsapp-inbound-spool/ (127 records + 2 quarantined)

Every line follows the real writer (sidecars/whatsapp/diagnostics-log.ts): {"at","event",...fields}.
Some lines carry TRAP values that must never appear in the report: names, a phone-like number,
a JID, message text. Expected counts are computed here with the json module (not with the
regexes of the PowerShell script) so the two are independent.
"""
import json, os, random, re, sys, time

TRAP_NAME = "TRAPNAME-Amina-Benali"
TRAP_NUM = "213555010203"
TRAP_JID = "213555010203@s.whatsapp.net"
TRAP_LID = "99887766554433@lid"
TRAP_TEXT = "bonjour je veux 3 kg de sucre TRAPTEXT"

rnd = random.Random(20261103)


def ts(day_offset_min):
    base = 1793600000  # 2026-11-02 approx (seconds)
    t = base + day_offset_min * 60
    ms = rnd.randint(0, 999)
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".%03dZ" % ms


def line(at, event, **fields):
    d = {"at": at, "event": event}
    d.update(fields)
    return json.dumps(d, separators=(",", ":"), ensure_ascii=False)


def make_lines(start_min, n):
    out = []
    t = start_min
    codes = ["TimeoutError"] * 12 + ["AbortError"] * 5 + ["UNKNOWN"] * 3 + ["ECONNREFUSED", "EBUSY", "app_503"]
    statuses = [None, None, "retry", "quarantined", "dead_letter", "applied"]
    for i in range(n):
        t += rnd.choice([0, 0, 1, 1, 2, 3])
        at = ts(t)
        r = rnd.random()
        if r < 0.22:
            out.append(line(at, "inbound.spooled", direction=rnd.choice(["in", "out"])))
        elif r < 0.50:
            out.append(line(at, "inbound.delivery-failed", code=rnd.choice(codes), attempt=rnd.randint(1, 17),
                            appStatus=rnd.choice(statuses), fields=TRAP_NAME))
        elif r < 0.58:
            out.append(line(at, "inbound.committed", attempt=rnd.randint(1, 4), replayed=rnd.random() < 0.3, ms=rnd.randint(50, 9000)))
        elif r < 0.66:
            out.append(line(at, "spool.flush-failed", stage=rnd.choice(["record", "pass"]), code=rnd.choice(["EBUSY", "EPERM", "ENOSPC", "UNKNOWN"])))
        elif r < 0.74:
            out.append(line(at, "spool.status", pending=rnd.randint(0, 130), retrying=rnd.randint(0, 100), stuck=rnd.randint(0, 20),
                            appHeld=0, oldestPendingSec=rnd.randint(0, 200000), unreadable=0, quarantined=2, quarantinedSinceStart=0, why="periodic"))
        elif r < 0.80:
            out.append(line(at, "provider.warn", message="stream errored out for " + TRAP_JID + " " + TRAP_TEXT, errorName="Error"))
        elif r < 0.85:
            out.append(line(at, "connection.update", connection=rnd.choice(["open", "close", "connecting"]), reason=TRAP_NAME))
        elif r < 0.90:
            out.append(line(at, "liveness", ok=True, ageSec=rnd.randint(1, 90)))
        elif r < 0.94:
            out.append(line(at, "send.outcome", ok=True, to=TRAP_NUM, text=TRAP_TEXT))
        elif r < 0.97:
            out.append(line(at, "inbound.upsert", jid="<jid>", pushName=TRAP_NAME, count=1))
        else:
            out.append(line(at, "session.state", state=rnd.choice(["ready", "reconnecting"]), who=TRAP_LID))
    return out, t


def trap_block(at):
    """Odd lines the real writer should never produce, but the reader must survive."""
    return [
        line(at, "inbound.delivery-failed", code=TRAP_JID, attempt=3, appStatus=None),             # code is a JID
        line(at, "inbound.delivery-failed", code=TRAP_NUM, attempt=4, appStatus="busy " + TRAP_NUM),  # digits only
        line(at, "inbound.delivery-failed", code="bad code \u00e9 " + "x" * 90, attempt=5, appStatus="applied"),  # spaces, accent, too long
        line(at, "spool.flush-failed", stage="pass", code="Z" * 100),                              # 100 chars
        line(at, "Bad_EVENT_Name", code="UNKNOWN"),                                                # invalid event name
        "this line is not json " + TRAP_TEXT,
        "",
        '{"at":"2026-11-03T01:02:03.000Z","event":"cut.off","message":"' + "y" * 9000 + '"}',    # oversized
        '{"at":"2026-11-03T01:02:03.000Z","event":"inbound.deliv',                               # cut in the middle
    ]


def policy_text(s):
    """Same policy as Protect-LogText in the script (second implementation)."""
    s = s[:256]
    s = re.sub(r"[^\s\"'<>]+@[A-Za-z0-9.-]+", "jid-removed", s)
    s = re.sub(r"\+?\d[\d\s-]{5,}\d", "digits-removed", s)
    s = re.sub(r"\d{8,}", "digits-removed", s)
    s = re.sub(r"[^A-Za-z0-9_.:-]", "?", s)
    return s[:64]


def expected(files):
    ev, codes, att, st, pairs = {}, {}, {}, {}, {}
    first = last = None
    lines = unreadable = oversized = 0
    seq = 0
    for path in files:
        with open(path, encoding="utf-8", newline="") as fh:
            for raw in fh.read().split("\n")[:-1]:
                lines += 1
                if raw == "":
                    continue
                if len(raw) > 8192:
                    oversized += 1
                    continue
                try:
                    d = json.loads(raw)
                except Exception:
                    unreadable += 1
                    continue
                if not (isinstance(d, dict) and raw.startswith('{"at":"') and "event" in d):
                    unreadable += 1
                    continue
                seq += 1
                at = d["at"][:19]
                first = at if first is None or at < first else first
                last = at if last is None or at > last else last
                e = d["event"] if re.fullmatch(r"[a-z][a-z0-9._-]{0,63}", d["event"]) else "other-event"
                ev[e] = ev.get(e, 0) + 1
                if "code" in d and isinstance(d["code"], str):
                    c = policy_text(d["code"]) or "(empty)"
                    if e in ("inbound.delivery-failed", "spool.flush-failed"):
                        codes.setdefault(e, {})
                        codes[e][c] = codes[e].get(c, 0) + 1
                    k = e + "|" + c
                    p = pairs.get(k, {"event": e, "code": c, "n": 0, "seq": 0})
                    p["n"] += 1
                    p["seq"] = seq
                    pairs[k] = p
                if "attempt" in d and isinstance(d["attempt"], int):
                    att.setdefault(e, []).append(d["attempt"])
                if "appStatus" in d:
                    v = d["appStatus"]
                    key = "null (no answer from the app)" if v is None else (policy_text(v) or "(empty)")
                    st[key] = st.get(key, 0) + 1
    att_out = {}
    for k, v in att.items():
        v = sorted(v)
        n = len(v)
        med = v[(n - 1) // 2] if n % 2 else (v[n // 2 - 1] + v[n // 2]) / 2
        att_out[k] = {"n": n, "min": v[0], "median": med, "max": v[-1]}
    last20 = sorted(pairs.values(), key=lambda p: -p["seq"])[:20]
    return {"lines": lines, "unreadable": unreadable, "oversized": oversized, "first": first, "last": last,
            "events": ev, "codes": codes, "attempts": att_out, "appStatus": st,
            "last20": [[p["event"], p["code"], p["n"]] for p in last20]}


def main():
    out = sys.argv[1]
    full = "--full" in sys.argv
    os.makedirs(os.path.join(out, "logs"), exist_ok=True)
    older, t = make_lines(0, 2600)
    newer, t = make_lines(t + 5, 3400)
    older = older + trap_block(ts(t))
    p1 = os.path.join(out, "logs", "whatsapp-diagnostics.log.1")
    p0 = os.path.join(out, "logs", "whatsapp-diagnostics.log")
    open(p1, "w", encoding="utf-8", newline="\n").write("\n".join(older) + "\n")
    open(p0, "w", encoding="utf-8", newline="\n").write("\n".join(newer) + "\n")
    exp = expected([p1, p0])  # .1 is older, read first
    exp["bytes"] = {"log": os.path.getsize(p0), "log1": os.path.getsize(p1)}
    json.dump(exp, open(os.path.join(out, "expected.json"), "w"), indent=1, sort_keys=True)
    if full:
        shops = os.path.join(out, "shops")
        os.makedirs(shops, exist_ok=True)
        rb = random.Random(1)
        open(os.path.join(shops, "shop-0001.db"), "wb").write(rb.randbytes(2 * 1024 * 1024))
        open(os.path.join(shops, "shop-0001.db-wal"), "wb").write(rb.randbytes(300 * 1024))
        open(os.path.join(shops, "shop-0001.db-shm"), "wb").write(rb.randbytes(32 * 1024))
        sp = os.path.join(out, "whatsapp-inbound-spool")
        os.makedirs(os.path.join(sp, "quarantine"), exist_ok=True)
        now = time.time()
        for i in range(127):
            name = "%064x" % (rb.getrandbits(256))
            path = os.path.join(sp, name + ".json")
            open(path, "w").write('{"fake":"spool record %d"}' % i)
            age_min = 3209 - i * 25  # oldest 3209 min, newest 3209-126*25 = 59 min
            os.utime(path, (now - age_min * 60, now - age_min * 60))
        for i in range(2):
            open(os.path.join(sp, "quarantine", "%064x.json" % rb.getrandbits(256)), "w").write("{}")
        open(os.path.join(sp, ".%064x.1234.abc.tmp" % rb.getrandbits(256)), "w").write("x")
        os.makedirs(os.path.join(out, "system"), exist_ok=True)
        open(os.path.join(out, "system", "x.bin"), "wb").write(rb.randbytes(10000))
        os.makedirs(os.path.join(out, "SecretCustomerName-Folder"), exist_ok=True)
        open(os.path.join(out, "SecretCustomerName-Folder", "y.bin"), "wb").write(rb.randbytes(5000))
    print("lines .1:", len(older), "lines .log:", len(newer))


main()
