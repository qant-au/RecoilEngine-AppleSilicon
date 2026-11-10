#!/usr/bin/env python3
"""Assemble messages/*.jsonc (one file per message) into the single
messages.json that Accurona fetches.

Authors edit small, focused per-message files (clean diffs, easy review even
when there are many); this concatenates them — in filename order, so a
YYYY-MM-DD- prefix keeps them chronological — validating each as it goes.

Runs on the maintainer's machine or CI (python3, no third-party deps); the
LAUNCHER never runs this — it just reads the assembled JSON.

Usage: python3 assemble.py            # writes messages.json, validates
       python3 assemble.py --check    # validate, and fail if messages.json is
                                      # not the assembly of messages/; writes nothing
"""
import json, sys, pathlib

HERE = pathlib.Path(__file__).parent
SRC = HERE / "messages"
OUT = HERE / "messages.json"

def strip_jsonc(text):
    # drop full-line // comments (never a same-line comment, to stay safe
    # around URLs); matches the launcher's own stripper.
    return "\n".join(l for l in text.splitlines()
                     if not l.lstrip().startswith("//"))

def main():
    check_only = "--check" in sys.argv
    files = sorted(SRC.glob("*.jsonc")) + sorted(SRC.glob("*.json"))
    messages, ids, errors = [], set(), []
    for f in files:
        try:
            obj = json.loads(strip_jsonc(f.read_text()))
        except json.JSONDecodeError as e:
            errors.append(f"{f.name}: invalid JSON — {e}")
            continue
        if not isinstance(obj, dict) or "id" not in obj:
            errors.append(f"{f.name}: must be a single object with an 'id'")
            continue
        if obj["id"] in ids:
            errors.append(f"{f.name}: duplicate id '{obj['id']}'")
            continue
        ids.add(obj["id"])
        messages.append(obj)
    if errors:
        print("\n".join("ERROR " + e for e in errors), file=sys.stderr)
        sys.exit(1)
    doc = {"schema": 1, "messages": messages}
    text = json.dumps(doc, indent=2) + "\n"
    if check_only:
        # messages.json is what every installed copy fetches. It must be the
        # assembly of messages/ exactly: a message added without assembling
        # reaches nobody, and a stale file can keep showing a deleted one.
        if not OUT.exists() or OUT.read_text() != text:
            print(f"ERROR {OUT.name} is not the assembly of {SRC.name}/: "
                  "run assemble.py and commit the result", file=sys.stderr)
            sys.exit(1)
        print(f"ok: {len(messages)} message(s) valid, {OUT.name} is up to date")
        return
    OUT.write_text(text)
    print(f"wrote {OUT.name}: {len(messages)} message(s) from {len(files)} file(s)")

if __name__ == "__main__":
    main()
