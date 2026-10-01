// Mission Control-style window overview.
//
// Shows every open window, across all workspaces, as a live thumbnail on the
// focused monitor. Click a window (or move with the arrow keys and press
// Enter) to jump to it. Escape, or a click on empty space, closes it.
//
// Driven through the shell's standard overlay lifecycle (open/close/opened):
//
//   omarchy-shell shell toggle io.github.proof001.window-overview
//   omarchy-shell shell summon io.github.proof001.window-overview
//   omarchy-shell shell hide io.github.proof001.window-overview

import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Wayland._Screencopy
import QtQuick
import qs.Commons
import qs.Ui

Item {
  id: root

  // Injected by Omarchy's panel loader.
  property var shell: null
  property var manifest: null

  property bool opened: false
  property var windows: []
  property int selectedIndex: 0

  readonly property int gap: Style.space(28)
  readonly property int labelHeight: Style.font.body + Style.space(14)
  readonly property int margin: Style.space(64)

  function normalizedAddress(raw) {
    const hex = String(raw || "").trim().toLowerCase()
    if (!hex) return ""
    return hex.indexOf("0x") === 0 ? hex : "0x" + hex
  }

  // friendlyAppName() and appIcon() are adapted from omarchy-altswitch
  // (MIT, Copyright (c) 2026 Pablo Merino).
  function friendlyAppName(appClass) {
    const raw = String(appClass || "").trim()
    if (!raw) return "Unknown"
    const entry = DesktopEntries.heuristicLookup(raw)
    if (entry && entry.name) return String(entry.name)
    let name = raw.replace(/^steam_app_/i, "")
    if (name.indexOf(".") !== -1) name = name.split(".").pop()
    name = name.replace(/[_-]+/g, " ").trim()
    return name.replace(/(^|\s)\S/g, function(letter) { return letter.toUpperCase() })
  }

  function appIcon(appClass) {
    const raw = String(appClass || "").trim()
    const entry = raw ? DesktopEntries.heuristicLookup(raw) : null
    const icon = entry ? String(entry.icon || "") : ""
    if (icon.indexOf("file://") === 0 || icon.indexOf("image://") === 0) return icon
    if (icon.charAt(0) === "/") return Util.fileUrl(icon)
    return Quickshell.iconPath(icon || "application-x-executable", true)
  }

  // Snapshot the window list. Windows on the current workspace come first,
  // then the rest by workspace, each group in on-screen reading order.
  function collectWindows() {
    const focusedWs = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -999
    const tops = Hyprland.toplevels ? Hyprland.toplevels.values : []
    const list = []

    for (let i = 0; i < tops.length; i++) {
      const top = tops[i]
      if (!top || !top.wayland) continue
      const ipc = top.lastIpcObject || {}
      if (ipc.mapped === false || ipc.hidden === true) continue

      const ws = top.workspace
      const at = ipc.at || [0, 0]
      const size = ipc.size || [16, 10]
      list.push({
        toplevel: top,
        address: root.normalizedAddress(top.address),
        title: String(top.title || ipc.title || ""),
        appClass: String(ipc.class || ipc.initialClass || ""),
        workspaceId: ws ? ws.id : 0,
        workspaceName: ws ? String(ws.name || ws.id) : "",
        x: at[0],
        y: at[1],
        aspect: size[1] > 0 ? size[0] / size[1] : 1.6,
        active: Hyprland.activeToplevel === top
      })
    }

    list.sort(function(a, b) {
      const aCur = a.workspaceId === focusedWs ? 0 : 1
      const bCur = b.workspaceId === focusedWs ? 0 : 1
      if (aCur !== bCur) return aCur - bCur
      // Special (scratchpad) workspaces have negative ids; put them last.
      const aSpecial = a.workspaceId < 0 ? 1 : 0
      const bSpecial = b.workspaceId < 0 ? 1 : 0
      if (aSpecial !== bSpecial) return aSpecial - bSpecial
      if (a.workspaceId !== b.workspaceId) return a.workspaceId - b.workspaceId
      if (a.y !== b.y) return a.y - b.y
      return a.x - b.x
    })
    return list
  }

  // Shell lifecycle: summon delivers open(payload), hide calls close(), and
  // toggle reads `opened`. The payload is unused.
  function open(payload) {
    root.show()
  }

  function close() {
    root.hide()
  }

  function show() {
    Hyprland.refreshToplevels()
    Hyprland.refreshWorkspaces()
    // The refresh is asynchronous; give it one tick before snapshotting.
    Qt.callLater(function() {
      root.windows = root.collectWindows()
      let start = 0
      for (let i = 0; i < root.windows.length; i++) {
        if (root.windows[i].active) { start = i; break }
      }
      root.selectedIndex = start
      root.opened = true
    })
  }

  function hide() {
    root.opened = false
  }

  function toggle() {
    if (root.opened) root.hide()
    else root.show()
  }

  function activate(index) {
    const win = root.windows[index]
    root.hide()
    if (!win || !win.address) return
    const target = "address:" + win.address
    Hyprland.dispatch(Hyprland.usingLua
      ? 'hl.dsp.focus({ window = "' + target + '" })'
      : "focuswindow " + target)
  }

  function moveSelection(dx, dy) {
    const count = root.windows.length
    if (count === 0) return
    const cols = grid.columns
    let next = root.selectedIndex
    if (dx !== 0) next = Math.max(0, Math.min(count - 1, next + dx))
    if (dy !== 0) {
      const candidate = next + dy * cols
      if (candidate >= 0 && candidate < count) next = candidate
      else if (dy > 0) next = count - 1
    }
    root.selectedIndex = next
  }

  PanelWindow {
    id: panel

    visible: root.opened
    screen: {
      const name = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
      const screens = Quickshell.screens
      for (let i = 0; i < screens.length; i++) {
        if (screens[i].name === name) return screens[i]
      }
      return screens.length > 0 ? screens[0] : null
    }
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "window-overview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      // The theme scrim is tuned for small menus; an overview needs the
      // desktop pushed much further back.
      color: Qt.rgba(0, 0, 0, 0.72)
      opacity: root.opened ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 140 } }
    }

    // A click on empty space dismisses the overview.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
      onClicked: root.hide()
    }

    Text {
      visible: root.windows.length === 0
      anchors.centerIn: parent
      text: "No open windows"
      color: Color.menu.text
      opacity: 0.7
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.body * 1.4
    }

    Item {
      id: keys

      anchors.fill: parent
      focus: root.opened
      Keys.onPressed: function(event) {
        switch (event.key) {
        case Qt.Key_Escape:
          root.hide(); break
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Space:
          root.activate(root.selectedIndex); break
        case Qt.Key_Left:
        case Qt.Key_H:
          root.moveSelection(-1, 0); break
        case Qt.Key_Right:
        case Qt.Key_L:
          root.moveSelection(1, 0); break
        case Qt.Key_Up:
        case Qt.Key_K:
          root.moveSelection(0, -1); break
        case Qt.Key_Down:
        case Qt.Key_J:
          root.moveSelection(0, 1); break
        case Qt.Key_Tab:
          root.moveSelection(event.modifiers & Qt.ShiftModifier ? -1 : 1, 0); break
        default:
          return
        }
        event.accepted = true
      }
    }

    Item {
      id: grid

      readonly property int count: root.windows.length
      readonly property real areaWidth: panel.width - root.margin * 2
      readonly property real areaHeight: panel.height - root.margin * 2

      // Pick the column count that gives the biggest tiles, assuming
      // 16:10-ish previews plus a title line under each.
      readonly property var layout: {
        const n = Math.max(1, count)
        let best = { columns: 1, tileWidth: 0 }
        for (let cols = 1; cols <= n; cols++) {
          const rows = Math.ceil(n / cols)
          const byWidth = (areaWidth - root.gap * (cols - 1)) / cols
          const byHeight = ((areaHeight - root.gap * (rows - 1)) / rows - root.labelHeight) * 1.6
          const w = Math.min(byWidth, byHeight, panel.width * 0.42)
          if (w > best.tileWidth) best = { columns: cols, tileWidth: w }
        }
        return best
      }
      readonly property int columns: layout.columns
      readonly property real tileWidth: Math.max(0, layout.tileWidth)
      readonly property real previewHeight: tileWidth / 1.6
      readonly property int rows: Math.ceil(Math.max(1, count) / columns)

      width: columns * tileWidth + (columns - 1) * root.gap
      height: rows * (previewHeight + root.labelHeight) + (rows - 1) * root.gap
      anchors.centerIn: parent
      scale: root.opened ? 1 : 0.94
      Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

      Repeater {
        model: root.opened ? root.windows : []

        delegate: Item {
          id: tile

          required property int index
          required property var modelData

          readonly property bool selected: index === root.selectedIndex
          readonly property int col: index % grid.columns
          readonly property int row: Math.floor(index / grid.columns)
          // Center a short last row, like Mission Control does.
          readonly property int itemsInRow: Math.min(grid.columns, grid.count - row * grid.columns)
          readonly property real rowOffset: (grid.columns - itemsInRow) * (grid.tileWidth + root.gap) / 2

          x: rowOffset + col * (grid.tileWidth + root.gap)
          y: row * (grid.previewHeight + root.labelHeight + root.gap)
          width: grid.tileWidth
          height: grid.previewHeight + root.labelHeight

          // Preview frame, sized to the window's own aspect ratio.
          Rectangle {
            id: frame

            readonly property real fitWidth: Math.min(tile.width, grid.previewHeight * tile.modelData.aspect)
            readonly property real fitHeight: fitWidth / tile.modelData.aspect

            width: fitWidth + 6
            height: fitHeight + 6
            anchors.horizontalCenter: parent.horizontalCenter
            y: (grid.previewHeight - height) / 2
            radius: Style.cornerRadius + 3
            color: Util.alpha(Color.menu.background, 0.85)
            border.width: tile.selected || hover.containsMouse ? 3 : 1
            border.color: tile.selected
              ? Color.menu.selectedBackground
              : Util.alpha(Color.menu.text, hover.containsMouse ? 0.6 : 0.2)
            scale: hover.containsMouse ? 1.03 : 1
            Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutQuad } }

            ScreencopyView {
              id: preview

              anchors.fill: parent
              anchors.margins: 3
              clip: true
              live: root.opened
              captureSource: tile.modelData.toplevel ? tile.modelData.toplevel.wayland : null
            }

            // Shown until the first frame arrives, or if capture fails.
            Image {
              visible: !preview.hasContent
              anchors.centerIn: parent
              width: Math.min(parent.width, parent.height) * 0.35
              height: width
              fillMode: Image.PreserveAspectFit
              sourceSize.width: width * Screen.devicePixelRatio
              sourceSize.height: height * Screen.devicePixelRatio
              source: root.appIcon(tile.modelData.appClass)
              asynchronous: true
            }

            // Workspace badge.
            Rectangle {
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.margins: Style.space(8)
              width: badge.implicitWidth + Style.space(12)
              height: badge.implicitHeight + Style.space(4)
              radius: height / 2
              color: Util.alpha(Color.menu.background, 0.85)

              Text {
                id: badge
                anchors.centerIn: parent
                text: tile.modelData.workspaceId < 0
                  ? tile.modelData.workspaceName.replace(/^special:/, "")
                  : tile.modelData.workspaceName
                color: Color.menu.text
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.body * 0.85
              }
            }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            spacing: Style.space(8)
            width: Math.min(implicitWidth, tile.width)

            Image {
              width: Style.font.body * 1.3
              height: width
              anchors.verticalCenter: parent.verticalCenter
              fillMode: Image.PreserveAspectFit
              sourceSize.width: width * Screen.devicePixelRatio
              sourceSize.height: height * Screen.devicePixelRatio
              source: root.appIcon(tile.modelData.appClass)
              asynchronous: true
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, tile.width - Style.font.body * 1.3 - Style.space(8))
              elide: Text.ElideRight
              text: tile.modelData.title || root.friendlyAppName(tile.modelData.appClass)
              color: Color.menu.text
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
              font.bold: tile.selected
            }
          }

          MouseArea {
            id: hover

            anchors.fill: frame
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton
            cursorShape: Qt.PointingHandCursor
            onEntered: root.selectedIndex = tile.index
            onClicked: root.activate(tile.index)
          }
        }
      }
    }
  }
}
