import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// The state the overview is in, and the two ways it gets there.
//
// `t` is the whole animation: 0 is the desktop as it is, 1 is the overview
// fully open, and every thumbnail's position, size and opacity is a blend of
// the two at `t`. A keypress animates it; a trackpad swipe *sets* it, frame by
// frame, which is why the gesture feels attached to your fingers rather than
// like a button that plays a video.
//
// Hyprland drives the gesture end: app/gesture.lua registers a three-finger
// gesture whose update callback emits a fraction on the event socket, which
// arrives here as a custom event. No compositor plugin, no daemon, nothing to
// rebuild when Hyprland updates.
Item {
  id: service

  property var shell: null
  property var manifest: null

  // 0 = closed, 1 = open. Anything between is a swipe in progress.
  property real t: 0
  // Not "visible": Item declares that FINAL, and shadowing it stops the whole
  // plugin loading with "Cannot override FINAL property".
  readonly property bool showing: t > 0.001
  // True once the user has committed: clicks land, keys are grabbed.
  // With a hysteresis: the spring lands with a bounce, and an overview that
  // dipped to 0.98 on the rebound must not drop the keyboard and grab it
  // again — or swap what three fingers sideways mean — on the way.
  property bool open: false
  onTChanged: {
    if (service.t > 0.995) service.open = true
    else if (service.t < 0.9) service.open = false
  }

  // Where the fingers have put the overview, which `t` chases. Decisions —
  // open or not, when they lift — are made on this, not on the spring lagging
  // behind it.
  property real goal: 0

  // Which monitor the overview belongs to — the one the pointer was on.
  property string monitorName: ""

  // Which gesture currently owns `t`: "", "up", "down", "allup" or "alldown".
  property string scrub: ""
  // Three fingers shows this workspace; four shows every window there is.
  property bool everything: false
  // Where `t` was when the fingers landed, so a gesture continues from what is
  // on screen instead of snapping to an end first.
  property real scrubFrom: 0

  readonly property int fingers: 3

  // "Get ready" — raised before `t` leaves zero, so the overlay can take its
  // snapshot of the windows on a frame where nothing is moving yet.
  signal arming()

  // Three fingers sideways while the overview is open. The overlay owns the
  // workspaces, so it decides what a sideways swipe means; this only relays it.
  // `phase` is "begin", "move" or "end"; `value` is how many workspaces the
  // fingers have travelled, positive toward the next; `velocity` is the same
  // per second.
  signal sideSwipe(string phase, real value, real velocity, bool cancelled)

  // ---------------------------------------------------------------- opening

  function aim() {
    service.monitorName = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
  }

  // Ask the compositor what is really there. Quickshell's model is filled from
  // events, and a window that opened while nothing was watching has no
  // geometry and the wrong workspace — which is an empty overview.
  function refreshModels() {
    Hyprland.refreshMonitors()
    Hyprland.refreshWorkspaces()
    Hyprland.refreshToplevels()
  }

  function show() {
    service.aim()
    service.arming()
    service.refreshModels()
    // Let the answers arrive before the thumbnails start flying, or they fly
    // from nowhere. Short enough to be invisible, long enough for one round
    // trip; the gesture skips it because at the start of a swipe the
    // thumbnails are still sitting exactly on top of their windows.
    settle.restart()
  }

  Timer {
    id: settle
    interval: 70
    onTriggered: service.glideTo(true, 0)
  }

  function hide() {
    settle.stop()
    service.scrub = ""
    service.glideTo(false, 0)
  }

  // Past fully open the overview gives a little rather than stopping dead
  // under the fingers, and settles back when they lift.
  readonly property real stretch: 0.05
  function rubber(value) {
    if (value <= 1) return value
    return 1 + service.stretch * (1 - Math.exp(-(value - 1) / service.stretch))
  }

  function toggle() { service.goal > 0.5 ? service.hide() : service.show() }

  // How the spring feels. Following the fingers it is tight, so it trails
  // them by a hair and settles with a small give when they stop; let go, it
  // loosens, and lands with a visible bounce.
  readonly property real followStiffness: 32
  readonly property real followDamping: 0.78
  readonly property real landStiffness: 17
  readonly property real landDamping: 0.66

  // Head for open or closed. The spring already has whatever speed the
  // fingers gave it, so letting go is only a change of target; `velocity` (in
  // `t` per second) tops that up when the fingers were faster than the spring
  // had caught up to — a flick — and only in the direction it is going.
  function glideTo(wantOpen, speed, velocity) {
    const target = wantOpen ? 1 : 0
    service.goal = target
    if (!tSpring.running) tSpring.value = service.t
    tSpring.stiffness = service.landStiffness
    tSpring.damping = service.landDamping
    const way = Math.sign(target - tSpring.value)
    if (velocity !== undefined && way !== 0 && Math.sign(velocity) === way
        && Math.abs(velocity) > Math.abs(tSpring.velocity)) {
      tSpring.velocity = velocity
    }
    tSpring.follow(target)
  }

  // Fingers down: from here the spring chases them.
  function grab() {
    if (!tSpring.running) {
      tSpring.value = service.t
      tSpring.velocity = 0
    }
    tSpring.stiffness = service.followStiffness
    tSpring.damping = service.followDamping
    service.goal = service.t
  }

  Spring {
    id: tSpring
    floor: 0
    onValueChanged: service.t = tSpring.value
  }

  // ---------------------------------------------------------------- the swipe

  readonly property string gestureFile: {
    const url = Qt.resolvedUrl("../app/gesture.lua").toString()
    return url.startsWith("file://") ? url.slice(7) : url
  }

  Process {
    id: lua
    // Registering the gestures resets nothing sideways, but a fresh Lua state
    // after a config reload has nothing registered at all: say it again.
    onRunningChanged: if (!running) {
      service.sidewaysSent = ""
      service.sendSideways()
    }
  }

  // The desktop's own wallpaper, which the overview sits on and every workspace
  // tile is a small picture of. Omarchy keeps it behind a symlink that moves
  // when the theme changes, so resolve it rather than remember it — but never
  // while a swipe is running: this looks it up at startup and whenever the
  // overview closes, so it is already known by the time one opens.
  property string wallpaper: ""

  // Resolved in QML rather than by a shell, and `readlink` by absolute path:
  // a plugin runs unsandboxed, so it should not be spawning shells to expand a
  // variable it can read itself.
  readonly property string backgroundLink: {
    const state = String(Quickshell.env("XDG_STATE_HOME") || "")
    const home = String(Quickshell.env("HOME") || "")
    const base = state !== "" ? state : (home !== "" ? home + "/.local/state" : "")
    return base === "" ? "" : base + "/omarchy/current/background"
  }

  Process {
    id: findWallpaper
    command: ["/usr/bin/readlink", "-f", service.backgroundLink]
    stdout: StdioCollector {
      onStreamFinished: {
        const path = text.trim()
        // Only ever a path the compositor's own theme points at, and only used
        // as an image source.
        if (path.startsWith("/")) service.wallpaper = path
      }
    }
  }

  function findTheWallpaper() {
    if (service.backgroundLink === "" || findWallpaper.running) return
    findWallpaper.running = true
  }

  onShowingChanged: {
    if (service.showing) return
    service.findTheWallpaper()
    // Reset once it is fully away, not while it is still closing, or the
    // spread rearranges itself on the way out.
    service.everything = false
  }

  // ------------------------------------------------------------ decoration

  // How Hyprland dresses a window: its rounding, border and shadow. At the
  // start of a swipe every card sits exactly on top of its window, and the
  // desktop behind has already been painted over, so a card has to look like
  // the window it stands in for — not like a square screenshot of its
  // contents — or the first frame of every swipe is a visible jump.
  property var deco: ({
    rounding: 0,
    border: 0,
    activeBorder: "transparent",
    inactiveBorder: "transparent",
    shadow: false,
    shadowRange: 0,
    shadowColor: "transparent",
    shadowColorInactive: "transparent",
  })

  readonly property var decoOptions: [
    "decoration:rounding", "general:border_size",
    "general:col.active_border", "general:col.inactive_border",
    "decoration:shadow:enabled", "decoration:shadow:range",
    "decoration:shadow:color", "decoration:shadow:color_inactive",
  ]

  Process {
    id: readDeco
    command: ["/usr/bin/hyprctl", "--batch",
              service.decoOptions.map(o => "j/getoption " + o).join("; ")]
    stdout: StdioCollector {
      onStreamFinished: service.takeDeco(text)
    }
  }

  // Hyprland prints colours as AARRGGBB, which is what Qt reads after a "#".
  // A gradient is a list of them and an angle; the first colour stands for it.
  function colourOf(entry) {
    const raw = entry && (entry.gradient || entry.color || entry.str)
    const hex = String(raw || "").trim().split(/\s+/)[0]
    return /^[0-9a-fA-F]{8}$/.test(hex) ? "#" + hex : "transparent"
  }

  function takeDeco(text) {
    const byName = ({})
    for (const chunk of String(text).split(/\n\s*\n/)) {
      try {
        const entry = JSON.parse(chunk)
        if (entry && entry.option) byName[entry.option] = entry
      } catch (e) {}
    }
    const num = name => {
      const e = byName[name]
      return e ? Number(e.int !== undefined ? e.int : (e.float !== undefined ? e.float : 0)) : 0
    }
    const shadowOn = byName["decoration:shadow:enabled"]
    service.deco = {
      rounding: Math.max(0, num("decoration:rounding")),
      border: Math.max(0, num("general:border_size")),
      activeBorder: service.colourOf(byName["general:col.active_border"]),
      inactiveBorder: service.colourOf(byName["general:col.inactive_border"]),
      shadow: !!(shadowOn && (shadowOn.bool === true || shadowOn.int === 1)),
      shadowRange: Math.max(0, num("decoration:shadow:range")),
      shadowColor: service.colourOf(byName["decoration:shadow:color"]),
      shadowColorInactive: service.colourOf(byName["decoration:shadow:color_inactive"]
                                            || byName["decoration:shadow:color"]),
    }
  }

  function readDecoration() {
    if (!readDeco.running) readDeco.running = true
  }

  function registerGesture() {
    const path = service.gestureFile.replace(/\\/g, "\\\\").replace(/"/g, '\\"')
    lua.command = ["/usr/bin/hyprctl", "eval", 'dofile("' + path + '")']
    lua.running = true
  }

  // Three fingers sideways: Hyprland's workspace swipe while the overview is
  // closed, sliding the spread between workspaces while it is open. Set to
  // false to leave sideways swipes alone while it is closed.
  readonly property bool nativeWorkspaceSwipe: true

  readonly property string sideways: service.open ? "slide"
                                   : (!service.showing && service.nativeWorkspaceSwipe ? "workspace" : "")
  property string sidewaysSent: ""

  // In an eval of its own, after the gestures exist: if the user already has
  // a horizontal swipe, Hyprland refuses ours and that refusal must not take
  // the up and down gestures with it.
  Process {
    id: sidewaysLua
    onRunningChanged: if (!running && service.sidewaysSent !== service.sideways) service.sendSideways()
  }

  function sendSideways() {
    if (lua.running || sidewaysLua.running) return
    const mode = service.sideways
    if (mode === "") return   // in between: keep whatever is there
    service.sidewaysSent = mode
    sidewaysLua.command = ["/usr/bin/hyprctl", "eval", '__aerial_horizontal("' + mode + '")']
    sidewaysLua.running = true
  }

  onSidewaysChanged: service.sendSideways()

  // A swipe shorter than this cannot open the overview however fast it was:
  // a flick has to be deliberate, not a brush against the pad.
  readonly property real flickFloor: 0.08
  // Travel per millisecond, as the Lua half measures it.
  readonly property real flickSpeed: 2.0

  /** Was that swipe thrown rather than dragged? */
  function flicked(fraction, speed) {
    return speed >= service.flickSpeed && fraction >= service.flickFloor
  }

  // What the Lua half sends, one fraction at a time.
  function onGesture(data) {
    const cut = data.indexOf(":")
    const what = cut < 0 ? data : data.slice(0, cut)
    const rest = cut < 0 ? "" : data.slice(cut + 1)
    const parts = rest.split(":")
    const raw = parseFloat(parts[0]) || 0
    const value = Math.max(0, raw)
    const speed = parseFloat(parts[1]) || 0
    const cancelled = parts[2] === "1"
    // Along the swipe, in progress per second. Older gesture halves did not
    // send it, and then there is nothing to carry on from.
    const velocity = parts.length > 3 ? (parseFloat(parts[3]) || 0) : undefined

    if (what === "shape") {
      // Only ever sent when the Lua half could not find the movement in what
      // Hyprland gave it, which means this plugin needs updating.
      console.warn("aerial: cannot read the swipe — Hyprland's gesture payload is now " + rest)
      return
    }

    // "allup-move" is the four-finger version of "up-move", and so on.
    const dash = what.lastIndexOf("-")
    if (dash < 0) return
    const who = what.slice(0, dash)
    const phase = what.slice(dash + 1)

    if (who === "side") {
      // Only means anything with the overview open; otherwise Hyprland's own
      // workspace swipe has it, and this is a stray from a gesture that began
      // just as it closed.
      if (phase === "begin" && !service.open) {
        // And if it reached us at all, Hyprland thinks the slide is still
        // ours — a shell restarted mid-reload can leave it that way. Hand the
        // swipe back so the next one switches workspaces again.
        if (!service.showing) {
          service.sidewaysSent = ""
          service.sendSideways()
        }
        return
      }
      service.sideSwipe(phase, raw, velocity || 0, cancelled)
      return
    }
    const opening = who === "up" || who === "allup"
    const wantsEverything = who === "allup" || who === "alldown"

    switch (phase) {
    case "begin":
      if (opening) {
        if (service.open) return
        service.everything = wantsEverything
        service.aim()
        service.arming()
        // The snapshot above is what the cards are built from; where each
        // window really is right now arrives a few milliseconds later and the
        // cards follow it, so a window resized since the last event starts
        // the swipe at its true size.
        service.refreshModels()
      } else {
        // Swiping down puts the overview away from anywhere it is visible,
        // including halfway through opening. On the bare desktop the gesture
        // belongs to whoever else wants it.
        if (service.t < 0.05) return
      }
      settle.stop()
      service.grab()
      service.scrubFrom = service.t
      service.scrub = who
      break

    case "move":
      if (service.scrub !== who) return
      service.goal = opening
        ? service.rubber(service.scrubFrom + (1 - service.scrubFrom) * value)
        : service.scrubFrom * (1 - Math.min(1, value))
      tSpring.follow(service.goal)
      break

    case "end":
      if (service.scrub !== who) return
      service.scrub = ""
      // Judged on where it ended up, not on the swipe alone, so a gesture that
      // carried on from a half-open overview is measured from what you saw.
      //
      // The speed carried into the glide is the fingers' speed turned into
      // `t`'s, and only when it points where the overview is going: flicked
      // open and let go it keeps moving, but a swipe that reverses and gets
      // dropped does not fling the overview the wrong way first.
      {
        let wantOpen
        if (cancelled) wantOpen = service.goal > 0.5
        else if (opening) wantOpen = service.goal > 0.5 || service.flicked(value, speed)
        else wantOpen = !(service.goal < 0.5 || service.flicked(value, speed))

        let carry = undefined
        if (velocity !== undefined && !cancelled) {
          const scale = opening ? (1 - service.scrubFrom) : -service.scrubFrom
          carry = velocity * scale
          if ((wantOpen ? 1 : -1) * carry < 0) carry = 0
          carry = Math.max(-12, Math.min(12, carry))
        }
        service.glideTo(wantOpen, speed, carry)
      }
      break

    default:
      return
    }

    watchdog.restart()
  }

  // A gesture that stops sending without a lift — a reload mid-swipe, a
  // compositor restart — must not strand the overview at 40%. Hyprland does
  // report the lift, so this is a net and nothing more: at 450ms it was firing
  // during ordinary pauses and snapping the animation out from under the hand.
  Timer {
    id: watchdog
    interval: 1400
    onTriggered: {
      if (service.scrub === "") return
      const wasMostlyOpen = service.goal > 0.5
      service.scrub = ""
      service.glideTo(wasMostlyOpen, 0)
    }
  }

  // ---------------------------------------------------------------- listening

  // Events that change what the overview would show. Refreshing on these keeps
  // the model warm, so opening never has to wait for the compositor to answer.
  readonly property var stirring: [
    "openwindow", "closewindow", "movewindow", "movewindowv2",
    "workspace", "workspacev2", "createworkspace", "createworkspacev2",
    "destroyworkspace", "destroyworkspacev2", "fullscreen",
    "changefloatingmode", "focusedmon", "monitoraddedv2", "monitorremoved",
  ]

  Connections {
    target: Hyprland

    function onRawEvent(event) {
      const name = event.name || ""

      if (name === "configreloaded") {
        // A reload drops runtime gestures the same way it drops runtime binds.
        rearm.restart()
        service.readDecoration()
        return
      }

      // hl.dsp.event("aerial,…") arrives as custom>>aerial,…
      const data = event.data || ""
      if (name === "aerial") {
        service.onGesture(data)
        return
      }
      if (name === "custom" && data.startsWith("aerial,")) {
        service.onGesture(data.slice(7))
        return
      }

      if (service.stirring.indexOf(name) >= 0) freshen.restart()
    }
  }

  Timer {
    id: freshen
    interval: 180
    onTriggered: service.refreshModels()
  }

  Timer {
    id: rearm
    interval: 600
    onTriggered: service.registerGesture()
  }

  Component.onCompleted: {
    service.registerGesture()
    service.findTheWallpaper()
    service.readDecoration()
  }
}
