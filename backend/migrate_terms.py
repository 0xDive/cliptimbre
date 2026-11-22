#!/usr/bin/env python3
"""Add newly shipped rules to an existing custom risk dictionary safely.

Never replace or edit existing rules: users may have customized their regexes.
Malformed user dictionaries are left untouched (the scanner reports bad JSON).
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

NEW_IDS = {"ru_personal_insults", "en_personal_insults"}


def merge_terms(terms_path: Path, defaults_path: Path) -> int:
    if not terms_path.exists():
        terms_path.write_bytes(defaults_path.read_bytes())
        print("Created default YouTube risk dictionary")
        return len(NEW_IDS)
    try:
        data = json.loads(terms_path.read_text(encoding="utf-8"))
        defaults = json.loads(defaults_path.read_text(encoding="utf-8"))
        rules = data["rules"]
        if not isinstance(rules, list):
            raise ValueError("dictionary rules must be a list")
        existing_ids = {str(rule.get("id")) for rule in rules if isinstance(rule, dict)}
        to_add = [rule for rule in defaults["rules"] if rule.get("id") in NEW_IDS and rule.get("id") not in existing_ids]
        if not to_add:
            print("YouTube personal-insult dictionary already up to date")
            return 0
        # Preserve every user-defined rule in place, and insert new ones after.
        data["rules"] = rules + to_add
        data["version"] = max(int(data.get("version", 1)), 2)
        next_path = terms_path.with_suffix(terms_path.suffix + ".new")
        next_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        os.replace(next_path, terms_path)
        print(f"Added {len(to_add)} personal-insult rules without overwriting custom rules")
        return len(to_add)
    except Exception as exc:
        print(f"WARNING: Could not merge personal-insult rules into {terms_path}: {exc}; file preserved", file=sys.stderr)
        return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: migrate_terms.py INSTALLED_JSON DEFAULT_JSON")
    merge_terms(Path(sys.argv[1]), Path(sys.argv[2]))
