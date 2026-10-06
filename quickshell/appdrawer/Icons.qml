pragma Singleton

import Quickshell
import Quickshell.Io

// Icon name -> absolute file path.
//
// Qt's Image does NOT resolve freedesktop icon theme names: `source: "firefox"`
// fails with Image.Error even though the file is installed, and this Qt build
// has no theme-aware Image type (IconImage exists in
// libQt6QuickControls2Impl but exposes no fromTheme, and Quickshell's
// IconImage is only a thin Image wrapper). So we resolve names ourselves with
// a single one-shot `find` over the app-icon directories, then pick the best
// candidate per name. One subprocess at startup, ~4k lines, no cache file to go
// stale.
Singleton {
    id: root

    readonly property var roots: [
        "/usr/share/icons",
        "/usr/share/pixmaps",
        "${HOME}/.local/share/icons",
        "${HOME}/.icons",
        // Flatpaks do NOT install into /usr/share/icons. Their desktop entries
        // declare icon names like `io.github.shiftey.Desktop` that only exist
        // in flatpak's own appstream store, under a per-app hash directory.
        "/var/lib/flatpak/appstream",
        "/var/lib/flatpak/exports/share/icons",
        "${HOME}/.local/share/flatpak/exports/share/icons"
    ]

    property var best: ({})     // basename -> { path: ..., rank: ... }
    property bool ready: false

    // Rank candidates so the closest-to-native-size icon wins. Higher is better.
    function rankOf(path) {
        var ext = path.substring(path.lastIndexOf(".") + 1).toLowerCase();

        // Flatpak appstream art is generic 64/128px raster art kept in a cache
        // store, not a themed icon. Rank it below every real theme tier (whose
        // lowest is ~201 for a 1px icon) so a genuine themed icon always wins
        // and this only ever fills a genuine gap. Within appstream, prefer the
        // 128px copy over the 64px one; the cap keeps the best possible
        // appstream rank (170) below that ~201 floor.
        if (path.indexOf("/appstream/") !== -1) {
            var sm = path.match(/\/icons\/(\d+)x\d+\//);
            return 150 + (sm ? Math.min(20, parseInt(sm[1], 10) / 8) : 0);
        }

        var score = 0;

        // Scalable art stays crisp at any tile size.
        if (ext === "svg")
            score += 1000;

        // pixmaps have no size directory; trust them but rank below a real
        // theme hit at a sensible resolution.
        if (path.indexOf("/pixmaps/") !== -1)
            return 700 + score;

        var m = path.match(/\/(\d+)x(\d+)(?:@\d+x\d+)?\//);
        if (m) {
            var w = parseInt(m[1], 10);
            // Sweet spot is 96-192px: crisp for a ~44px tile, not wasteful.
            if (w >= 96 && w <= 192)
                score += 400;
            else if (w < 96)
                score += 200 + w;          // prefer bigger among the small
            else
                score += 400 - Math.min(300, (w - 192) / 4);
        } else {
            score += 300;
        }

        // hicolor is the fallback theme; prefer a real theme's art when present.
        if (path.indexOf("/hicolor/") !== -1)
            score += 60;

        return score;
    }

    function offer(path) {
        var dot = path.lastIndexOf(".");
        if (dot <= 0)
            return;
        var name = path.substring(path.lastIndexOf("/") + 1, dot);
        if (name.length === 0)
            return;
        var rank = rankOf(path);
        var cur = best[name];
        if (cur === undefined || rank > cur.rank) {
            best[name] = { "path": path, "rank": rank };
        }
    }

    // Public lookup. Returns "" when nothing matches so callers can fall back to
    // a text glyph rather than showing a broken image.
    function path(name) {
        if (!name)
            return "";
        if (name.indexOf("/") === 0)      // already an absolute path
            return name;
        var hit = best[name];
        return hit ? hit.path : "";
    }

    Process {
        id: scan
        // The argument list is built from `roots` rather than hardcoding
        // roots[0..3]: a hardcoded index list silently skips any root added
        // later, which is exactly the bug that left every Flatpak icon missing.
        //
        // `sh -c 'find "$@"' sh <roots...>` so that roots which do not exist on
        // this machine are skipped instead of making `find` exit non-zero, and
        // the trailing `exit 0` keeps a missing optional root from looking like
        // a scan failure.
        command: ["sh", "-c",
                  "find \"$@\" -type f \\( -iname '*.png' -o -iname '*.svg' -o -iname '*.xpm' \\) 2>/dev/null; exit 0",
                  "appdrawer-icons"].concat(root.roots)
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                var lines = String(this.text).split("\n");
                for (var i = 0; i < lines.length; i++) {
                    var l = lines[i].trim();
                    if (l.length > 0)
                        root.offer(l);
                }
                root.ready = true;
                console.log("ICONS ready entries=" + Object.keys(root.best).length);
            }
        }
    }
}