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
        reset = _parse_reset(msg.get("bot_reset"), now)
        if reset is None and last and last.get("reset_at"):
            reset = int(last["reset_at"])
            while reset <= now:
                reset += 7 * 86400
        if last and last.get("source") == "auto" and float(last.get("value", -1)) == float(bot) \
                and now - int(last.get("at", 0)) < BOT_HEARTBEAT_S:
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
