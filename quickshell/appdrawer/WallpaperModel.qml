pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The wallpaper list, and the thing that applies one.
//
// Deliberately a thin wrapper over the `simpbar-wallpaper` CLI rather than
// walking the wallpaper folders in QML. "Which files count as a wallpaper"
// then has exactly one definition -- the same extension list swaybg can decode,
// the same folder list, the same ~ expansion -- instead of two that drift. The
// CLI also owns the swaybg swap and the matugen run, so a wallpaper picked here
// and one picked from a terminal end up in identical state.
//
// That consistency is the whole point. The bar used to be themed from one image
// while a different one was on screen, because two programs each had their own
// idea of the current wallpaper and one of them could not parse a filename with
// spaces in it.
Singleton {
    id: root

    readonly property string cfgDir: (Quickshell.env("XDG_CONFIG_HOME")
                                      || Quickshell.env("HOME") + "/.config")
                                  + "/simpbar"

    // Absolute path of the wallpaper currently applied. Compared against each
    // tile's path to badge the active one.
    property string current: ""
    property bool ready: false
    property string query: ""

    // Transient one-line feedback in the footer ("Setting…", or an error).
    property string status: ""

    // Backing store for `items`. Reassigned wholesale rather than mutated: QML
    // cannot observe an in-place push/splice on a `var` array, so the grid would
    // never repaint.
    property var _items: []
    readonly property var items: _items
    readonly property var visibleItems: {
        var q = query.trim().toLowerCase();
        if (q.length === 0)
            return items;
        var out = [];
        for (var i = 0; i < items.length; i++) {
            if (items[i].name.toLowerCase().indexOf(q) !== -1)
                out.push(items[i]);
        }
        return out;
    }

    // ---- listing ---------------------------------------------------------

    Process {
        id: lister
        // stdout is collected, not streamed: the list arrives as one blob and
        // is parsed once, so the grid never repopulates row by row.
        stdout: StdioCollector {
            onStreamFinished: {
                root.applyList(text);
                lister.running = false;
            }
        }
        stderr: StdioCollector {
            onStreamFinished: {
                // No `list` subcommand (older install, or not on PATH) should
                // say so rather than looking like an empty folder.
                if (text.trim().length > 0)
                    root.status = text.trim().split("\n")[0];
                lister.running = false;
            }
        }
    }

    function refresh() {
        ready = false;
        lister.command = ["simpbar-wallpaper", "list"];
        lister.running = true;
    }

    // "path<TAB>name" per line. Split on the tab, never on spaces: wallpaper
    // names are full of them.
    function applyList(blob) {
        var out = [];
        var lines = blob.split("\n");
        for (var i = 0; i < lines.length; i++) {
            var line = lines[i];
            if (line.length === 0)
                continue;
            var tab = line.indexOf("\t");
            var path = tab === -1 ? line : line.substring(0, tab);
            var name = tab === -1 ? "" : line.substring(tab + 1);
            if (path.length === 0)
                continue;
            out.push({ path: path, name: name.length > 0 ? name : path });
        }
        root._items = out;
        ready = true;
    }

    // ---- current ---------------------------------------------------------

    Process {
        id: currentQuery
        stdout: StdioCollector {
            onStreamFinished: {
                root.current = text.trim();
                currentQuery.running = false;
            }
        }
        stderr: StdioCollector {
            // `current` exits non-zero when it genuinely has nothing to report.
            // That is not an error worth surfacing.
            onStreamFinished: currentQuery.running = false
        }
    }

    function refreshCurrent() {
        currentQuery.command = ["simpbar-wallpaper", "current"];
        currentQuery.running = true;
    }

    // ---- applying --------------------------------------------------------

    property bool applying: false

    Process {
        id: setter
        stdout: StdioCollector {
            onStreamFinished: {
                var out = text.trim();
                // The engine echoes the wallpaper it applied, so `current` is
                // updated from what actually happened rather than from what we
                // asked for.
                if (out.length > 0)
                    root.current = out;
            }
        }
        stderr: StdioCollector {
            onStreamFinished: {
                var msg = text.trim();
                if (msg.length > 0)
                    root.status = msg.split("\n")[0];
            }
        }
        // Single place that clears the busy state, for both success and
        // failure. Clearing it in the collectors instead races them: stdout and
        // stderr finish independently, so a run with no stderr would never
        // re-enable the picker.
        onExited: {
            root.applying = false;
            setter.running = false;
            // Leave a success message off; keep a failure on screen.
            if (root.status.length > 0 && !root.status.endsWith("…"))
                return;
            root.status = "";
        }
    }

    // Apply a wallpaper: swaybg swaps, matugen recolors, the bar live-reloads
    // from its post_hook. The drawer deliberately stays open so the recolour is
    // visible behind it -- closing here would hide the entire point.
    function apply(path) {
        if (applying)
            return;
        applying = true;
        status = "Setting " + nameOf(path) + "…";
        setter.command = ["simpbar-wallpaper", "set", path];
        setter.running = true;
    }

    function random() {
        if (applying)
            return;
        applying = true;
        status = "Picking a random wallpaper…";
        setter.command = ["simpbar-wallpaper", "random"];
        setter.running = true;
    }

    // ---- fetching new wallpapers (Bing today / random from wallhaven) ----

    // True while a fetch runs. Kept separate from `applying` so the two are
    // distinguishable in the footer, but both block the action buttons: only
    // one wallpaper-related process may be in flight at a time, and they share
    // the same "Working…" state.
    property bool fetching: false

    Process {
        id: fetcher
        stdout: StdioCollector {
            onStreamFinished: {
                // bing --apply and random --online echo the applied wallpaper's
                // path on stdout. Keep it for the exit handler rather than
                // repainting the badge mid-run.
                var out = text.trim();
                if (out.length > 0)
                    root._fetchApplied = out.split("\n")[0];
            }
        }
        stderr: StdioCollector {
            onStreamFinished: {
                var msg = text.trim();
                if (msg.length > 0)
                    root.status = msg.split("\n")[0];
            }
        }
        // One place to unwind success and failure alike: a fetch changes what's
        // in the wallpaper folder and possibly what's on screen, so the grid
        // and the "current" badge are refetched however the run ended. Keeping
        // the applied path across stdout/stderr/exit is also why the badge
        // update happens here rather than in a collector, which can fire before
        // the other stream has finished.
        onExited: function(exitCode) {
            root.fetching = false;
            var applied = root._fetchApplied;
            root._fetchApplied = "";
            if (applied.length > 0)
                root.current = applied;
            root.refresh();
            root.refreshCurrent();
            // exit == 0 is a success, and a success's stderr chatter
            // ("already have …", "saved …") is just noise -- clear it so the
            // footer doesn't sit on a stale line after a quiet dedup. A
            // non-zero exit means the engine had a real problem, whose message
            // it printed to stderr; that one stays on screen.
            if (exitCode !== 0)
                return;
            root.status = "";
        }
    }
    property string _fetchApplied: ""

    // Today's Bing wallpaper, downloaded into the wallpaper folder and applied.
    // --apply is the drawer's call, not the CLI default: clicking a fetch
    // button here is the same gesture as clicking Random -- "put something on
    // screen" -- so it ends with the wallpaper on screen, and the tile showing
    // up in the grid is the side effect that makes the picker feel alive.
    function fetchBing() {
        if (applying || fetching)
            return;
        fetching = true;
        status = "Fetching today's Bing wallpaper…";
        fetcher.command = ["simpbar-wallpaper", "bing", "--count", "1", "--apply"];
        fetcher.running = true;
    }

    // A random wallpaper from wallhaven.cc, fetched and applied. The engines's
    // `random --online` applies by design; this is the same verb over the
    // internet rather than the local folder.
    function randomOnline() {
        if (applying || fetching)
            return;
        fetching = true;
        status = "Drawing a random online wallpaper…";
        fetcher.command = ["simpbar-wallpaper", "random", "--online"];
        fetcher.running = true;
    }

    function nameOf(path) {
        var i = path.lastIndexOf("/");
        return i === -1 ? path : path.substring(i + 1);
    }

    function isCurrent(path) {
        return current.length > 0 && current === path;
    }

    Component.onCompleted: {
        refresh();
        refreshCurrent();
    }
}