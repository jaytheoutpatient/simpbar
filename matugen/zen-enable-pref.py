#!/usr/bin/env python3
"""Ensure the legacy user-chrome pref is enabled for a Firefox-derived browser.

Idempotently sets `toolkit.legacyUserProfileCustomizations.stylesheets` to true
in a profile's prefs.js. Used by the matugen [templates.zen] post_hook.

Usage:
    zen-enable-pref.py <path to prefs.js>
"""
import os
import sys

def main() -> int:
    if len(sys.argv) != 2:
        print("usage: zen-enable-pref.py <prefs.js>", file=sys.stderr)
        return 1

    prefs = os.path.expanduser(sys.argv[1])
    key = "toolkit.legacyUserProfileCustomizations.stylesheets"

    try:
        with open(prefs, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except FileNotFoundError:
        lines = []

    out: list[str] = []
    found = False
    for line in lines:
        if key in line:
            found = True
            out.append(f'user_pref("{key}", true);\n')
        else:
            out.append(line)

    if not found:
        out.append(f'user_pref("{key}", true);\n')

    with open(prefs, "w", encoding="utf-8") as f:
        f.writelines(out)

    print(f"zen-enable-pref: stylesheets pref -> true in {prefs}")
    return 0

if __name__ == "__main__":
    sys.exit(main())