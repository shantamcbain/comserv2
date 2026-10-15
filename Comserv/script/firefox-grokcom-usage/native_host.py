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
    if not isinstance(build, (int, float)) and not isinstance(chat, (int, float)):
        write_msg({"ok": False, "error": "no_percent"})
        return
    out = {
        "ok": True,
        "source": "firefox-extension",
        "build": build,
        "chat": chat,
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
    write_msg({"ok": True, "wrote": str(OUT), "changed": bool(changed)})


if __name__ == "__main__":
    main()
