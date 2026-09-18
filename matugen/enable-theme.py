#!/usr/bin/env python3
"""Enable a theme file in a Vencord-derived client (Vesktop / Equicord).

Idempotently appends the theme filename to the `enabledThemes` list in the
client's settings.json. Used by matugen post_hooks (see config.toml).

Usage:
    enable-theme.py <settings.json path> <theme filename>
"""
import json
import os
import sys

def main() -> int:
    if len(sys.argv) != 3:
        print("usage: enable-theme.py <settings.json> <theme filename>", file=sys.stderr)
        return 1

    path, theme = sys.argv[1], sys.argv[2]
    path = os.path.expanduser(path)
    theme = os.path.basename(theme)

    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        print(f"enable-theme: no readable settings at {path}, skipping", file=sys.stderr)
        return 0

    themes = data.setdefault("enabledThemes", [])
    if theme not in themes:
        themes.append(theme)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=4)
            f.write("\n")
        print(f"enable-theme: enabled {theme} in {path}")
    else:
        print(f"enable-theme: {theme} already enabled in {path}")

    return 0

if __name__ == "__main__":
    sys.exit(main())