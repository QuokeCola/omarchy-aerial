import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Widgets
import qs.Commons
import "../app/Layout.js" as Layout

// One screen's worth of overview.
//
// Every monitor gets one of these, each spreading its own workspace's windows,
// because a second screen that merely dims while you are looking for a window
// on it is worse than no overview at all. The workspace strip belongs to the
// screen you were pointing at; the others are just their own windows.
PanelWindow {
  id: surface

  required property var overlay
  required property var screenInfo

  screen: surface.screenInfo
  visible: overlay.opened
  color: "transparent"
  WlrLayershell.namespace: "omarchy-aerial"
  WlrLayershell.layer: WlrLayer.Overlay
  exclusionMode: ExclusionMode.Ignore
  anchors { top: true; bottom: true; left: true; right: true }

  // Only the screen you swiped on grabs the keyboard; two surfaces both
  // claiming it exclusively is a fight nobody wins. And only once the overview
  // is actually open — a swipe still in progress must not take keys from the
  // window underneath.
  WlrLayershell.keyboardFocus: surface.leading && overlay.active
                               ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

  // A swipe in progress should not swallow clicks meant for the desktop.
  mask: overlay.active ? null : emptyRegion
  Region { id: emptyRegion }

  readonly property string monitorName: surface.screenInfo ? surface.screenInfo.name : ""
  readonly property var monitor: (Hyprland.monitors.values || []).find(m => m.name === surface.monitorName) || null
  readonly property bool leading: surface.monitorName === overlay.leadMonitor

  // How soft the wallpaper behind the spread is, 0 to 1. At 0 it is the
  // wallpaper itself, sharp, exactly as the desktop shows it.
  readonly property real blur: 0
  // How much it is darkened behind the spread, 0 to 1. At 0 it is not.
  readonly property real dim: 0

  // Frosted windows. A terminal drawn partly see-through, with the compositor
  // blurring what is behind it, captures as see-through and nothing more: the
  // blur is the compositor's, not the window's. So every card is backed by
  // Hyprland's own blur of whatever is behind it — computed here the way
  // Hyprland computes it, with its settings, so the glass does not change as
  // the window hands over to its card. See HyprBlur.qml.
  //
  // Live: redrawn whenever what it covers changes, which during a swipe is
  // every frame. A machine that struggles wants the `polish` branch.
  readonly property bool glass: overlay.deco.blur === true
  // Measured, not derived: against screenshots of Hyprland blurring a
  // floating terminal over a static scene, the port matches best — to within
  // one level of brightness — at twice the configured size. Everything else
  // it takes as configured.
  readonly property real blurScale: 2

  // A floating window's card is on screen, so the blur behind floating
  // windows — which includes the tiled ones — has to run.
  readonly property bool floatingShown: {
    if (!surface.glass) return false
    for (let i = 0; i < floatCards.count; i++) {
      const card = floatCards.itemAt(i)
      if (card && card.shown) return true
    }
    return false
  }

  // The part of the screen windows live in: all of it, less what the bar and
  // anything else exclusive has reserved. Hyprland reports that as
  // [left, top, right, bottom].
  readonly property var reserved: {
    const r = surface.monitor && surface.monitor.lastIpcObject ? surface.monitor.lastIpcObject.reserved : null
    // A list from C++, which is not a JS Array as far as isArray is concerned.
    if (!r || r.length !== 4) return [0, 0, 0, 0]
    return [Number(r[0]) || 0, Number(r[1]) || 0, Number(r[2]) || 0, Number(r[3]) || 0]
  }

  // Every card on screen has its first frame. Until then the desktop behind
  // must stay visible, or a window whose capture is late blinks out.
  readonly property bool captured: {
    for (const list of [tiledCards, floatCards]) {
      for (let i = 0; i < list.count; i++) {
        const card = list.itemAt(i)
        if (card && card.waiting) return false
      }
    }
    return true
  }

  readonly property real pixelRatio: surface.screenInfo && surface.screenInfo.devicePixelRatio > 0
                                     ? surface.screenInfo.devicePixelRatio : 1

  // Which workspace this screen is showing. Peeking at a tile swaps it without
  // going there.
  readonly property int shownWorkspace: {
    if (surface.leading && overlay.peek > 0) return overlay.peek
    if (surface.leading && overlay.stageWorkspace > 0) return overlay.stageWorkspace
    return surface.monitor && surface.monitor.activeWorkspace ? surface.monitor.activeWorkspace.id : -1
  }

  // Sliding between workspaces moves every desktop's spread sideways together,
  // so this screen is a window onto a row of them.
  readonly property bool sliding: surface.leading && overlay.moving
                                  && !overlay.everything && !surface.searching

  // Every window on this screen, whichever desktop it is on. This is what the
  // cards are built from, and it deliberately does not depend on which
  // workspace is being shown: a new array makes the Repeater throw away every
  // delegate and build new ones, and rebuilding a live capture is exactly the
  // hitch the snapshot above exists to avoid. Peeking used to do it on every
  // hover, which is why the strip felt slow and flashed the desktop you were
  // already on while the new captures caught up.
  readonly property var monitorWindows: {
    const out = []
    for (const win of overlay.shot) {
      if (win.monitor !== surface.monitorName) continue
      out.push(win)
    }
    return out
  }

  // The ones the spread is laid out from: this desktop's, or every one of them.
  // Typing is a search, not a filter. Asking "where is that terminal" and being
  // told only about this desktop is the wrong answer to the question -- the
  // window you cannot find is, almost by definition, not the one in front of
  // you. So the moment there is something to search for, every desktop is in
  // scope; clear the text and it narrows back to where you are.
  readonly property bool searching: !overlay.everything && overlay.filter !== ""

  readonly property var windows: {
    if (overlay.everything || surface.searching) return surface.monitorWindows
    const out = []
    for (const win of surface.monitorWindows) {
      if (win.workspace !== surface.shownWorkspace) continue
      out.push(win)
    }
    return out
  }

  // What the filter leaves standing. The card for a window that does not match
  // stays alive but steps out of the spread, so typing does not tear down and
  // rebuild a live capture on every keystroke.
  readonly property var shownWindows: surface.windows.filter(w => overlay.matches(w))

  // Everything on this screen that the filter leaves standing, whichever
  // desktop it is on. What the slots are laid out from.
  readonly property var matching: surface.monitorWindows.filter(w => overlay.matches(w))

  // Room for the workspace strip along the top, the way Mission Control does.
  readonly property real stripHeight: surface.leading ? Math.max(96, surface.height * 0.15) : 24
  readonly property real padding: 32

  // The strip is laid out from these and hit-tested from these, so a dragged
  // window lands on the tile it looks like it is over.
  readonly property real tileWidth: Math.max(96, surface.height * 0.15) * 0.92
  readonly property real tileHeight: surface.tileWidth * (surface.height / Math.max(1, surface.width))
  readonly property real tileGap: 16
  readonly property real tileTop: (surface.stripHeight - surface.tileHeight) / 2
  readonly property real tileLeft: {
    const count = overlay.workspaces.length
    const total = count * surface.tileWidth + Math.max(0, count - 1) * surface.tileGap
    return (surface.width - total) / 2
  }

  function tileX(index) { return surface.tileLeft + index * (surface.tileWidth + surface.tileGap) }

  /** Which workspace is under this point, or -1. Generous by a few pixels: a
   *  drop that looks like it is on a tile should count as one. */
  function workspaceAtPoint(px, py) {
    if (!surface.leading) return -1
    const slack = 10
    if (py < surface.tileTop - slack || py > surface.tileTop + surface.tileHeight + slack) return -1
    for (let i = 0; i < overlay.workspaces.length; i++) {
      const left = surface.tileX(i)
      if (px >= left - slack && px <= left + surface.tileWidth + slack) return overlay.workspaces[i].id
    }
    return -1
  }

  /** Which window's card is under this point, ignoring the one being dragged. */
  function cardAtPoint(px, py) {
    for (const win of surface.shownWindows) {
      const slot = surface.slots[win.key]
      if (!slot || win.key === overlay.dragKey) continue
      if (px >= slot.x && px <= slot.x + slot.w && py >= slot.y && py <= slot.y + slot.h) return win.key
    }
    return ""
  }

  readonly property var slots: {
    if (surface.matching.length === 0 || surface.width <= 0) return ({})
    const area = {
      width: surface.width - surface.padding * 2,
      height: surface.height - surface.stripHeight - surface.padding * 2,
    }
    const options = { gap: 26, rowGap: 62, maxScale: 0.78 }

    const byKey = ({})

    // While searching, the matches are one set and get one spread. Peeking lays
    // every desktop into this same area so switching between them is a
    // crossfade -- which is right until two desktops are on screen at once, and
    // then it stacks them on top of each other.
    if (surface.searching) {
      for (const slot of Layout.spread(surface.matching, area, options)) {
        byKey[slot.key] = {
          x: slot.x + surface.padding,
          y: slot.y + surface.stripHeight + surface.padding,
          w: slot.w,
          h: slot.h,
        }
      }
      return byKey
    }

    if (!overlay.everything) {
      // Every desktop is laid out, not just the one on screen, each into the
      // same area. A card is therefore already standing exactly where it will
      // be when you peek at its desktop, so peeking is a cross-fade and
      // nothing moves.
      //
      // That is not only tidier, it is the whole bug: a card that animates
      // into place travels from where the window really is, which crosses the
      // workspace strip, which takes the pointer's hover off the tile you are
      // pointing at, which cancels the peek, which sends the card back — and
      // round it goes. It also means this no longer depends on which desktop
      // is shown, so hovering the strip recomputes no layout at all.
      for (const group of Layout.groupBy(surface.matching, w => w.workspace)) {
        for (const slot of Layout.spread(group.windows, area, options)) {
          byKey[slot.key] = {
            x: slot.x + surface.padding,
            y: slot.y + surface.stripHeight + surface.padding,
            w: slot.w,
            h: slot.h,
          }
        }
      }
      return byKey
    }

    // Every window on this screen, kept in its workspace's own column so the
    // answer to "where is it" is still "on that desktop".
    const groups = Layout.groupBy(surface.shownWindows, w => w.workspace)
    for (const column of Layout.columns(groups, area, options)) {
      for (const slot of column.slots) {
        byKey[slot.key] = {
          x: slot.x + column.x + surface.padding,
          y: slot.y + surface.stripHeight + surface.padding + Layout.LABEL_SPACE,
          w: slot.w,
          h: slot.h,
        }
      }
    }
    return byKey
  }

  readonly property var columnLabels: {
    if (!overlay.everything || surface.shownWindows.length === 0 || surface.width <= 0) return []
    const area = {
      width: surface.width - surface.padding * 2,
      height: surface.height - surface.stripHeight - surface.padding * 2,
    }
    const groups = Layout.groupBy(surface.shownWindows, w => w.workspace)
    return Layout.columns(groups, area, { gap: 26, rowGap: 62, maxScale: 0.78 }).map(column => ({
      key: column.key,
      x: column.x + surface.padding,
      width: column.width,
    }))
  }

  Item {
    id: stage
    anchors.fill: parent
    focus: surface.leading

    Keys.onPressed: function (event) { if (surface.leading) overlay.onKey(event) }

    // Every card is frosted with a live blur of whatever is behind it, the
    // way Hyprland draws a see-through window, and stacked the way Hyprland
    // stacks them, so a floating window blurs the tiled ones beneath it too:
    //
    //   base        the desktop and the strip — behind every card
    //   tiledLayer  tiled windows' cards, which never overlap one another
    //   floatLayer  floating windows' cards, over all of it
    //
    // Each card blurs what is behind it itself, redrawn whenever that changes
    // — during a swipe, every frame. That is the price of this branch.
    Item {
      id: lower
      anchors.fill: parent

      // The desktop and the strip: what is behind every card.
      Item {
        id: base
        anchors.fill: parent

        // The desktop goes away: the windows you are about to see spread out are
        // still sitting there underneath, and two of everything reads as a mess.
        //
        // So from the very first frame the part of the screen windows live in is
        // painted over with the wallpaper exactly as the desktop draws it — same
        // image, same crop — and the cards, standing exactly where their windows
        // are and dressed the way Hyprland dresses them, take the windows' place.
        // Nothing fades: the desktop you were looking at simply becomes the
        // overview, and only then starts to move. The bar's strip is left to fade,
        // since there is no card standing in for the bar.
        //
        // Then the blur comes in over it. Loaded at the screen's real resolution
        // and blurred properly, into a layer drawn once, since the wallpaper does
        // not change while the overview is open.
        Item {
          anchors.fill: parent
          visible: overlay.wallpaper !== ""

          // One image, decoded once: the three below share it through the image
          // cache, since source and size are the same.
          Image {
            id: wall
            anchors.fill: parent
            visible: false
            source: overlay.wallpaperUrl
            fillMode: Image.PreserveAspectCrop
            sourceSize.width: Math.ceil(surface.width * surface.pixelRatio)
            sourceSize.height: Math.ceil(surface.height * surface.pixelRatio)
            smooth: true
            asynchronous: true
            cache: true
          }

          // The whole screen, bar strip included, fading with the swipe.
          Image {
            anchors.fill: parent
            source: wall.source
            opacity: overlay.veil
            fillMode: wall.fillMode
            sourceSize: wall.sourceSize
            smooth: true
            asynchronous: true
            cache: true
          }

          // Where the windows are: solid from the first frame, as soon as every
          // card is ready to stand in for its window.
          Item {
            id: workArea
            x: surface.reserved[0]
            y: surface.reserved[1]
            width: surface.width - surface.reserved[0] - surface.reserved[2]
            height: surface.height - surface.reserved[1] - surface.reserved[3]
            clip: true
            opacity: overlay.opened && surface.captured && solid.status === Image.Ready ? 1 : overlay.veil

            Image {
              id: solid
              x: -workArea.x
              y: -workArea.y
              width: surface.width
              height: surface.height
              source: wall.source
              fillMode: wall.fillMode
              sourceSize: wall.sourceSize
              smooth: true
              asynchronous: true
              cache: true
            }
          }

          MultiEffect {
            anchors.fill: parent
            source: wall
            visible: surface.blur > 0
            opacity: overlay.veil
            blurEnabled: true
            blur: 1
            blurMax: Math.round(64 * surface.blur)
            autoPaddingEnabled: false
            layer.enabled: true
          }
        }

        Rectangle {
          anchors.fill: parent
          color: "#07070A"
          opacity: (overlay.wallpaper === "" ? 0.93 : surface.dim) * overlay.veil
        }

        MouseArea {
          anchors.fill: parent
          onClicked: overlay.dismiss()
        }

        // ------------------------------------------------------------ the strip
        Item {
          id: strip
          width: parent.width
          height: surface.stripHeight
          y: -height * (1 - overlay.veil)
          opacity: overlay.veil
          visible: surface.leading

          Repeater {
            model: surface.leading ? overlay.workspaces : []

            delegate: Item {
              id: space
              required property var modelData
              required property int index
              // The desktop the spread is showing, which sliding moves before the
              // compositor has caught up.
              readonly property bool focused: space.modelData.id === overlay.stageWorkspace
              readonly property bool targeted: overlay.dragTarget === space.modelData.id
              readonly property bool peeked: overlay.peek === space.modelData.id
              readonly property var plan: overlay.plans[space.modelData.id] || []

              x: surface.tileX(space.index)
              y: surface.tileTop
              width: surface.tileWidth
              height: surface.tileHeight

              scale: space.targeted ? 1.12 : (space.peeked ? 1.06 : 1)
              Behavior on scale { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

              ClippingRectangle {
                id: tile
                anchors.fill: parent
                radius: 8
                color: "#0B0B0E"

                // Each desktop is a small picture of the desktop: the same
                // wallpaper, with a block where each window sits.
                Image {
                  anchors.fill: parent
                  source: overlay.wallpaperUrl
                  visible: overlay.wallpaper !== ""
                  fillMode: Image.PreserveAspectCrop
                  sourceSize.width: Math.ceil(surface.tileWidth * surface.pixelRatio * 1.5)
                  smooth: true
                  asynchronous: true
                  cache: true
                  opacity: space.focused || space.peeked ? 0.85 : 0.5
                }

                Rectangle {
                  anchors.fill: parent
                  color: space.targeted ? Qt.rgba(1, 1, 1, 0.16) : "transparent"
                }

                Repeater {
                  model: space.plan

                  delegate: Rectangle {
                    id: mini
                    required property var modelData
                    x: mini.modelData.x * tile.width
                    y: mini.modelData.y * tile.height
                    width: Math.max(3, mini.modelData.w * tile.width)
                    height: Math.max(3, mini.modelData.h * tile.height)
                    radius: 3
                    // Dark enough to read as a window against any wallpaper, rather
                    // than a grey square that could be anything.
                    color: mini.modelData.active ? Qt.rgba(0.10, 0.10, 0.13, 0.94)
                                                 : Qt.rgba(0.07, 0.07, 0.09, 0.84)
                    border.width: 1
                    border.color: mini.modelData.active ? Qt.rgba(1, 1, 1, 0.34)
                                                        : Qt.rgba(1, 1, 1, 0.16)

                    IconImage {
                      anchors.centerIn: parent
                      implicitSize: Math.round(Math.min(18, Math.min(mini.width, mini.height) * 0.62))
                      source: overlay.iconFor(mini.modelData.appId)
                      visible: source !== "" && mini.width > 16 && mini.height > 14
                      opacity: space.focused || space.peeked ? 0.95 : 0.7
                    }
                  }
                }

                // An untouched workspace says so, instead of looking broken — and
                // the one past the end offers itself.
                Text {
                  // Window titles are somebody else's string: a browser tab can put
                  // anything in one. Rendered literally, never interpreted as markup.
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  visible: space.plan.length === 0
                  text: space.modelData.fresh ? "\u002b" : "empty"
                  color: Qt.rgba(1, 1, 1, space.modelData.fresh ? 0.5 : 0.34)
                  font.family: Style.font.family
                  font.pixelSize: space.modelData.fresh
                                  ? Math.round(Style.font.body * 1.6) : Style.font.caption
                }
              }

              Rectangle {
                anchors.fill: parent
                radius: tile.radius
                color: "transparent"
                // The accent ring for the current desktop is drawn once, below,
                // so it can travel between tiles as you slide.
                border.width: space.targeted || space.peeked ? 2 : 1
                border.color: space.targeted ? "#F2EFE7"
                            : space.peeked ? Qt.rgba(1, 1, 1, 0.5)
                            : Qt.rgba(1, 1, 1, 0.14)
              }

              Text {
                // Window titles are somebody else's string: a browser tab can put
                // anything in one. Rendered literally, never interpreted as markup.
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.bottom
                anchors.topMargin: 6
                text: space.modelData.name
                color: space.focused ? "#F2EFE7" : "#8D8880"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.weight: space.focused ? Font.DemiBold : Font.Normal
              }

              HoverHandler {
                enabled: overlay.active && !overlay.everything
                cursorShape: Qt.PointingHandCursor
                onHoveredChanged: overlay.hoverWorkspace(space.modelData.id, hovered)
              }

              TapHandler {
                enabled: overlay.active
                onTapped: overlay.goToWorkspace(space.modelData.id)
              }
            }
          }

          // Where you are, as one ring that slides along the strip with your
          // fingers rather than jumping from tile to tile when you let go.
          Rectangle {
            visible: overlay.stageIndex >= 0
            x: surface.tileX(Math.max(0, overlay.stageIndex + overlay.slide))
            y: surface.tileTop
            width: surface.tileWidth
            height: surface.tileHeight
            radius: 8
            color: "transparent"
            border.width: 2
            border.color: Color.accent
            Behavior on x { enabled: !overlay.moving; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
          }
        }

        // ------------------------------------------------------- column labels
        Repeater {
          model: surface.columnLabels

          delegate: Text {
            required property var modelData
            x: modelData.x
            y: surface.stripHeight + surface.padding
            width: modelData.width
            horizontalAlignment: Text.AlignHCenter
            text: modelData.key
            color: Qt.rgba(1, 1, 1, 0.45)
            opacity: overlay.veil
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.weight: Font.DemiBold
          }
        }
      }

      Item {
        id: tiledLayer
        anchors.fill: parent

        Repeater {
          id: tiledCards
          model: surface.monitorWindows.filter(w => !w.floating)
          delegate: cardDelegate
        }
      }
    }

    Item {
      id: floatLayer
      anchors.fill: parent

      Repeater {
        id: floatCards
        model: surface.monitorWindows.filter(w => w.floating)
        delegate: cardDelegate
      }
    }

    // Behind a tiled window: the desktop and the strip.
    HyprBlur {
      id: baseBlur
      anchors.fill: parent
      sourceItem: base
      live: surface.glass && overlay.opened
      pixelSize: Qt.size(Math.round(surface.width * surface.pixelRatio), Math.round(surface.height * surface.pixelRatio))
      size: overlay.deco.blurSize * surface.blurScale
      passes: overlay.deco.blurPasses
      noise: overlay.deco.blurNoise
      contrast: overlay.deco.blurContrast
      brightness: overlay.deco.blurBrightness
      vibrancy: overlay.deco.blurVibrancy
      vibrancyDarkness: overlay.deco.blurVibrancyDarkness
    }

    // Behind a floating window: all of that and the tiled windows too. Only
    // run while a floating window is on screen.
    HyprBlur {
      id: floatBlur
      anchors.fill: parent
      sourceItem: lower
      live: surface.glass && overlay.opened && surface.floatingShown
      pixelSize: baseBlur.pixelSize
      size: baseBlur.size
      passes: baseBlur.passes
      noise: baseBlur.noise
      contrast: baseBlur.contrast
      brightness: baseBlur.brightness
      vibrancy: baseBlur.vibrancy
      vibrancyDarkness: baseBlur.vibrancyDarkness
    }

    // ------------------------------------------------------------ the windows
    // One card, drawn in whichever layer its window belongs to.
    Component {
      id: cardDelegate

      Item {
        id: card
        required property var modelData
        // Where the window really is right now, which can be fresher than the
        // snapshot the card was built from.
        readonly property var real: overlay.geo[card.modelData.key] || card.modelData
        readonly property bool focusedWindow: card.real.active === true
        // Which layer it is in: floating over tiled, as Hyprland stacks them,
        // so each card's blur has the right things behind it.
        readonly property bool floating: card.modelData.floating === true
        // Shown, but nothing captured to show yet.
        readonly property bool waiting: card.shown && !shot.hasContent
        readonly property var slot: surface.slots[card.modelData.key] || null
        // On the desktop being shown, which peeking changes without rebuilding
        // anything: the card is already here, it just fades in.
        readonly property bool here: overlay.everything || surface.searching
                                     || (surface.sliding ? Math.abs(card.lane) < 1
                                                         : card.modelData.workspace === surface.shownWorkspace)
        // How many screens over this card's desktop is while sliding.
        readonly property real lane: surface.leading ? overlay.laneOf(card.modelData.workspace) : 0
        readonly property real shift: surface.sliding ? card.lane * surface.width : 0
        readonly property bool shown: card.here && overlay.matches(card.modelData)
        readonly property bool hovered: hover.hovered && overlay.active
        readonly property bool picked: card.hovered || overlay.selectedKey === card.modelData.key
        readonly property bool dragging: dragger.active
        readonly property bool landing: overlay.dropOnKey === card.modelData.key
        // Resolved once per card rather than per frame: a desktop-entry search
        // is a directory walk.
        readonly property string icon: overlay.iconFor(card.modelData.appId)

        // The whole animation: where it is, blended with where it goes — plus
        // however far it has been dragged since it was picked up.
        // Up to fully open, the window's place blended with its slot. Past
        // it — the fingers still pushing — the card goes on shrinking about
        // its own middle and drifting up toward the strip, rather than
        // carrying on along the same line, which would shrink a big window
        // with a small slot to nothing.
        readonly property real along: Math.min(1, overlay.t)
        readonly property real beyond: Math.max(0, overlay.t - 1)
        readonly property real squeeze: 1 - card.beyond * 0.7
        readonly property real baseW: card.slot ? card.real.w + (card.slot.w - card.real.w) * card.along : card.real.w
        readonly property real baseH: card.slot ? card.real.h + (card.slot.h - card.real.h) * card.along : card.real.h

        x: (card.slot ? card.real.x + (card.slot.x - card.real.x) * card.along : card.real.x)
           + card.baseW * (1 - card.squeeze) / 2
           + card.shift
           + (card.dragging ? dragger.activeTranslation.x : 0)
        y: (card.slot ? card.real.y + (card.slot.y - card.real.y) * card.along : card.real.y)
           + card.baseH * (1 - card.squeeze) / 2
           - card.beyond * surface.height * 0.12
           + (card.dragging ? dragger.activeTranslation.y : 0)
        width: card.baseW * card.squeeze
        height: card.baseH * card.squeeze

        Behavior on x { enabled: overlay.active && !card.dragging && !overlay.moving && !overlay.settling; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on y { enabled: overlay.active && !card.dragging && !overlay.moving && !overlay.settling; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on width { enabled: overlay.active && !card.dragging && !overlay.moving && !overlay.settling; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        Behavior on height { enabled: overlay.active && !card.dragging && !overlay.moving && !overlay.settling; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

        z: card.dragging ? 3 : (card.picked ? 2 : 1)
        // Held, it shrinks the way a thing you have picked up does — and
        // shrinks further over somewhere it would land, so it stops covering
        // what it is about to drop into.
        // Grown under the pointer only once the overview is open. The window
        // you were using starts out selected, and growing it from the first
        // frame made it the one card that did not match its window.
        scale: card.dragging ? (overlay.dragTarget > 0 || overlay.dropOnKey !== "" ? 0.4 : 0.82)
             : (card.picked && overlay.active ? 1.035 : 1)
        opacity: card.shown ? (card.dragging ? 0.94 : 1) : 0
        visible: card.opacity > 0.01
        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        // Sliding carries a desktop off the screen rather than fading it: one
        // that is still dissolving as it goes reads as lag.
        Behavior on opacity { enabled: !surface.sliding; NumberAnimation { duration: 150 } }

        // Hyprland's rounding on the desktop, the overview's own once spread.
        readonly property real radius: overlay.deco.rounding + (14 - overlay.deco.rounding) * overlay.dress

        // Hyprland's shadow and border, which the card wears while it still
        // stands in for the window, and sheds as it becomes a card.
        RectangularShadow {
          z: -1
          anchors.fill: parent
          anchors.margins: -overlay.deco.border
          radius: card.radius + overlay.deco.border
          blur: overlay.deco.shadowRange
          spread: 0
          color: card.focusedWindow ? overlay.deco.shadowColor : overlay.deco.shadowColorInactive
          opacity: 1 - overlay.dress
          visible: overlay.deco.shadow && overlay.deco.shadowRange > 0 && opacity > 0.01 && !card.dragging
        }

        Rectangle {
          z: -1
          anchors.fill: parent
          anchors.margins: -overlay.deco.border
          radius: card.radius + overlay.deco.border
          color: "transparent"
          border.width: overlay.deco.border
          border.color: card.focusedWindow ? overlay.deco.activeBorder : overlay.deco.inactiveBorder
          opacity: 1 - overlay.dress
          visible: overlay.deco.border > 0 && opacity > 0.01 && !card.dragging
        }

        // What the compositor blurs behind this window: the piece of the
        // blurred screen the card is over, cut to its shape. Tiled windows
        // take it from the desktop's blur; floating ones from the blur that
        // has the tiled windows in it too, the way Hyprland stacks them.
        //
        // Outside the frame, not in it: the frame draws its contents through
        // a copy of its own, and textures read inside that never update.
        readonly property bool frostedGlass: surface.glass && overlay.wallpaper !== "" && shot.hasContent

        ShaderEffect {
          anchors.fill: parent
          visible: card.frostedGlass
          opacity: frame.opacity
          property var source: card.floating ? floatBlur.output : baseBlur.output
          // Where the card is on screen, scaled about its middle as it is
          // drawn, as a fraction of the screen.
          property vector4d area: {
            const w = card.width * card.scale
            const h = card.height * card.scale
            const x = card.x + (card.width - w) / 2
            const y = card.y + (card.height - h) / 2
            return Qt.vector4d(x / Math.max(1, surface.width), y / Math.max(1, surface.height),
                               w / Math.max(1, surface.width), h / Math.max(1, surface.height))
          }
          property vector2d size: Qt.vector2d(width, height)
          property real radius: card.radius
          fragmentShader: Qt.resolvedUrl("blur/frost.frag.qsb")
        }

        ClippingRectangle {
          id: frame
          anchors.fill: parent
          radius: card.radius
          // As see-through as Hyprland draws the window, becoming solid.
          opacity: card.real.opacity + (1 - card.real.opacity) * overlay.dress
          // Under the capture, so a window whose first frame has not arrived
          // yet reads as a tile and not as a hole — but only as the overview
          // comes in. At the start of a swipe the card sits exactly on its
          // real window, which is still showing, so an empty card should let
          // that window through rather than flash a dark block over it.
          color: card.frostedGlass ? "transparent"
               : shot.hasContent ? "#101014" : Qt.rgba(0.063, 0.063, 0.078, overlay.veil)

          ScreencopyView {
            id: shot
            anchors.fill: parent
            captureSource: card.modelData.capture
            // Never live, not even for the window under the pointer. A live
            // capture is a texture that changes every frame, and one of those
            // makes the compositor redraw this whole surface sixty times a
            // second — the wallpaper, every tile, every icon — which cost more
            // than all eight captures put together. On the clock instead, they
            // still read as alive and the surface redraws a dozen times a
            // second rather than sixty.
            live: false
          }

          Connections {
            target: overlay
            // Only the cards you can actually see are worth a frame; the rest
            // are kept alive purely so that showing them is instant.
            function onBeatChanged() { if (card.shown) shot.captureFrame() }
          }

          // Coming into view does not wait for the next beat. Without this a
          // card that has just been peeked at shows its placeholder until the
          // clock comes round, which is the blank tile people saw.
          Connections {
            target: card
            function onShownChanged() { if (card.shown) shot.captureFrame() }
          }
        }

        // Hairline at rest, accent ring under the pointer, bright ring for a
        // window something is about to be dropped onto.
        Rectangle {
          anchors.fill: parent
          radius: card.radius
          color: "transparent"
          border.width: card.landing ? 3 : (card.picked ? 3 : 1)
          border.color: card.landing ? "#F2EFE7" : (card.picked ? Color.accent : Qt.rgba(1, 1, 1, 0.14))
          opacity: overlay.dress
        }

        HoverHandler {
          id: hover
          enabled: overlay.active && card.shown
          cursorShape: card.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
          onHoveredChanged: if (hover.hovered) overlay.selectedKey = card.modelData.key
        }

        TapHandler {
          enabled: overlay.active && card.shown
          acceptedButtons: Qt.LeftButton | Qt.MiddleButton
          onTapped: function (point, button) {
            if (button === Qt.MiddleButton) overlay.closeWindow(card.modelData.key)
            else overlay.focusWindow(card.modelData.key)
          }
        }

        // Pick a window up: drop it on a workspace to send it there, or on
        // another window to trade places with it.
        DragHandler {
          id: dragger
          enabled: overlay.active && card.shown
          target: null

          onActiveChanged: {
            if (dragger.active) {
              overlay.dragKey = card.modelData.key
              overlay.selectedKey = card.modelData.key
            } else {
              overlay.drop(card.modelData.key)
              overlay.dragKey = ""
            }
          }

          onCentroidChanged: {
            if (!dragger.active) return
            const at = dragger.centroid.scenePosition
            overlay.aimDrag(surface.workspaceAtPoint(at.x, at.y), surface.cardAtPoint(at.x, at.y))
          }
        }

        // Close it from here, rather than going there to close it.
        Rectangle {
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: 8
          width: 26
          height: 26
          radius: 13
          color: shut.hovered ? "#D2604F" : Qt.rgba(0, 0, 0, 0.62)
          border.width: 1
          border.color: Qt.rgba(1, 1, 1, 0.22)
          visible: overlay.active && card.picked && !card.dragging
          opacity: visible ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 110 } }

          Text {
            // Window titles are somebody else's string: a browser tab can put
            // anything in one. Rendered literally, never interpreted as markup.
            textFormat: Text.PlainText
            anchors.centerIn: parent
            text: "×"
            color: "#F4F1E9"
            font.family: Style.font.family
            font.pixelSize: Math.round(Style.font.body * 1.1)
          }

          HoverHandler { id: shut }

          TapHandler {
            onTapped: overlay.closeWindow(card.modelData.key)
          }
        }

        // The name of the window, under it, the way a caption sits under a
        // photograph — with the app's own icon, because at thumbnail size the
        // icon is what you recognise before you have read anything.
        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.top: parent.bottom
          anchors.topMargin: 10
          width: Math.min(caption.implicitWidth + 20, parent.width)
          height: caption.implicitHeight + 10
          radius: height / 2
          color: card.picked ? Qt.rgba(0, 0, 0, 0.78) : Qt.rgba(0, 0, 0, 0.5)
          opacity: overlay.active ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 120 } }

          Row {
            id: caption
            anchors.centerIn: parent
            spacing: 7

            IconImage {
              anchors.verticalCenter: parent.verticalCenter
              implicitSize: Math.round(Style.font.caption * 1.35)
              source: card.icon
              visible: card.icon !== ""
            }

            // Which desktop a match came from, shown only when that is news:
            // while searching, and only for a window that is not on the one you
            // are already looking at.
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              visible: surface.searching
                       && card.modelData.workspace !== surface.shownWorkspace
              implicitWidth: elsewhere.implicitWidth + 12
              implicitHeight: elsewhere.implicitHeight + 4
              radius: 4
              color: Qt.rgba(1, 1, 1, 0.14)

              Text {
                id: elsewhere
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: card.modelData.workspace
                color: "#F7F4EC"
                font.family: Style.font.family
                font.pixelSize: Math.round(Style.font.caption * 0.9)
                font.weight: Font.DemiBold
              }
            }

            Text {
              // Window titles are somebody else's string: a browser tab can put
              // anything in one. Rendered literally, never interpreted as markup.
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, card.width - 40)
              text: card.modelData.title
              elide: Text.ElideRight
              color: card.picked ? "#F7F4EC" : "#C9C3B9"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }

    // ------------------------------------------------------ an empty desktop
    // Says so, and slides with the rest, so a desktop with nothing on it
    // arrives as a place rather than as a gap.
    Repeater {
      model: surface.leading ? overlay.lanes : []

      delegate: Text {
        id: nothing
        required property var modelData
        readonly property real lane: overlay.laneOf(nothing.modelData)
        textFormat: Text.PlainText
        visible: overlay.active && !overlay.everything && !surface.searching && overlay.peek <= 0
                 && Math.abs(nothing.lane) < 1
                 && !surface.monitorWindows.some(w => w.workspace === nothing.modelData)
        x: (surface.width - nothing.width) / 2 + nothing.lane * surface.width
        y: surface.stripHeight + (surface.height - surface.stripHeight - nothing.height) / 2
        text: "No windows on " + nothing.modelData
        color: Qt.rgba(1, 1, 1, 0.42)
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }

    // ----------------------------------------------------------- the filter
    // Only ever on the screen you are typing at, and only once you have typed.
    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      y: surface.stripHeight + 14
      visible: surface.leading && overlay.filter !== ""
      width: query.implicitWidth + 34
      height: query.implicitHeight + 20
      radius: height / 2
      color: Qt.rgba(0, 0, 0, 0.72)
      border.width: 1
      border.color: Qt.rgba(1, 1, 1, 0.16)
      opacity: overlay.veil

      Text {
        // Window titles are somebody else's string: a browser tab can put
        // anything in one. Rendered literally, never interpreted as markup.
        textFormat: Text.PlainText
        id: query
        anchors.centerIn: parent
        text: overlay.filter + "   " + surface.shownWindows.length
              + (surface.shownWindows.length === 1 ? " window" : " windows")
        color: surface.shownWindows.length === 0 ? "#D2604F" : "#F2EFE7"
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }
  }
}
