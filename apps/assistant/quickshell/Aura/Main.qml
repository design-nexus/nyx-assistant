import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Nyx.Shell
import Nyx.Theme

// The Assistant's Aura in the shared Quickshell runtime (nyx-shell-qs): a glow at the
// screen's edges that shows what the Assistant is doing. It only draws: the daemon's
// events (`nyx-assistant listen`) say the state, and nothing here waits on listening,
// speaking or the model. It draws as nyx-assistant-visual's GTK Aura does:
//
// - Full Aura: soft light up both sides; Edge Flow: a bright segment going round the
//   sides and bottom and back. `[ui] aura_style`, or the voice profile's.
// - Persistent: faint while idle in a conversation, full while busy; activity: only
//   while busy. A finished reply shows green, an approval amber, for two seconds; an
//   error four. `[ui] aura_visibility`.
// - The state's colour from the theme's swatches, tinted by the voice profile
//   (`[ui] aura_persona_colors`); it breathes and follows the voice's level.
// - Reduced motion (`[ui] aura_reduce_motion`, or the system's): still light, no movement.
// - A Shell Core `presentation` overlay: never takes the keyboard or input, hidden while
//   the session is locked and on a screen with a fullscreen window, on the screens
//   `[ui] aura_monitors` or `aura_monitor_mode` name.
Scope {
    id: root

    // What the daemon says. `offline` when it isn't running: then nothing shows.
    property string daemonState: "offline"
    property bool conversation: false
    // Waits longer between tries while the daemon stays off.
    property int retryMs: 2000
    property var ui: ({ enabled: true, aura_enabled: true, aura_style: "full", aura_visibility: "persistent", aura_intensity: 0.4, aura_thickness: 3, aura_speed: 1, aura_segment_length: 0.14, aura_audio_reactive: true, aura_persona_colors: true, aura_reduce_motion: "system", aura_monitor_mode: "active", aura_primary_monitor: "", aura_monitors: [], aura_renderer: "gtk" })
    property string personaId: ""
    // The voice profile's `aura_tint` and `aura_style`.
    property string tint: "accent"
    property string profileStyle: ""

    // What the Aura shows (GTK's State): idle, listening, thinking, speaking, attention,
    // done, error. `base` is the daemon's; done, attention and error show over it for a
    // while.
    property string shown: "idle"
    property string base: "idle"
    property bool completionPending: false
    property real changedAt: 0
    property real lastStateMs: 0

    readonly property string bin: (Quickshell.env("HOME") || "") + "/.local/bin/nyx-assistant"
    readonly property string voicesDir: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/nyx-assistant/voices"
    // Tests: a fixed state (and style), without the daemon.
    readonly property string testState: Quickshell.env("NYX_AURA_TEST_STATE") || ""
    Component.onCompleted: {
        if (testState !== "") {
            daemonState = "idle";
            setState(["done", "attention"].indexOf(testState) >= 0 ? testState : daemonToShown(testState));
            const style = Quickshell.env("NYX_AURA_TEST_STYLE");
            ui = Object.assign({}, ui, { aura_monitor_mode: "all" }, style ? { aura_style: style } : {});
        }
        if (ShellCore.ready)
            registerOverlay();
    }

    readonly property string style: profileStyle || ui.aura_style || "full"
    readonly property bool reducedMotion: ui.aura_reduce_motion === "on" || (ui.aura_reduce_motion === "system" && NyxTheme.motion.reduced === true)
    readonly property var overlayState: ShellCore.overlay("assistant-aura")
    readonly property bool allowed: overlayState === null || overlayState.visible || testState !== ""
    readonly property bool lit: {
        if (daemonState === "offline" || !ui.enabled || !ui.aura_enabled || !allowed)
            return false;
        // nyx-assistant-visual draws it unless `[ui] aura_renderer = "quickshell"`.
        if (ui.aura_renderer !== "quickshell" && testState === "")
            return false;
        return shown !== "idle" || (ui.aura_visibility === "persistent" && conversation);
    }
    property real fade: lit ? 1 : 0
    Behavior on fade {
        NumberAnimation {
            duration: root.reducedMotion ? 0 : 320
            easing.type: Easing.OutCubic
        }
    }
    readonly property bool drawing: fade > 0.01

    // The state's colour (GTK's): a theme swatch, tinted by the voice profile.
    function swatch(name, fallback) {
        const s = NyxTheme.swatches || {};
        return NyxTheme.qmlColor(s[name] || fallback);
    }
    function legacy(name) {
        return NyxTheme.qmlColor(NyxTheme.legacy[name] || NyxTheme.legacy.accent);
    }
    readonly property color tintColor: legacy(["highlight", "danger", "border"].indexOf(tint) >= 0 ? tint : "accent")
    readonly property color tone: {
        let c;
        switch (shown) {
        case "listening":
            c = swatch("blue", NyxTheme.legacy.accent);
            break;
        case "thinking":
            c = swatch("violet", NyxTheme.legacy.accent);
            break;
        case "speaking":
            c = swatch("teal", NyxTheme.legacy.highlight);
            break;
        case "attention":
            c = swatch("amber", NyxTheme.legacy.border);
            break;
        case "done":
            c = swatch("green", NyxTheme.legacy.highlight);
            break;
        case "error":
            return legacy("danger");
        default:
            return tintColor;
        }
        c = Qt.lighter(c, 1.0);
        if (ui.aura_persona_colors === false)
            return c;
        const p = tintColor;
        return Qt.rgba(c.r * 0.82 + p.r * 0.18, c.g * 0.82 + p.g * 0.18, c.b * 0.82 + p.b * 0.18, 1);
    }
    property color glowColor: tone
    Behavior on glowColor {
        ColorAnimation {
            duration: root.reducedMotion ? 0 : 150
        }
    }

    // GTK's state rules: a finished reply waits for speech to end, and the short states
    // (done, attention, error) aren't cut off by the daemon's next one.
    function setState(s) {
        const now = Date.now();
        const age = now - changedAt;
        if (shown === "error" && (s === "attention" || s === "done") && age < 4000)
            return;
        if (s === "error")
            completionPending = false;
        if (s === "done" && (base === "thinking" || base === "speaking")) {
            completionPending = true;
            return;
        }
        if ((s === "listening" || s === "thinking") && base !== s)
            completionPending = false;
        if (["idle", "listening", "thinking", "speaking"].indexOf(s) >= 0) {
            const previous = base;
            if (previous !== s) {
                levelTarget = 0;
                level = 0;
            }
            base = s;
            if (["done", "error", "attention"].indexOf(shown) >= 0 && age < (shown === "error" ? 4000 : 2000) && !(s === "listening" && shown === "done"))
                return;
            if (s === "idle" && (previous === "thinking" || previous === "speaking") && completionPending) {
                completionPending = false;
                s = "done";
            }
        } else if (s === "done" && base !== "idle") {
            return;
        }
        if (shown !== s) {
            shown = s;
            changedAt = now;
        }
        if (s === "done" || s === "attention" || s === "error") {
            expire.interval = s === "error" ? 4000 : 2000;
            expire.restart();
        }
    }
    Timer {
        id: expire
        onTriggered: if (root.testState === "" && (root.shown === "done" || root.shown === "attention" || root.shown === "error")) {
            root.shown = root.base;
            root.changedAt = Date.now();
        }
    }
    function daemonToShown(s) {
        switch (s) {
        case "listening":
        case "transcribing":
            return "listening";
        case "thinking":
        case "executing":
        case "activating":
            return "thinking";
        case "speaking":
            return "speaking";
        case "error":
        case "unavailable":
            return "error";
        default:
            return "idle";
        }
    }

    // The voice's level (GTK's meter): it opens above -48 dB, closes below -52 dB and
    // is full at -12 dB; it rises fast and falls slowly, and drops when the levels stop.
    property real level: 0
    property real levelTarget: 0
    property real levelAt: 0
    function meter(rms, previous) {
        const open = 0.004, close = 0.0025;
        if (!isFinite(rms) || rms <= 0 || (previous <= 0 && rms < open) || (previous > 0 && rms < close))
            return 0;
        const floor = 20 * Math.log10(open);
        return Math.max(0, Math.min(1, (20 * Math.log10(rms) - floor) / (-12 - floor)));
    }
    function setLevel(rms) {
        levelTarget = meter(rms, levelTarget);
        levelAt = Date.now();
    }

    // The breathing and Edge Flow's travel: a turn every 8 s at speed 1, slower while
    // thinking and slower still while listening.
    property real phase: 0
    FrameAnimation {
        running: root.drawing
        onTriggered: {
            const dt = Math.min(0.1, frameTime);
            const target = Date.now() - root.levelAt < 180 ? root.levelTarget : 0;
            const tau = target > root.level ? 0.035 : 0.16;
            root.level += (target - root.level) * (1 - Math.exp(-dt / tau));
            if (!root.reducedMotion && root.lit) {
                const factor = root.shown === "thinking" ? 0.65 : root.shown === "listening" ? 0.3 : 1;
                root.phase = (root.phase + dt * 0.12 * (root.ui.aura_speed || 1) * factor) % 1;
            }
        }
    }
    readonly property real breath: reducedMotion ? 1 : 0.88 + 0.12 * Math.abs(Math.sin(phase * 2 * Math.PI))
    readonly property real idleFactor: shown === "idle" ? 0.2 : 1
    readonly property real intensity: (ui.aura_intensity === undefined ? 0.4 : ui.aura_intensity) * idleFactor

    function handle(line) {
        let e;
        try {
            e = JSON.parse(line);
        } catch (err) {
            return;
        }
        handleEvent(e);
    }
    function handleEvent(e) {
        switch (e.type) {
        case "state":
            {
                const at = e.at_ms || 0;
                if (at > 0 && at < lastStateMs)
                    return;
                if (at > 0)
                    lastStateMs = at;
                daemonState = e.state || "idle";
                setState(daemonToShown(e.state));
                break;
            }
        case "tool_approval":
        case "proactive":
            setState("attention");
            break;
        case "error":
            setState("error");
            break;
        case "assistant_text":
            if (e.done === true)
                setState("done");
            break;
        case "session":
            conversation = (e.mode === "conversation" || e.mode === "follow_up") && (e.remaining_secs || 0) > 0;
            break;
        case "level":
            if (base === "listening")
                setLevel(e.rms || 0);
            break;
        case "playback_level":
            if (base === "speaking")
                setLevel(e.rms || 0);
            break;
        case "settings":
            if (e.running && e.running.ui)
                ui = Object.assign({}, ui, e.running.ui);
            if (e.running && e.running.assistant && e.running.assistant.persona_id)
                personaId = e.running.assistant.persona_id;
            break;
        }
    }

    // The voice profile (`voices/<persona>.toml`): its Aura tint and style.
    FileView {
        id: profile
        path: /^[a-z0-9_-]+$/.test(root.personaId) ? root.voicesDir + "/" + root.personaId + ".toml" : ""
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            const get = key => {
                const m = text().match(new RegExp("^\\s*" + key + "\\s*=\\s*\"([^\"]*)\"", "m"));
                return m ? m[1] : "";
            };
            root.tint = get("aura_tint") || "accent";
            root.profileStyle = get("aura_style");
        }
        onLoadFailed: {
            root.tint = "accent";
            root.profileStyle = "";
        }
    }

    // The current state and settings once, then every event as it comes.
    Process {
        id: snapshot
        command: [root.bin, "status", "--json"]
        running: root.testState === ""
        stdout: StdioCollector {
            onStreamFinished: {
                let s;
                try {
                    s = JSON.parse(text);
                } catch (err) {
                    return;
                }
                const d = s.data || s;
                if (d.running_settings)
                    root.handleEvent({ type: "settings", running: d.running_settings });
                if (d.state)
                    root.handleEvent({ type: "state", state: d.state, at_ms: d.snapshot_at_ms || 0 });
                if (d.session)
                    root.handleEvent({ type: "session", mode: d.session.mode, remaining_secs: d.session.remaining_secs });
                if (d.pending_approvals && Object.keys(d.pending_approvals).length > 0)
                    root.setState("attention");
            }
        }
    }
    Process {
        id: events
        command: [root.bin, "listen"]
        running: root.testState === ""
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                root.retryMs = 2000;
                root.handle(data);
            }
        }
        onRunningChanged: {
            if (!running && root.testState === "") {
                root.daemonState = "offline";
                root.conversation = false;
                root.setState("idle");
                root.level = 0;
                root.levelTarget = 0;
                restart.interval = root.retryMs;
                root.retryMs = Math.min(root.retryMs * 2, 30000);
                restart.restart();
            } else {
                snapshot.running = true;
            }
        }
    }
    Timer {
        id: restart
        interval: 2000
        onTriggered: events.running = true
    }

    ShellComponent {
        componentId: "assistant-aura"
        overlays: ["assistant-aura"]
    }
    function registerOverlay() {
        ShellCore.request("RegisterOverlay", { policy: { id: "assistant-aura", category: "presentation", keyboard: "none", fullscreen: "hide", placement: "all" } }, (ok, err) => {
            if (err)
                console.warn("nyx-assistant aura:", err.code, err.msg);
            else
                ShellCore.showOverlay("assistant-aura");
        });
    }
    Connections {
        target: ShellCore
        function onReconnected() {
            root.registerOverlay();
        }
    }

    // The screens it shows on (GTK's choice): the ones listed, else every screen, the
    // primary one (as set, else the one at the layout's origin, else the built-in panel),
    // or the active one. Never a virtual (headless) output.
    readonly property string pinnedScreen: Quickshell.env("NYX_SHELL_SCREEN") || ""
    readonly property var physical: {
        const preferred = ui.aura_primary_monitor || "";
        const rank = s => !s ? 4 : preferred !== "" && s.name === preferred ? 0 : (s.x === 0 && s.y === 0) ? 1 : s.name.indexOf("eDP") === 0 ? 2 : 3;
        return Quickshell.screens.filter(s => s.name.indexOf("HEADLESS-") !== 0).sort((a, b) => rank(a) - rank(b) || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0)).map(s => s.name);
    }
    function onScreen(screen) {
        if (pinnedScreen !== "")
            return screen.name === pinnedScreen;
        if (screen.name.indexOf("HEADLESS-") === 0)
            return false;
        const list = ui.aura_monitors || [];
        if (list.length > 0)
            return list.indexOf(screen.name) >= 0;
        const mode = ui.aura_monitor_mode || "active";
        if (mode === "all")
            return true;
        if (mode === "primary") {
            const p = ui.aura_primary_monitor || "";
            return screen.name === (physical.indexOf(p) >= 0 ? p : physical[0]);
        }
        const active = DesktopState.activeMonitorName;
        return screen.name === (physical.indexOf(active) >= 0 ? active : physical[0]);
    }

    // One of Edge Flow's strokes, `times` the line's width, along `shape`'s path.
    component FlowPath: ShapePath {
        required property real times
        required property real alpha
        required property var shape
        readonly property real lw: (root.ui.aura_thickness || 3) * times * (1 + 1.8 * shape.audio)
        strokeColor: Qt.rgba(root.glowColor.r, root.glowColor.g, root.glowColor.b, Math.min(1, alpha * shape.strength))
        strokeWidth: lw
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        strokeStyle: ShapePath.DashLine
        dashPattern: [shape.segment / lw, shape.length / lw]
        dashOffset: ((shape.segment + shape.length) - shape.travel * (shape.length - shape.segment)) / lw
        startX: shape.leftX
        startY: shape.topY
        PathLine {
            x: shape.leftX
            y: shape.bottomY - shape.r
        }
        PathArc {
            x: shape.leftX + shape.r
            y: shape.bottomY
            radiusX: shape.r
            radiusY: shape.r
            direction: PathArc.Counterclockwise
        }
        PathLine {
            x: shape.rightX - shape.r
            y: shape.bottomY
        }
        PathArc {
            x: shape.rightX
            y: shape.bottomY - shape.r
            radiusX: shape.r
            radiusY: shape.r
            direction: PathArc.Counterclockwise
        }
        PathLine {
            x: shape.rightX
            y: shape.topY
        }
    }

    MonitorSurfaces {
        componentId: "assistant-aura"
        delegate: PanelWindow {
            id: win
            required property var modelData
            screen: modelData
            visible: root.drawing && root.onScreen(modelData) && !DesktopState.fullscreenOn(modelData.name)
            color: "transparent"
            anchors.top: true
            anchors.bottom: true
            anchors.left: true
            anchors.right: true
            // Inside the bars' reserved space, so the glow never covers a bar.
            exclusionMode: ExclusionMode.Normal
            exclusiveZone: 0
            mask: Region {}
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.namespace: "nyx-assistant-aura"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            Item {
                id: glow
                anchors.fill: parent
                opacity: root.fade

                readonly property real thick: root.ui.aura_thickness || 3
                readonly property real pad: thick + 2
                // Even the widest glow and round caps stay clear of the bar above.
                readonly property real topY: pad + thick * 5.5
                readonly property real bottomY: height - pad
                readonly property real radius: 18
                readonly property bool fits: topY + radius < bottomY && width > 2 * (pad + radius)

                // Full Aura: soft light up both sides, wider and brighter with the voice.
                Item {
                    id: full
                    anchors.fill: parent
                    visible: root.style === "full" && glow.fits
                    readonly property real pulse: root.ui.aura_audio_reactive !== false && (root.shown === "listening" || root.shown === "speaking") && !root.reducedMotion ? Math.max(0, Math.min(1, root.level)) : 0
                    readonly property real reach: Math.min((24 + glow.thick * 7) * (1 + 2 * pulse), width * 0.18)
                    readonly property real strength: Math.min(1, root.intensity * root.breath * (1 + 0.55 * pulse))

                    Repeater {
                        model: full.visible ? 2 : 0
                        Canvas {
                            id: side
                            required property int index
                            x: index === 0 ? 0 : full.width - width
                            y: glow.topY
                            width: Math.max(1, Math.ceil(full.reach))
                            height: Math.max(1, full.height - glow.topY)
                            opacity: full.strength
                            readonly property color c: root.glowColor
                            onCChanged: requestPaint()
                            onWidthChanged: requestPaint()
                            onHeightChanged: requestPaint()
                            onPaint: {
                                const g = getContext("2d");
                                g.reset();
                                const w = width, h = height;
                                const edge = index === 0 ? 0 : w, inner = index === 0 ? w : 0;
                                const across = g.createLinearGradient(edge, 0, inner, 0);
                                for (const [stop, alpha] of [[0, 0.76], [0.08, 0.66], [0.25, 0.38], [0.55, 0.12], [1, 0]])
                                    across.addColorStop(stop, Qt.rgba(c.r, c.g, c.b, alpha));
                                g.fillStyle = across;
                                g.fillRect(0, 0, w, h);
                                // Faded in at the top and out at the bottom.
                                const f = Math.min(24 / h, 0.25);
                                const along = g.createLinearGradient(0, 0, 0, h);
                                along.addColorStop(0, Qt.rgba(0, 0, 0, 0));
                                along.addColorStop(f, Qt.rgba(0, 0, 0, 1));
                                along.addColorStop(1 - f, Qt.rgba(0, 0, 0, 1));
                                along.addColorStop(1, Qt.rgba(0, 0, 0, 0));
                                g.globalCompositeOperation = "destination-in";
                                g.fillStyle = along;
                                g.fillRect(0, 0, w, h);
                            }
                        }
                    }
                }

                // Edge Flow: a bright segment going down one side, along the bottom, up the
                // other and back, in four strokes from a wide soft glow to the line itself.
                Shape {
                    id: flow
                    anchors.fill: parent
                    visible: root.style !== "full" && glow.fits
                    preferredRendererType: Shape.CurveRenderer
                    readonly property real leftX: glow.pad
                    readonly property real rightX: width - glow.pad
                    readonly property real topY: glow.topY
                    readonly property real bottomY: glow.bottomY
                    readonly property real r: glow.radius
                    readonly property real length: 2 * (glow.bottomY - r - glow.topY) + (rightX - leftX - 2 * r) + Math.PI * r
                    readonly property real segment: length * (root.ui.aura_segment_length || 0.14)
                    readonly property real audio: root.ui.aura_audio_reactive !== false ? Math.max(0, Math.min(1, root.level)) * 0.65 : 0
                    readonly property real strength: root.intensity * (root.breath + audio)
                    // 0 at the start of the path, 1 at its end, eased at both.
                    readonly property real travel: root.reducedMotion ? 0.5 : (1 - Math.cos(root.phase * 2 * Math.PI)) * 0.5

                    FlowPath {
                        shape: flow
                        times: 5
                        alpha: 0.045
                    }
                    FlowPath {
                        shape: flow
                        times: 3
                        alpha: 0.11
                    }
                    FlowPath {
                        shape: flow
                        times: 1.5
                        alpha: 0.24
                    }
                    FlowPath {
                        shape: flow
                        times: 1
                        alpha: 0.64
                    }
                }
            }
        }
    }
}
