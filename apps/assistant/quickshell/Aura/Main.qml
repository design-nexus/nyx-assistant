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
// speaking or the model.
//
// - Full Aura: soft light up both sides; Edge Flow: a bright segment travelling round the
//   edge. `[ui] aura_style`.
// - Persistent: faint while idle, full while busy; activity: only while busy, fading
//   out shortly after. `[ui] aura_visibility`.
// - Reduced motion (`[ui] aura_reduce_motion`, or the system's): still light, no movement.
// - A Shell Core `presentation` overlay: never takes the keyboard or input, hidden while
//   the session is locked and over fullscreen windows, on the screens `[ui]
//   aura_monitor_mode` names.
Scope {
    id: root

    // What the daemon says. `offline` when it isn't running: then nothing shows.
    property string state: "offline"
    property bool conversation: false
    property bool attention: false
    property real level: 0
    property var ui: ({ enabled: true, aura_enabled: true, aura_style: "full", aura_visibility: "persistent", aura_intensity: 0.4, aura_thickness: 3, aura_speed: 1, aura_segment_length: 0.14, aura_audio_reactive: true, aura_reduce_motion: "system", aura_monitor_mode: "active", aura_primary_monitor: "", aura_monitors: [], aura_renderer: "gtk" })

    readonly property string bin: (Quickshell.env("HOME") || "") + "/.local/bin/nyx-assistant"
    // Tests: a fixed state (and style), without the daemon.
    readonly property string testState: Quickshell.env("NYX_AURA_TEST_STATE") || ""
    Component.onCompleted: {
        if (testState !== "") {
            state = testState;
            const style = Quickshell.env("NYX_AURA_TEST_STYLE");
            if (style)
                ui = Object.assign({}, ui, { aura_style: style, aura_monitor_mode: "all" });
        }
        if (ShellCore.ready)
            registerOverlay();
    }
    readonly property bool busy: state !== "idle" && state !== "offline"
    readonly property bool reducedMotion: ui.aura_reduce_motion === "on" || (ui.aura_reduce_motion === "system" && NyxTheme.motion.reduced === true)
    readonly property var overlayState: ShellCore.overlay("assistant-aura")
    readonly property bool allowed: overlayState === null || overlayState.visible || testState !== ""
    // Brief visibility: busy, or just finished.
    property bool lingering: false
    readonly property real presence: {
        if (state === "offline" || !ui.enabled || !ui.aura_enabled || !allowed)
            return 0;
        // nyx-assistant-visual draws it unless `[ui] aura_renderer = "quickshell"`.
        if (ui.aura_renderer !== "quickshell" && testState === "")
            return 0;
        if (busy || attention || lingering)
            return 1;
        return ui.aura_visibility === "persistent" ? 0.2 : 0;
    }

    readonly property color tone: {
        const c = NyxTheme.colors;
        if (attention)
            return c.status.warning;
        switch (state) {
        case "listening":
        case "transcribing":
            return c.accent.primary;
        case "activating":
        case "thinking":
            return Qt.lighter(c.accent.primary, 1.25);
        case "executing":
            return c.status.warning;
        case "speaking":
            return c.status.success;
        case "error":
            return c.status.error;
        case "unavailable":
            return c.text.secondary;
        default:
            return c.accent.primary;
        }
    }

    onBusyChanged: {
        if (!busy) {
            lingering = true;
            linger.restart();
        }
    }
    Timer {
        id: linger
        interval: 1400
        onTriggered: root.lingering = false
    }

    function handle(line) {
        let e;
        try {
            e = JSON.parse(line);
        } catch (err) {
            return;
        }
        switch (e.type) {
        case "state":
            root.state = e.state || "idle";
            if (root.state === "idle" || root.state === "listening")
                root.attention = false;
            break;
        case "session":
            root.conversation = (e.mode === "conversation" || e.mode === "follow_up") && (e.remaining_secs || 0) > 0;
            break;
        case "level":
        case "playback_level":
            if (ui.aura_audio_reactive)
                root.level = Math.max(0, Math.min(1, (20 * Math.log10(Math.max(e.rms || 0, 1e-6)) + 48) / 36));
            break;
        case "tool_approval":
        case "proactive":
            root.attention = true;
            break;
        case "settings":
            if (e.running && e.running.ui)
                root.ui = Object.assign({}, root.ui, e.running.ui);
            break;
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
                if (d.running_settings && d.running_settings.ui)
                    root.ui = Object.assign({}, root.ui, d.running_settings.ui);
                if (d.state)
                    root.state = d.state;
            }
        }
    }
    Process {
        id: events
        command: [root.bin, "listen"]
        running: root.testState === ""
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => root.handle(data)
        }
        onRunningChanged: {
            if (!running && root.testState === "") {
                root.state = "offline";
                root.level = 0;
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
    Timer {
        interval: 120
        running: root.level > 0
        repeat: true
        onTriggered: root.level = Math.max(0, root.level - 0.08)
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

    function onScreen(screen) {
        const mode = ui.aura_monitor_mode || "active";
        if (mode === "all")
            return true;
        if (mode === "primary")
            return screen.name === (ui.aura_primary_monitor || DesktopState.activeMonitorName);
        if (mode === "list")
            return (ui.aura_monitors || []).indexOf(screen.name) >= 0;
        return screen.name === DesktopState.activeMonitorName || Quickshell.env("NYX_SHELL_SCREEN") === screen.name;
    }

    MonitorSurfaces {
        componentId: "assistant-aura"
        delegate: PanelWindow {
            id: win
            required property var modelData
            screen: modelData
            visible: root.onScreen(modelData) && glow.opacity > 0.005
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
                opacity: root.presence * Math.min(1, root.ui.aura_intensity * 2.5)
                Behavior on opacity {
                    NumberAnimation {
                        duration: root.reducedMotion ? 0 : 320
                    }
                }

                readonly property real thick: root.ui.aura_thickness || 3
                readonly property real pulse: root.reducedMotion ? 0 : root.level
                readonly property real reach: Math.min(width * 0.18, (24 + thick * 7) * (1 + 2 * pulse))

                // Full Aura: soft light up both sides.
                Repeater {
                    model: root.ui.aura_style === "edge-flow" ? 0 : 2
                    Rectangle {
                        required property int index
                        y: 0
                        height: glow.height
                        width: glow.reach
                        x: index === 0 ? 0 : glow.width - width
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop {
                                position: 0
                                color: Qt.rgba(root.tone.r, root.tone.g, root.tone.b, index === 0 ? 0.76 : 0)
                            }
                            GradientStop {
                                position: 0.5
                                color: Qt.rgba(root.tone.r, root.tone.g, root.tone.b, 0.2)
                            }
                            GradientStop {
                                position: 1
                                color: Qt.rgba(root.tone.r, root.tone.g, root.tone.b, index === 0 ? 0 : 0.76)
                            }
                        }
                    }
                }

                // Edge Flow: a bright segment travelling round the edge.
                Shape {
                    id: flow
                    visible: root.ui.aura_style === "edge-flow"
                    anchors.fill: parent
                    anchors.margins: 6
                    preferredRendererType: Shape.CurveRenderer
                    readonly property real perimeter: 2 * (width + height)
                    readonly property real lineWidth: glow.thick * (1 + 1.8 * glow.pulse)
                    readonly property real segment: Math.max(40, perimeter * (root.ui.aura_segment_length || 0.14))
                    property real travel: 0
                    NumberAnimation on travel {
                        running: flow.visible && !root.reducedMotion && root.presence > 0
                        from: 0
                        to: flow.perimeter
                        duration: Math.max(1500, 9000 / Math.max(0.2, root.ui.aura_speed || 1) * (root.state === "thinking" || root.state === "activating" ? 0.65 : 1))
                        loops: Animation.Infinite
                    }
                    // Soft light round the line, as the GTK Aura draws it.
                    ShapePath {
                        strokeColor: Qt.rgba(root.tone.r, root.tone.g, root.tone.b, 0.045)
                        strokeWidth: flow.lineWidth * 5
                        fillColor: "transparent"
                        capStyle: ShapePath.RoundCap
                        strokeStyle: ShapePath.DashLine
                        dashPattern: [flow.segment / (flow.lineWidth * 5), (flow.perimeter - flow.segment) / (flow.lineWidth * 5)]
                        dashOffset: (root.reducedMotion ? flow.perimeter / 2 : flow.travel) / (flow.lineWidth * 5)
                        PathRectangle {
                            x: 0
                            y: 0
                            width: flow.width
                            height: flow.height
                            radius: 18
                        }
                    }
                    ShapePath {
                        strokeColor: Qt.rgba(root.tone.r, root.tone.g, root.tone.b, 0.11)
                        strokeWidth: flow.lineWidth * 3
                        fillColor: "transparent"
                        capStyle: ShapePath.RoundCap
                        strokeStyle: ShapePath.DashLine
                        dashPattern: [flow.segment / (flow.lineWidth * 3), (flow.perimeter - flow.segment) / (flow.lineWidth * 3)]
                        dashOffset: (root.reducedMotion ? flow.perimeter / 2 : flow.travel) / (flow.lineWidth * 3)
                        PathRectangle {
                            x: 0
                            y: 0
                            width: flow.width
                            height: flow.height
                            radius: 18
                        }
                    }
                    ShapePath {
                        strokeColor: Qt.rgba(root.tone.r, root.tone.g, root.tone.b, 0.24)
                        strokeWidth: flow.lineWidth * 1.5
                        fillColor: "transparent"
                        capStyle: ShapePath.RoundCap
                        strokeStyle: ShapePath.DashLine
                        dashPattern: [flow.segment / (flow.lineWidth * 1.5), (flow.perimeter - flow.segment) / (flow.lineWidth * 1.5)]
                        dashOffset: (root.reducedMotion ? flow.perimeter / 2 : flow.travel) / (flow.lineWidth * 1.5)
                        PathRectangle {
                            x: 0
                            y: 0
                            width: flow.width
                            height: flow.height
                            radius: 18
                        }
                    }
                    ShapePath {
                        strokeColor: root.tone
                        strokeWidth: flow.lineWidth
                        fillColor: "transparent"
                        capStyle: ShapePath.RoundCap
                        strokeStyle: ShapePath.DashLine
                        dashPattern: [flow.segment / flow.lineWidth, (flow.perimeter - flow.segment) / flow.lineWidth]
                        dashOffset: (root.reducedMotion ? flow.perimeter / 2 : flow.travel) / flow.lineWidth
                        PathRectangle {
                            x: 0
                            y: 0
                            width: flow.width
                            height: flow.height
                            radius: 18
                        }
                    }
                }
            }
        }
    }
}
