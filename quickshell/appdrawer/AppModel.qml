pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The app catalogue.
//
// DesktopEntries is a global singleton (isCreatable: false), so it cannot be
// declared or hooked with onApplicationsChanged -- and it populates
// asynchronously, so reading it once on startup yields zero entries. Poll until
// it fills, then snapshot into `apps` so the UI has a plain reactive array.
Singleton {
    id: root

    // Resolved the way quickshell itself resolves configs: XDG_CONFIG_HOME when
    // it is set, ~/.config otherwise. Deriving this from HOME alone would put
    // favourites.json somewhere quickshell never looks, so on a system with
    // XDG_CONFIG_HOME pointed elsewhere the pinned apps would silently start
    // from empty. env() returns "" for an unset variable, so the || is a
    // fallback rather than a null check.
    //
    // Note this deliberately does NOT match Theme.qml's matugen.json path, which
    // is $HOME-based because that is where the bar itself looks.
    readonly property string cfgDir: (Quickshell.env("XDG_CONFIG_HOME")
                                      || Quickshell.env("HOME") + "/.config")
                                  + "/quickshell/appdrawer"

    property var apps: ([])
    property bool ready: false
    property int loadTries: 0

    property string query: ""
    property string category: "All"

    property var favIds: ([])

    // freedesktop main categories, in sidebar order. Several categories are
    // present on this system but never as MainCategory, so we derive the
    // bucket from the first recognised entry in the Categories list instead.
    readonly property var mainCats: [
        "AudioVideo", "Audio", "Video",
        "Development", "Education", "Game", "Graphics",
        "Network", "Office", "Science",
        "Settings", "System", "Utility"
    ]

    readonly property var catLabels: ({
        "AudioVideo": "Media",
        "Audio": "Audio",
        "Video": "Video",
        "Development": "Development",
        "Education": "Education",
        "Game": "Games",
        "Graphics": "Graphics",
        "Network": "Network",
        "Office": "Office",
        "Science": "Science",
        "Settings": "Settings",
        "System": "System",
        "Utility": "Utilities",
        "Other": "Other"
    })

    function mainCat(cats) {
        if (!cats)
            return "Other";
        for (var i = 0; i < cats.length; i++) {
            if (mainCats.indexOf(cats[i]) !== -1)
                return cats[i];
        }
        return "Other";
    }

    // Snapshot the singleton's entries into plain objects. Keeping the
    // DesktopEntry handle lets us launch with entry.execute(), which applies
    // the desktop file's own Exec rules (field codes, terminal flag, cwd).
    function load() {
        if (root.ready)
            return true;

        // Icon paths are resolved by a separate one-shot scan. Snapshotting
        // before it finishes would permanently bake in empty icon strings,
        // since `apps` is only assigned once.
        if (!Icons.ready)
            return false;

        var vals = DesktopEntries.applications.values;
        if (!vals || vals.length === 0)
            return false;

        var seen = {};
        var out = [];
        for (var i = 0; i < vals.length; i++) {
            var e = vals[i];
            if (e.noDisplay)
                continue;
            var id = String(e.id);
            if (seen[id])
                continue;
            seen[id] = true;

            var cats = e.categories ? Array.prototype.slice.call(e.categories) : [];
            var kws = e.keywords ? Array.prototype.slice.call(e.keywords) : [];

            out.push({
                id: id,
                name: String(e.name || id),
                icon: Icons.path(String(e.icon || "")),
                cat: mainCat(cats),
                keywords: kws,
                entry: e
            });
        }

        // Stable alphabetical order so the grid does not shuffle between loads.
        out.sort(function (a, b) {
            return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1;
        });

        apps = out;
        ready = true;
        console.log("APPS loaded=" + out.length);
        return true;
    }

    Timer {
        interval: 300
        running: true
        repeat: !root.ready
        onTriggered: {
            root.loadTries++;
            if (root.loadTries > 60) {
                console.log("APPS timeout: DesktopEntries never populated");
                running = false;
                return;
            }
            root.load();
        }
    }

    // ---- favourites -------------------------------------------------------

    FileView {
        id: favFile
        path: root.cfgDir + "/favourites.json"
        watchChanges: true
        blockLoading: true
        onFileChanged: reload()
        onAdapterUpdated: writeAdapter()

        JsonAdapter {
            property list<string> ids: []
        }
    }

    // Fan the adapter's list into a plain array the UI can bind to.
    property var favBinding: favFile.adapter.ids
    onFavBindingChanged: favIds = favFile.adapter.ids

    // Ids are matched against DesktopEntry.id, which is the desktop file's
    // basename -- e.g. Dolphin is "org.kde.dolphin", NOT "dolphin". Matching
    // on the icon or a guessed name silently drops pins, so normalise against
    // the real catalogue before comparing.
    function resolveId(id) {
        if (apps.length === 0)
            return id;
        for (var i = 0; i < apps.length; i++) {
            if (apps[i].id === id)
                return id;
        }
        // Fall back to matching by app name, so a hand-edited favourites file
        // keyed by display name still resolves.
        for (var j = 0; j < apps.length; j++) {
            if (apps[j].name.toLowerCase() === String(id).toLowerCase())
                return apps[j].id;
        }
        return id;
    }

    function isFav(id) {
        var real = resolveId(id);
        for (var i = 0; i < favIds.length; i++) {
            if (favIds[i] === id || resolveId(favIds[i]) === real)
                return true;
        }
        return false;
    }

    function toggleFav(id) {
        var next = [];
        var removed = false;
        // Rebuild rather than splice on the raw id, so an id stored under a
        // different form is still removed instead of duplicated.
        for (var i = 0; i < favIds.length; i++) {
            if (favIds[i] === id || resolveId(favIds[i]) === resolveId(id)) {
                removed = true;
                continue;
            }
            next.push(favIds[i]);
        }
        if (!removed)
            next.push(resolveId(id));

        favIds = next;
        favFile.adapter.ids = next;   // triggers onAdapterUpdated -> writeAdapter
    }

    // ---- filtering --------------------------------------------------------

    readonly property var categories: {
        if (!ready)
            return ["All", "Favourites"];
        var counts = {};
        var order = [];
        for (var i = 0; i < apps.length; i++) {
            var c = apps[i].cat;
            if (counts[c] === undefined) {
                counts[c] = 0;
                order.push(c);
            }
            counts[c]++;
        }
        order.sort(function (a, b) {
            var ia = root.mainCats.indexOf(a);
            var ib = root.mainCats.indexOf(b);
            if (ia === -1) ia = 999;
            if (ib === -1) ib = 999;
            return ia - ib;
        });

        var out = ["All", "Favourites"];
        for (var j = 0; j < order.length; j++)
            out.push(order[j]);
        return out;
    }

    function labelFor(c) {
        if (c === "All")
            return "All Apps";
        if (c === "Favourites")
            return "Favourites";
        return catLabels[c] ? catLabels[c] : c;
    }

    readonly property var visibleApps: {
        if (!ready)
            return [];
        var q = query.trim().toLowerCase();
        var out = [];
        for (var i = 0; i < apps.length; i++) {
            var a = apps[i];

            if (category === "Favourites" && !isFav(a.id))
                continue;
            if (category !== "All" && category !== "Favourites" && a.cat !== category)
                continue;

            if (q.length > 0) {
                var hit = a.name.toLowerCase().indexOf(q) !== -1;
                if (!hit) {
                    for (var k = 0; k < a.keywords.length && !hit; k++) {
                        hit = String(a.keywords[k]).toLowerCase().indexOf(q) !== -1;
                    }
                }
                if (!hit)
                    continue;
            }
            out.push(a);
        }
        return out;
    }

    // ---- launching --------------------------------------------------------

    function launch(a) {
        if (!a)
            return;

        // Terminal apps: entry.execute() would drop them straight into a
        // non-graphical session on a bare layer-shell surface, so spawn the
        // user's terminal instead.
        if (a.entry.runInTerminal) {
            newProcess("foot", ["-e", "sh", "-c", String(a.entry.execString || a.name)]);
        } else {
            a.entry.execute();
        }
    }

    Process {
        id: spawner
        stdout: StdioCollector {}
        stderr: StdioCollector {}
    }

    function newProcess(bin, argv) {
        spawner.command = [bin].concat(argv);
        spawner.running = true;
    }
}