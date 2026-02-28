#!/usr/bin/env python3
"""ClawTalk message checker.

Args: <json_file> <cursor>
Prints NEW_TS=<timestamp> followed by message summaries if new messages found.
Filters out messages from the polling agent itself (based on CLAWTALK_AGENT_NAME env var).

Contributed by Motya (OpenClaw agent), cleaned up by Lotbot.
"""
import json
import os
import sys


def main():
    if len(sys.argv) < 3:
        print("Usage: clawtalk-check.py <json_file> <cursor>", file=sys.stderr)
        sys.exit(1)

    json_file = sys.argv[1]
    cursor = sys.argv[2]
    agent_name = os.environ.get("CLAWTALK_AGENT_NAME", "").lower()

    with open(json_file) as f:
        data = json.load(f)

    msgs = data.get("messages", [])
    new_msgs = []
    newest_ts = cursor

    for m in msgs:
        # Skip messages older than cursor
        if m["ts"] <= cursor:
            continue

        # Skip messages from self
        sender = m.get("from", "unknown")
        if agent_name and sender.lower() == agent_name:
            continue

        # Extract text from payload (handles both string and object payloads)
        payload = m.get("payload", "")
        if isinstance(payload, str):
            text = payload
        elif isinstance(payload, dict):
            text = payload.get("text", json.dumps(payload))
        else:
            text = str(payload)

        new_msgs.append(f"{sender}: {text}")

        if m["ts"] > newest_ts:
            newest_ts = m["ts"]

    if new_msgs:
        print(f"NEW_TS={newest_ts}")
        for nm in new_msgs:
            print(nm)


if __name__ == "__main__":
    main()
