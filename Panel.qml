import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.oidium.pocket"
  ipcTarget: "io.github.oidium.pocket"
  implicitWidth: barButton.implicitWidth
  implicitHeight: barButton.implicitHeight

  readonly property string bridge: decodeURIComponent(Qt.resolvedUrl("bridge.py").toString().replace(/^file:\/\//, ""))
  readonly property color ink: Color.popups.text
  readonly property color subdued: Qt.alpha(ink, 0.62)
  readonly property string face: bar ? bar.fontFamily : Style.font.family
  property var dependencies: ({})
  readonly property var missingDependencies: Object.keys(dependencies).filter(function(name) { return !dependencies[name] })
  property var devices: []
  property string selectedId: ""
  property bool loaded: false
  property string connectionError: ""
  property string message: ""
  property bool messageError: false
  property string busyVerb: ""
  readonly property var phone: {
    for (var i = 0; i < devices.length; ++i)
      if (devices[i].id === selectedId) return devices[i]
    return devices.length ? devices[0] : null
  }
  readonly property bool online: !!phone && phone.online
  readonly property var media: phone ? phone.media : ({})
  readonly property var notes: phone ? phone.notifications : []
  readonly property bool playing: online && !!media.player
  readonly property bool busy: action.running

  function can(feature) {
    if (!online || phone.can.indexOf("kdeconnect_" + feature) < 0) return false
    if (feature === "sftp") return dependencies.sshfs === true && dependencies["kio-fuse"] === true && dependencies.nautilus === true
    if (feature === "share") return dependencies["omarchy-file-select"] === true
    return true
  }
  function reveal(item) {
    if (!root.opened) return
    var point = item.mapToItem(content, 0, 0)
    if (point.y < scroll.contentY) scroll.contentY = point.y
    else if (point.y + item.height > scroll.contentY + scroll.height)
      scroll.contentY = Math.max(0, point.y + item.height - scroll.height)
  }
  function refresh() { if (!snapshot.running) snapshot.running = true }
  function run(verb, value) {
    if (!online || busy) return
    message = ""; busyVerb = verb
    action.command = ["python3", bridge, verb, phone.id, value === undefined ? "" : String(value)]
    action.running = true
    if (verb === "share") root.close()
  }
  function nextDevice() {
    if (devices.length < 2) return
    var index = devices.findIndex(function(d) { return d.id === phone.id })
    selectedId = devices[(index + 1) % devices.length].id
    message = ""
  }
  function nextPlayer() {
    var players = media.playerList || []
    if (!players.length) return
    run("player", players[(players.indexOf(media.player) + 1) % players.length])
  }
  onOpenedChanged: if (opened) { refresh(); message = "" }
  Component.onCompleted: refresh()

  Timer { interval: root.opened ? 4000 : 30000; repeat: true; running: true; onTriggered: root.refresh() }
  Timer { id: feedbackTimer; interval: 7000; onTriggered: if (!root.messageError) root.message = "" }
  Timer {
    interval: 12000; running: snapshot.running
    onTriggered: {
      snapshot.running = false
      root.connectionError = "KDE Connect is taking too long to respond. Try Refresh."
      root.devices = []; root.loaded = true
    }
  }
  Process {
    id: snapshot
    command: ["python3", root.bridge, "snapshot"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var result = JSON.parse(text)
          root.dependencies = result.dependencies || {}
          root.devices = result.devices || []
          root.connectionError = result.ok ? "" : (result.error || "Could not reach KDE Connect. Open its settings and try again.")
        } catch (e) {
          root.devices = []; root.connectionError = "Could not read device status. Try Refresh."
        }
        root.loaded = true
      }
    }
  }
  Process {
    id: action
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var result = JSON.parse(text)
          root.messageError = !result.ok
          root.message = result.ok ? result.message : result.error
        } catch (e) { root.messageError = true; root.message = "Action could not be completed. Try again." }
        feedbackTimer.restart(); root.refresh()
      }
    }
  }

  BarIconButton {
    id: barButton
    anchors.fill: parent
    bar: root.bar
    text: ""
    iconComponent: Component {
      Item {
        Rectangle {
          anchors.centerIn: parent
          width: parent.width * 0.57; height: parent.height * 0.86
          color: "transparent"; radius: Style.space(2)
          border.width: Math.max(1, Style.space(1.4))
          border.color: root.opened ? Color.accent : root.barForeground
          Rectangle {
            width: parent.width * 0.3; height: Math.max(1, Style.space(1))
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom; anchors.bottomMargin: Style.space(3)
            color: parent.border.color
          }
        }
      }
    }
    active: root.opened
    activeColor: Color.accent
    tooltipText: "Pocket · KDE Connect" + (root.phone ? " · " + root.phone.name + (root.online ? (root.phone.battery >= 0 ? " · " + root.phone.battery + "%" : " · Connected") : " · Offline") : " · No paired phone")
    onPressed: root.toggle()
    Rectangle {
      visible: root.online
      width: Style.space(4); height: width; radius: width / 2
      anchors.right: parent.right; anchors.rightMargin: Style.space(2)
      anchors.bottom: parent.bottom; anchors.bottomMargin: Style.space(7)
      color: Color.accent
    }
  }

  KeyboardPanel {
    id: popup
    anchorItem: barButton
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyArea
    contentWidth: fittedContentWidth(Style.space(424))
    contentHeight: fittedContentHeight(content.implicitHeight, Style.space(880))

    Item {
      id: keyArea
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.close()
      Keys.onPressed: function(event) {
        if (event.text === "b" && root.can("sftp")) { root.run("files"); event.accepted = true }
        if (event.text === "r") { root.refresh(); event.accepted = true }
      }
      Flickable {
        id: scroll
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: content.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

        Column {
          id: content
          width: scroll.width
          spacing: Style.space(16)

          Row {
            width: parent.width
            spacing: Style.space(8)
            Label {
              width: parent.width - refreshButton.width - closeButton.width - parent.spacing * 2
              anchors.verticalCenter: parent.verticalCenter
              text: "POCKET"; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1.5
            }
            PocketButton {
              id: refreshButton; iconText: "󰑐"; tooltipText: "Refresh · R"; focusable: true
              foreground: root.ink; enabled: !snapshot.running
              onClicked: root.refresh()
            }
            PocketButton {
              id: closeButton; iconText: "󰅖"; tooltipText: "Close · Esc"; focusable: true
              foreground: root.ink; onClicked: root.close()
            }
          }

          Rectangle {
            width: parent.width
            visible: root.missingDependencies.length > 0
            height: setupInfo.implicitHeight + Style.space(24)
            radius: Style.cornerRadius
            color: Qt.alpha(Color.urgent, 0.08)
            border.width: 1; border.color: Qt.alpha(Color.urgent, 0.4)
            Column {
              id: setupInfo
              anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(12); spacing: Style.space(6)
              Label { width: parent.width; text: "Finish setting up"; font.bold: true; color: Color.urgent }
              Label { width: parent.width; text: "Missing: " + root.missingDependencies.join(", "); wrapMode: Text.WordWrap }
              Label {
                width: parent.width; font.pixelSize: Style.font.bodySmall; color: root.subdued; wrapMode: Text.WrapAnywhere
                text: root.missingDependencies.indexOf("omarchy-file-select") >= 0
                  ? "Update Omarchy to restore its file chooser. See the README for other packages, then refresh."
                  : "In a terminal, run: sudo pacman -S --needed " + root.missingDependencies.join(" ") + " — then refresh."
              }
            }
          }

          Rectangle {
            width: parent.width
            height: hero.implicitHeight + Style.space(32)
            radius: Style.cornerRadius
            color: Qt.alpha(Color.accent, 0.08)
            border.width: 1; border.color: Qt.alpha(Color.accent, 0.2)
            Column {
              id: hero
              anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(16)
              spacing: Style.space(14)
              Row {
                width: parent.width; spacing: Style.space(14)
                Rectangle {
                  width: Style.space(38); height: Style.space(56); radius: Style.space(7)
                  color: "transparent"; border.width: 2; border.color: root.online ? Color.accent : root.subdued
                  anchors.verticalCenter: parent.verticalCenter
                  Rectangle { width: parent.width * 0.4; height: 2; radius: 1; color: parent.border.color; anchors.top: parent.top; anchors.topMargin: 5; anchors.horizontalCenter: parent.horizontalCenter }
                  Text { anchors.centerIn: parent; text: root.online ? "󰄬" : "󰅖"; color: parent.border.color; font.family: root.face; font.pixelSize: Style.font.heading }
                  Rectangle { width: 9; height: 2; radius: 1; color: parent.border.color; anchors.bottom: parent.bottom; anchors.bottomMargin: 5; anchors.horizontalCenter: parent.horizontalCenter }
                }
                Column {
                  width: parent.width - Style.space(52); spacing: Style.space(5)
                  Label { width: parent.width; text: root.phone ? root.phone.name : root.loaded ? "Your phone belongs here" : "Finding your phone…"; font.pixelSize: Style.font.title; font.bold: true; wrapMode: Text.WordWrap }
                  Label { width: parent.width; text: root.online ? "CONNECTED  /  " + (root.phone.links.join(" + ") || "KDE Connect") : root.phone ? "OFFLINE  /  Waiting to reconnect" : "Pair a device in KDE Connect"; color: root.online ? Color.accent : root.subdued; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
                }
              }
              Row {
                visible: root.online && root.phone.battery >= 0
                width: parent.width; spacing: Style.space(12)
                Label { id: percent; text: root.phone ? root.phone.battery + "%" : ""; font.pixelSize: Style.font.heading; font.bold: true; color: root.phone && root.phone.battery <= 15 ? Color.urgent : root.ink }
                Rectangle {
                  width: parent.width - percent.width - charge.width - parent.spacing * 2; height: Style.space(5); radius: height / 2
                  anchors.verticalCenter: parent.verticalCenter; color: Qt.alpha(root.ink, 0.12)
                  Rectangle { width: parent.width * Math.max(0, Math.min(100, root.phone ? root.phone.battery : 0)) / 100; height: parent.height; radius: parent.radius; color: percent.color; Behavior on width { NumberAnimation { duration: 200 } } }
                }
                Label { id: charge; anchors.verticalCenter: parent.verticalCenter; text: root.phone && root.phone.charging ? "Charging" : "Battery"; font.pixelSize: Style.font.caption; color: root.subdued }
              }
              PocketButton { visible: root.devices.length > 1; text: "Switch device  →"; focusable: true; foreground: root.ink; onClicked: root.nextDevice() }
            }
          }

          Label {
            width: parent.width; visible: !root.online
            text: root.connectionError || (root.phone ? "Open KDE Connect on your phone to reconnect. Your shortcuts will be ready when it returns." : "Open KDE Connect settings to pair your phone with this laptop.")
            color: root.subdued; wrapMode: Text.WordWrap
          }

          Column {
            width: parent.width; spacing: Style.space(8)
            ActionTile { width: parent.width; title: "Browse files"; detail: "Your phone’s shared storage"; glyph: "󰉋"; primary: true; verb: "files"; feature: "sftp"; height: Style.space(64) }
            Row {
              width: parent.width; spacing: Style.space(8)
              ActionTile { width: (parent.width - parent.spacing * 2) / 3; title: "Photos"; glyph: "󰋩"; verb: "photos"; feature: "sftp"; compact: true }
              ActionTile { width: (parent.width - parent.spacing * 2) / 3; title: "Downloads"; glyph: "󰇚"; verb: "downloads"; feature: "sftp"; compact: true }
              ActionTile { width: (parent.width - parent.spacing * 2) / 3; title: "Documents"; glyph: "󰈙"; verb: "documents"; feature: "sftp"; compact: true }
            }
            Row {
              width: parent.width; spacing: Style.space(8)
              QuickButton { width: (parent.width - parent.spacing * 2) / 3; text: "Send file"; iconText: "󰒍"; enabled: root.can("share") && !root.busy; onClicked: root.run("share") }
              QuickButton { width: (parent.width - parent.spacing * 2) / 3; text: "Clipboard"; iconText: "󰅍"; enabled: root.can("clipboard") && !root.busy; onClicked: root.run("clipboard") }
              QuickButton { width: (parent.width - parent.spacing * 2) / 3; text: "Ring"; iconText: "󰍡"; tooltipText: "Make your phone ring"; enabled: root.can("findmyphone") && !root.busy; onClicked: root.run("ring") }
            }
          }

          Label {
            width: parent.width; visible: root.busy || root.message !== ""
            text: root.busy ? (root.busyVerb === "share" ? "Choose a file in the file picker…" : "Working…") : root.message
            color: root.messageError ? Color.urgent : Color.accent; wrapMode: Text.WordWrap; font.pixelSize: Style.font.bodySmall
          }

          PanelSeparator { foreground: root.ink }
          Column {
            width: parent.width; spacing: Style.space(10)
            SectionLabel { text: "ON YOUR PHONE" }
            Row {
              width: parent.width; spacing: Style.space(12)
              Label { text: "󰎈"; font.pixelSize: Style.font.display; color: Color.accent }
              Column {
                width: parent.width - Style.space(48); spacing: Style.space(3)
                Label { width: parent.width; text: root.media.title || (root.playing ? "Ready to play" : "Nothing playing"); font.bold: true; elide: Text.ElideRight }
                Label { width: parent.width; text: root.media.artist || (root.online ? "Start music or a podcast on your phone" : "Reconnect to control playback"); font.pixelSize: Style.font.bodySmall; color: root.subdued; elide: Text.ElideRight }
              }
            }
            PocketButton {
              visible: (root.media.playerList || []).length > 0
              text: (root.media.player || "Select player") + ((root.media.playerList || []).length > 1 ? "  ⇄" : "")
              foreground: root.subdued; fontSize: Style.font.caption; focusable: true
              enabled: !root.busy; onClicked: root.nextPlayer()
            }
            Row {
              width: parent.width; spacing: Style.space(8)
              QuickButton { iconText: "󰒮"; tooltipText: "Previous track"; enabled: root.playing && !root.busy; onClicked: root.run("media", "Previous") }
              QuickButton { iconText: root.media.isPlaying ? "󰏤" : "󰐊"; tooltipText: root.media.isPlaying ? "Pause" : "Play"; selected: root.playing; enabled: root.playing && !root.busy; onClicked: root.run("media", "PlayPause") }
              QuickButton { iconText: "󰒭"; tooltipText: "Next track"; enabled: root.playing && !root.busy; onClicked: root.run("media", "Next") }
              Label { text: "󰕾"; color: root.subdued; anchors.verticalCenter: parent.verticalCenter }
              PanelSlider {
                width: Math.max(40, parent.width - Style.space(182)); anchors.verticalCenter: parent.verticalCenter
                bar: root.bar; minimum: 0; maximum: 100; step: 1; integer: true
                value: root.media.volume || 0; enabled: root.playing && !root.busy; opacity: enabled ? 1 : 0.35
                fillColor: Color.accent; knobColor: Color.accent; trackColor: Qt.alpha(root.ink, 0.12)
                onReleased: function(value) { root.run("volume", Math.round(value)) }
              }
            }
          }

          PanelSeparator { foreground: root.ink }
          Column {
            width: parent.width; spacing: Style.space(10)
            SectionLabel { text: "NOTIFICATIONS" + (root.notes.length ? "  /  " + root.notes.length : "") }
            Label {
              width: parent.width; visible: root.notes.length === 0
              text: !root.online ? "Notifications appear when your phone is connected." : !root.can("notifications") ? "Enable notification sync in KDE Connect on your phone." : "All quiet. You’re caught up."
              color: root.subdued; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap
            }
            Repeater {
              model: root.notes
              Rectangle {
                required property var modelData
                width: content.width
                height: notificationText.implicitHeight + Style.space(24)
                radius: Style.cornerRadius; color: Qt.alpha(root.ink, 0.035)
                Column {
                  id: notificationText
                  anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                  anchors.margins: Style.space(12); anchors.rightMargin: dismiss.visible ? Style.space(48) : Style.space(12)
                  spacing: Style.space(4)
                  Label { width: parent.width; text: modelData.app; color: Color.accent; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
                  Label { width: parent.width; text: modelData.title; visible: text !== ""; font.bold: true; wrapMode: Text.WordWrap }
                  Label { width: parent.width; text: modelData.body; visible: text !== ""; color: root.subdued; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WrapAnywhere }
                }
                PocketButton {
                  id: dismiss; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: Style.space(6)
                  visible: modelData.dismissable; enabled: !root.busy
                  iconText: "󰅖"; tooltipText: "Dismiss on phone"; foreground: root.subdued; focusable: true
                  onClicked: root.run("dismiss", modelData.id)
                }
              }
            }
          }

          PanelSeparator { foreground: root.ink }
          Row {
            width: parent.width
            Label { width: parent.width - settingsButton.width; anchors.verticalCenter: parent.verticalCenter; text: "KDE Connect  ·  Local connection"; color: root.subdued; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
            PocketButton { id: settingsButton; iconText: "󰒓"; tooltipText: "KDE Connect settings"; foreground: root.ink; focusable: true; onClicked: { Quickshell.execDetached(["kdeconnect-app"]); root.close() } }
          }
        }
      }
    }
  }

  component PocketButton: Button {
    onActiveFocusChanged: if (activeFocus) root.reveal(this)
  }
  component Label: Text {
    textFormat: Text.PlainText
    color: root.ink
    font.family: root.face
    font.pixelSize: Style.font.body
  }
  component SectionLabel: Label { font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1.5; color: root.subdued }
  component QuickButton: PocketButton { foreground: root.ink; fontFamily: root.face; fontSize: Style.font.bodySmall; focusable: true; bordered: true; horizontalPadding: Style.space(6); opacity: enabled ? 1 : 0.35 }
  component ActionTile: Rectangle {
    id: tile
    property string title: ""
    property string detail: ""
    property string glyph: ""
    property string verb: ""
    property string feature: ""
    property bool primary: false
    property bool compact: false
    enabled: root.can(feature) && !root.busy
    activeFocusOnTab: enabled
    onActiveFocusChanged: if (activeFocus) root.reveal(this)
    height: Style.space(68)
    radius: Style.cornerRadius
    opacity: enabled ? 1 : 0.35
    color: pointer.containsMouse || activeFocus ? Qt.alpha(Color.accent, 0.18) : Qt.alpha(Color.accent, primary ? 0.1 : 0.035)
    border.width: 1
    border.color: pointer.containsMouse || activeFocus ? Color.accent : Qt.alpha(root.ink, 0.13)
    Behavior on color { ColorAnimation { duration: 120 } }
    Accessible.role: Accessible.Button
    Accessible.name: title
    Accessible.onPressAction: if (enabled) root.run(verb)
    Keys.onReturnPressed: root.run(verb)
    Keys.onSpacePressed: root.run(verb)
    MouseArea { id: pointer; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.run(tile.verb) }
    Column {
      visible: tile.compact; anchors.centerIn: parent; spacing: Style.space(5)
      Label { anchors.horizontalCenter: parent.horizontalCenter; text: tile.glyph; color: Color.accent; font.pixelSize: Style.font.heading }
      Label { anchors.horizontalCenter: parent.horizontalCenter; text: tile.title; font.pixelSize: Style.font.caption }
    }
    Row {
      visible: !tile.compact; anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; anchors.margins: Style.space(14); spacing: Style.space(12)
      Label { anchors.verticalCenter: parent.verticalCenter; text: tile.glyph; color: Color.accent; font.pixelSize: Style.font.heading }
      Column {
        width: parent.width - Style.space(62); spacing: Style.space(3)
        Label { text: tile.title; font.bold: true }
        Label { text: tile.detail; font.pixelSize: Style.font.caption; color: root.subdued }
      }
      Label { anchors.verticalCenter: parent.verticalCenter; text: "↗"; color: Color.accent }
    }
  }
}
