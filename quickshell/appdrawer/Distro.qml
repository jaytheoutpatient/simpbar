pragma Singleton

import Quickshell
import Quickshell.Io

// Distro branding for the drawer: reads /etc/os-release once at startup,
// maps the distro ID (falling back through ID_LIKE, then to the generic
// Linux glyph) to a Nerd Font linux-* logo codepoint, and exposes it as a
// QML string for a Text item to render. Nerd Font rather than an icon-theme
// file because the glyph is guaranteed present (same font file the bar
// renders its icons from, installed by the simpbar installer) while a
// themed distributor-logo file may or may not exist. Every codepoint below
// was verified present in JetBrainsMonoNerdFont-Regular.ttf.
Singleton {
    id: root

    FileView {
        id: osRelease
        path: "/etc/os-release"
        blockLoading: true
    }

    // os-release line value: KEY=... with optional double quotes.
    function valueOf(key) {
        if (!osRelease.loaded)
            return "";
        const lines = osRelease.text().split("\n");
        for (let i = 0; i < lines.length; ++i) {
            const line = lines[i];
            if (line.indexOf(key + "=") === 0) {
                let v = line.substring(key.length + 1).trim();
                if (v.length >= 2 && v[0] === '"' && v[v.length - 1] === '"')
                    v = v.substring(1, v.length - 1);
                return v.toLowerCase();
            }
        }
        return "";
    }

    // ID -> Nerd Font codepoint (BMP PUA linux-* set, plus fa-linux).
    readonly property var glyphs: ({
        "cachyos": 0xf385,
        "arch": 0xf303, "archarm": 0xf303, "archlinux": 0xf303,
        "artix": 0xf31f, "endeavouros": 0xf322, "garuda": 0xf337,
        "manjaro": 0xf312, "arcolinux": 0xf346, "archcraft": 0xf345,
        "crystal": 0xf348, "xerolinux": 0xf34a, "biglinux": 0xf347,
        // Featherlite is Arch-based with no Nerd Font glyph of its own, so
        // it wears the Arch logo (mirrored in simpbar/src/main.zig).
        "featherlite": 0xf303,
        "debian": 0xf306, "ubuntu": 0xf31b, "pop": 0xf32a, "pop_os": 0xf32a,
        "linuxmint": 0xf30e, "zorin": 0xf32f, "elementary": 0xf309,
        "kubuntu": 0xf333, "kde_neon": 0xf331, "neon": 0xf331,
        "fedora": 0xf30a, "nobara": 0xf380,
        "rhel": 0xf316, "redhat": 0xf316, "centos": 0xf304,
        "rocky": 0xf32b, "almalinux": 0xf31d,
        "opensuse": 0xf314, "tumbleweed": 0xf37d, "opensuse-tumbleweed": 0xf37d,
        "opensuse-leap": 0xf37e, "leap": 0xf37e,
        "nixos": 0xf313, "gentoo": 0xf30d, "slackware": 0xf318,
        "void": 0xf32e, "alpine": 0xf300, "solus": 0xf32d,
        "mx": 0xf33f, "mxlinux": 0xf33f
    })

    // ID_LIKE family token -> codepoint, for distros with no direct entry.
    readonly property var familyGlyphs: ({
        "arch": 0xf303, "debian": 0xf306, "ubuntu": 0xf31b,
        "fedora": 0xf30a, "rhel": 0xf316, "centos": 0xf304,
        "suse": 0xf314, "opensuse": 0xf314, "nixos": 0xf313,
        "gentoo": 0xf30d, "slackware": 0xf318, "void": 0xf32e,
        "alpine": 0xf300, "solus": 0xf32d
    })

    readonly property string distroId: valueOf("ID")
    readonly property string distroLike: valueOf("ID_LIKE")

    // Resolved logo codepoint: direct ID hit, then each ID_LIKE token
    // against both tables, then the generic Linux glyph. Never zero.
    readonly property int logoCode: {
        if (root.glyphs[root.distroId] !== undefined)
            return root.glyphs[root.distroId];
        const toks = root.distroLike.split(" ");
        for (let i = 0; i < toks.length; ++i) {
            if (toks[i].length === 0)
                continue;
            if (root.glyphs[toks[i]] !== undefined)
                return root.glyphs[toks[i]];
            if (root.familyGlyphs[toks[i]] !== undefined)
                return root.familyGlyphs[toks[i]];
        }
        return 0xf17c; // fa-linux: the universal fallback
    }

    // Single-char string for a Text item with the Nerd Font family.
    readonly property string logo: String.fromCharCode(root.logoCode)

    // Human-readable name (tooltip/accessible text), e.g. "CachyOS Linux".
    readonly property string displayName: {
        if (!osRelease.loaded)
            return "Linux";
        const lines = osRelease.text().split("\n");
        for (let i = 0; i < lines.length; ++i) {
            if (lines[i].indexOf("PRETTY_NAME=") === 0) {
                let v = lines[i].substring(12).trim();
                if (v.length >= 2 && v[0] === '"' && v[v.length - 1] === '"')
                    v = v.substring(1, v.length - 1);
                if (v.length > 0)
                    return v;
            }
        }
        return root.distroId.length > 0 ? root.distroId : "Linux";
    }
}
