#!/usr/bin/env python3
"""Write current grok.com Build/Chat % and append a history line on change."""
import json
import struct
import sys
from pathlib import Path

OUT = Path(
    "/home/shanta/.comserv/worktrees/aisystem/Comserv/Comserv/root/static/ai/grokcom_usage.json"
)
HIST = Path(
    "/home/shanta/.comserv/worktrees/aisystem/Comserv/Comserv/root/static/ai/grokcom_usage_history.jsonl"
)
MAX_HIST = 500
# Oct 13 2026: Grok Bot % from the same Usage page -> consumer grok_bot readings (source auto).
READINGS = Path(
    "/home/shanta/.comserv/worktrees/aisystem/Comserv/Comserv/data/ai_usage_readings.jsonl"
)
BOT_HEARTBEAT_S = 3600  # same value re-recorded at most hourly
# Oct 15 2026: Super Grok % flipped 93 <-> 100 every few seconds. A jump of more
# than JUMP points is held until it is read twice with no revert in REVERT_S.
# While flapping (2+ reverts in REVERT_S) the lower value wins.
PENDING = OUT.parent / "grokcom_usage_pending.json"
JUMP = 5
REVERT_S = 60


def stabilize(new, cur, now, st):
    """Return (value_to_keep, new_state). Pure; st is a dict."""
    st = dict(st or {})
    reverts = [t for t in st.get("reverts", []) if now - t < REVERT_S]
    if not isinstance(new, (int, float)):
        return cur, st
    if not isinstance(cur, (int, float)):
        return new, {}
    if abs(new - cur) <= JUMP:
        if st.get("value") is not None:
            reverts.append(now)          # a pending jump reverted
        return new, {"reverts": reverts}
    if len(reverts) >= 2 and new < cur:
        return new, {}                   # flapping: keep the lower reading
    if st.get("value") == new:
        if not reverts:                  # 2nd matching read, no revert in 60s
            return new, {}
        return cur, {"value": new, "since": st.get("since", now), "reverts": reverts}
    return cur, {"value": new, "since": now, "reverts": reverts}


# Oct 18 2026 (Shanta): Saturday had ~4,450 grok_bot writes bouncing 57/58/60
# (several grok.com tabs). Write only when the value changes from the last one
# written, and never write a lower value within DROP_S of a higher one.
DROP_S = 600


def should_write(new, written, now, seen=None):
    """written: [(at, value), ...] oldest->newest; seen: values posted (written
    or not) as [(at, value)]. Pure. A lower value is skipped while any higher one
    was seen in the last DROP_S (stale second tab); real drops (weekly reset)
    show on every tab, so they get through after DROP_S."""
    if not isinstance(new, (int, float)):
        return False
    pool = list(written or []) + list(seen or [])
    if any(now - t < DROP_S and float(v) > float(new) for (t, v) in pool):
        return False
    if written and float(written[-1][1]) == float(new):
        return False
    return True


SEEN = READINGS.parent / "grokcom_bot_seen.json"


def _seen_update(path, new, now):
    """Return seen list (last DROP_S) before adding new; persist with new added."""
    try:
        seen = json.loads(path.read_text(encoding="utf-8")) if path.exists() else []
    except Exception:
        seen = []
    seen = [(int(t), v) for (t, v) in seen if now - int(t) < DROP_S]
    try:
        path.write_text(json.dumps(seen + [(int(now), new)]) + "\n", encoding="utf-8")
    except Exception:
        pass
    return seen


def _pt(ep):
    from datetime import datetime
    from zoneinfo import ZoneInfo
    return datetime.fromtimestamp(ep, ZoneInfo("America/Vancouver")).strftime("%a %b %d %H:%M PT")


def _parse_reset(txt, now):
    """'Oct 19, 7:52 AM' / 'Oct 19' / 'in 6 days' / ISO -> epoch, else None."""
    import re
    from datetime import datetime
    from zoneinfo import ZoneInfo
    if not txt:
        return None
    tz = ZoneInfo("America/Vancouver")
    t = str(txt).strip()
    m = re.search(r"in\s+(\d+)\s*(day|d|hour|hr|h)", t, re.I)
    if m:
        n = int(m.group(1))
        return int(now + n * (86400 if m.group(2).lower().startswith("d") else 3600))
    try:
        return int(datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp())
    except Exception:
        pass
    now_dt = datetime.fromtimestamp(now, tz)
    for fmt in ("%b %d, %I:%M %p", "%b %d %I:%M %p", "%B %d, %I:%M %p", "%B %d %I:%M %p", "%b %d", "%B %d", "%b %d, %Y", "%B %d, %Y"):
        try:
            d = datetime.strptime(re.sub(r"\s+", " ", t.replace(".", "")), fmt)
        except ValueError:
            continue
        if "%Y" not in fmt:
            d = d.replace(year=now_dt.year)
        d = d.replace(tzinfo=tz)
        if d.timestamp() < now - 86400:
            d = d.replace(year=d.year + 1)
        return int(d.timestamp())
    return None


def record_bot(msg):
    """Append a grok_bot reading when the Bot % changes (or hourly). Never raises."""
    import time
    try:
        bot = msg.get("bot")
        if not isinstance(bot, (int, float)) or not (0 <= bot <= 100):
            return None
        now = int(time.time())
        last = None
        written = []
        import fcntl
        lockf = open(str(READINGS) + ".lock", "a")
        fcntl.flock(lockf, fcntl.LOCK_EX)
        if READINGS.exists():
            for line in READINGS.read_text(encoding="utf-8").splitlines():
                if '"grok_bot"' in line:
                    try:
                        r = json.loads(line)
                    except Exception:
                        continue
                    if r.get("consumer") == "grok_bot" and r.get("kind") != "unconfirmed":
                        if last is None or r.get("at", 0) >= last.get("at", 0):
                            last = r
                        if r.get("source") == "auto":
                            written.append((int(r.get("at", 0)), r.get("value")))
        reset = _parse_reset(msg.get("bot_reset"), now)
        if reset is None and last and last.get("reset_at"):
            reset = int(last["reset_at"])
            while reset <= now:
                reset += 7 * 86400
        written.sort()
        seen = _seen_update(SEEN, bot, now)
        if not should_write(bot, written, now, seen):
            return None
        rd = {"consumer": "grok_bot", "value": bot, "unit": "%", "kind": "used",
              "at": now, "at_pt": _pt(now), "source": "auto",
              "entered_by": "grok.com usage add-on (native_host.py)", "entered_at": now,
              "note": "auto from grok.com Usage page" + (f" (reset text: {msg.get('bot_reset')})" if msg.get("bot_reset") else "")}
        if reset:
            rd["reset_at"] = reset
            rd["reset_pt"] = _pt(reset)
        with READINGS.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(rd, separators=(",", ":")) + "\n")
        return rd
    except Exception:
        return None


def read_msg():
    raw = sys.stdin.buffer.read(4)
    if not raw or len(raw) < 4:
        return None
    (n,) = struct.unpack("<I", raw)
    body = sys.stdin.buffer.read(n)
    return json.loads(body.decode("utf-8"))


def write_msg(obj):
    data = json.dumps(obj).encode("utf-8")
    sys.stdout.buffer.write(struct.pack("<I", len(data)))
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def main():
    msg = read_msg()
    if not isinstance(msg, dict):
        write_msg({"ok": False, "error": "no_message"})
        return
    build = msg.get("build")
    chat = msg.get("chat")
    bot_rd = record_bot(msg)
    has_bot = isinstance(msg.get("bot"), (int, float))
    if not isinstance(build, (int, float)) and not isinstance(chat, (int, float)) and not has_bot:
        write_msg({"ok": False, "error": "no_percent"})
        return
    # Oct 14 2026: keep the last known value for any meter missing from this post.
    try:
        _old = json.loads(OUT.read_text(encoding="utf-8")) if OUT.exists() else {}
    except Exception:
        _old = {}
    if not isinstance(build, (int, float)):
        build = _old.get("build")
    else:
        import time as _t
        try:
            _st = json.loads(PENDING.read_text(encoding="utf-8")) if PENDING.exists() else {}
        except Exception:
            _st = {}
        build, _st = stabilize(build, _old.get("build"), _t.time(), _st)
        try:
            PENDING.write_text(json.dumps(_st) + "\n", encoding="utf-8")
        except Exception:
            pass
    if not isinstance(chat, (int, float)):
        chat = _old.get("chat")
    out = {
        "ok": True,
        "source": "firefox-extension",
        "build": build,
        "chat": chat,
        "bot": msg.get("bot") if has_bot else _old.get("bot"),
        "bot_reset": msg.get("bot_reset") if has_bot else _old.get("bot_reset"),
        "at": msg.get("at"),
        "reason": msg.get("reason") or "page",
        "href": "https://grok.com/",
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    prev = {}
    if OUT.exists():
        try:
            prev = json.loads(OUT.read_text(encoding="utf-8"))
        except Exception:
            prev = {}
    OUT.write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")
    changed = (prev.get("build") != build) or (prev.get("chat") != chat)
    # Oct 18: same rule for the Super Grok (build) history - no bounce writes.
    if changed and isinstance(build, (int, float)) and HIST.exists():
        import time as _t2
        _w = []
        for _l in HIST.read_text(encoding="utf-8").splitlines()[-200:]:
            try:
                _h = json.loads(_l)
                _ep = _parse_reset(_h.get("at"), _t2.time()) if _h.get("at") else None
                if isinstance(_h.get("build"), (int, float)) and _ep:
                    _w.append((_ep, _h["build"]))
            except Exception:
                pass
        _seen_b = _seen_update(OUT.parent / "grokcom_build_seen.json", build, _t2.time())
        if not should_write(build, _w, _t2.time(), _seen_b) and prev.get("chat") == chat:
            changed = False
    if changed or not HIST.exists():
        with HIST.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({
                "build": build,
                "chat": chat,
                "at": out["at"],
                "reason": out["reason"],
            }) + "\n")
        lines = HIST.read_text(encoding="utf-8").splitlines()
        if len(lines) > MAX_HIST:
            HIST.write_text("\n".join(lines[-MAX_HIST:]) + "\n", encoding="utf-8")
    write_msg({"ok": True, "wrote": str(OUT), "changed": bool(changed), "bot_recorded": bool(bot_rd)})


if __name__ == "__main__":
    main()
