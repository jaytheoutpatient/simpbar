pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Results of a wallhaven.cc search, as a preview grid source.
//
// A thin wrapper over `simpbar-wallpaper search <q> --thumbs --meta`, in the
// same style as WallpaperModel: the engine owns the API call, the API key,
// the purity gate and every wallhaven quirk (categories are filtered locally,
// the single-wallpaper lookup needs a key, results come 24 to a page, and so
// on), while this file only turns the tab-separated result lines into tiles.
// Pages after the first are appended by searchMore(), so the grid can grow to
// the full selection instead of stopping at 24.
//
// Nothing is downloaded yet -- the
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
    property int page: 1             // wallhaven result page behind `results`
    property int lastPage: 1         // last page the API reports for `query`
    property int total: 0            // total matches the API reports
    readonly property bool hasMore: results.length > 0 && page < lastPage

    // ---- search filters ------------------------------------------------
    // Survive across queries (a new search keeps the current filter set);
    // changing one re-runs the active query from page 1 via refilter().
    property string whSort: "date_added"  // favorites | toplist | date_added
    property string whRange: "1M"         // toplist window: 1d 1w 1M 1y
    property string whRes: "any"          // any | 1920x1080 | 2560x1440 | 3840x2160
    property string whColor: ""           // "" | 6-digit hex, no '#'
    property string whCat: "any"          // any | general | anime | people

    readonly property var sortValues: ["date_added", "toplist", "favorites"]
    readonly property var sortLabels: ["Latest", "Hot", "Loved"]
    readonly property var rangeValues: ["1d", "1w", "1M", "1y"]
    readonly property var rangeLabels: ["Day", "Week", "Month", "Year"]
    readonly property var resValues: ["any", "1920x1080", "2560x1440", "3840x2160"]
    readonly property var resLabels: ["Any res", "1080p", "1440p", "4K"]
    readonly property var catValues: ["any", "general", "anime", "people"]
    readonly property var catLabels: ["Any", "General", "Anime", "People"]
    readonly property var colorChoices: ["ff3b30", "ff9500", "ffd60a", "34c759", "00aacc", "0a84ff", "bf5af2", "ff6482"]

    function optLabel(values, labels, cur) {
        var i = values.indexOf(cur);
        return i >= 0 ? labels[i] : labels[0];
    }
    function sortLabel() { return optLabel(sortValues, sortLabels, whSort); }
    function rangeLabel() { return optLabel(rangeValues, rangeLabels, whRange); }
    function resLabel() { return optLabel(resValues, resLabels, whRes); }
    function catLabel() { return optLabel(catValues, catLabels, whCat); }

    function cycle(values, cur) {
        return values[(values.indexOf(cur) + 1) % values.length];
    }
    function cycleSort() { whSort = cycle(sortValues, whSort); refilter(); }
    function cycleRange() { whRange = cycle(rangeValues, whRange); refilter(); }
    function cycleRes() { whRes = cycle(resValues, whRes); refilter(); }
    function cycleCat() { whCat = cycle(catValues, whCat); refilter(); }
    function setColor(hex) {
        whColor = (whColor === hex) ? "" : hex;
        refilter();
    }

    // Extra engine args for the current filter set. topRange rides along
    // always — the engine only sends it with toplist sorting.
    function filterArgs() {
        var a = ["--sorting", whSort, "--toprange", whRange,
                 "--atleast", whRes, "--category", whCat];
        if (whColor.length > 0)
            a.push("--colors", whColor);
        return a;
    }

    // Re-run the active query under changed filters (fresh paging). Silent
    // while a run is in flight — the guard in search() would drop it anyway.
    function refilter() {
        if (query.length > 0 && !searching && !applying)
            search(query);
    }

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
        appending = false;
        root.query = q;
        root.page = 1;
        root.lastPage = 1;
        root.total = 0;
        status = "Searching wallhaven for \"" + q + "\"…";
        // --category any: the picker has no category switch, so filtering to
        // general here would silently hide most of a query's results (anime
        // feelings and all). Purity still gates server-side.
        // --pages 2: the first screenful is ~48 tiles, same as More presses.
        // The engine stops early at the last page, so short selections are
        // unaffected.
        searcher.command = ["simpbar-wallpaper", "search", q, "--thumbs", "--meta", "--pages", "2"].concat(filterArgs());
        searcher.running = true;
    }

    // Next result page, appended to the grid instead of replacing it. The
    // engine's `#meta` trailer carries the page number, so a failed page
    // (rate limit, empty after the local category filter) simply leaves
    // `page` where it was and the button stays for a retry.
    property bool appending: false
    function searchMore() {
        if (query.length === 0 || searching || applying || !hasMore)
            return;
        // Two pages (~48 tiles) per press: fewer taps to walk a big
        // selection, still polite to the API. Capped at what's left.
        var n = Math.min(2, lastPage - page);
        searching = true;
        appending = true;
        status = n > 1
            ? "Loading pages " + (page + 1) + "–" + (page + n) + " of " + lastPage + "…"
            : "Loading page " + (page + 1) + " of " + lastPage + "…";
        searcher.command = ["simpbar-wallpaper", "search", query, "--thumbs", "--meta", "--page", String(page + 1), "--pages", String(n)].concat(filterArgs());
        searcher.running = true;
    }

    function parse(text) {
        var out = [];
        var metaTotal = 0, metaPage = 0, metaLast = 0;
        var lines = String(text || "").split("\n");
        for (var i = 0; i < lines.length; i++) {
            var f = lines[i].split("\t");
            if (f.length === 4 && f[0] === "#meta") {
                metaTotal = parseInt(f[1], 10) || 0;
                metaPage = parseInt(f[2], 10) || 0;
                metaLast = parseInt(f[3], 10) || 0;
                continue;
            }
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
        if (metaPage > 0) {
            root.total = metaTotal;
            root.page = metaPage;
            root.lastPage = Math.max(metaLast, metaPage);
        } else if (!appending) {
            // No trailer (older engine): single page, as before. A failed
            // append must NOT reset the paging — the button stays for retry.
            root.page = 1;
            root.lastPage = 1;
        }
        root.results = appending ? results.concat(out) : out;
        appending = false;
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