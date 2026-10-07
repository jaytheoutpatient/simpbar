pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Results of a wallhaven.cc search, as a preview grid source.
//
// A thin wrapper over `simpbar-wallpaper search <q> --thumbs`, in the same
// style as WallpaperModel: the engine owns the API call, the API key, the
// purity gate and every wallhaven quirk (categories are filtered locally, the
// single-wallpaper lookup needs a key, and so on), while this file only turns
// the tab-separated result lines into tiles. Nothing is downloaded yet -- the
// grid shows remote thumbnails, and clicking a tile is what fetches the full
// wallpaper: `simpbar-wallpaper fetch <url> --apply`. That single command both
// lands it in the wallpaper folder and puts it on screen, so the picked tile
// shows up in the local grid on the next refresh with the "current" badge
// following it, exactly as if it had been downloaded from a terminal.
Singleton {
    id: root

    property bool searching: false   // an API search is in flight
    property bool applying: false    // a preview tile is being fetched + applied
    property string status: ""       // footer-worthy line (progress, errors)
    property string query: ""        // the query behind `results`
    property var results: []         // list of {id, res, purity, full, thumb}

    Process {
        id: searcher
        stdout: StdioCollector {
            onStreamFinished: root.parse(text)
        }
        stderr: StdioCollector {
            onStreamFinished: {
                var msg = text.trim();
                if (msg.length > 0)
                    root.status = msg.split("\n")[0];
            }
        }
        onExited: function(exitCode) {
            root.searching = false;
            // A clean run is quiet; only a real failure (non-zero exit -- no
            // results, rate limited, bad key) keeps its stderr line on screen.
            if (exitCode !== 0)
                return;
            root.status = "";
        }
    }

    Process {
        id: applier
        stdout: StdioCollector {
            onStreamFinished: {
                // fetch echoes the saved path on stdout; the exit handler's
                // WallpaperModel.refresh() is what makes it appear as a tile.
            }
        }
        stderr: StdioCollector {
            onStreamFinished: {
                var msg = text.trim();
                if (msg.length > 0)
                    root.status = msg.split("\n")[0];
            }
        }
        onExited: function(exitCode) {
            root.applying = false;
            WallpaperModel.refresh();
            WallpaperModel.refreshCurrent();
            if (exitCode !== 0)
                return;
            root.status = "";
        }
    }

    function search(q) {
        q = String(q || "").trim();
        if (q.length === 0 || searching || applying)
            return;
        searching = true;
        root.query = q;
        status = "Searching wallhaven for \"" + q + "\"…";
        searcher.command = ["simpbar-wallpaper", "search", q, "--thumbs"];
        searcher.running = true;
    }

    function parse(text) {
        var out = [];
        var lines = String(text || "").split("\n");
        for (var i = 0; i < lines.length; i++) {
            var f = lines[i].split("\t");
            if (f.length < 7 || f[6].length === 0)
                continue;
            out.push({
                id: f[0],
                res: f[1],
                purity: f[2],
                full: f[6],
                thumb: f.length > 7 ? f[7] : ""
            });
        }
        root.results = out;
    }

    function applyResult(i) {
        var r = root.results[i];
        if (!r || searching || applying)
            return;
        applying = true;
        status = "Saving wallhaven-" + r.id + "…";
        applier.command = ["simpbar-wallpaper", "fetch", r.full, "--apply"];
        applier.running = true;
    }
}