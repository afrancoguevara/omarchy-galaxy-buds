import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// Galaxy Buds on the bar. buds-status.py keeps an RFCOMM link to the buds and
// streams JSON lines with per-bud and case battery, placement, noise control
// and PipeWire profiles; this panel renders them and drives connect/disconnect,
// noise control (over the helper's stdin) and the card profile.
Panel {
  id: root
  moduleName: "afrancoguevara.galaxy-buds"
  ipcTarget: "afrancoguevara.galaxy-buds"

  property var buds: ({ found: false })
  property string pendingAction: ""
  property string pendingProfile: ""
  property int pendingNoise: -1

  readonly property bool connected: buds.connected === true
  readonly property bool showPercentage: setting("showPercentage", false) === true

  // UI language: the widget's `language` setting ("es" or "en"), or the
  // system locale when it is "auto" or unset.
  readonly property string lang: {
    var value = String(setting("language", "auto"))
    if (value === "es" || value === "en") return value
    return Qt.locale().name.indexOf("es") === 0 ? "es" : "en"
  }

  readonly property var strings: lang === "es" ? {
    notFound: "No hay Galaxy Buds emparejados",
    connected: "Conectados",
    disconnected: "Desconectados",
    connecting: "Conectando…",
    disconnecting: "Desconectando…",
    connect: "Conectar",
    disconnect: "Desconectar",
    left: "Izquierdo",
    right: "Derecho",
    caseLabel: "Estuche",
    profile: "PERFIL DE AUDIO",
    noise: "CONTROL DE RUIDO",
    noiseModes: ["Apagado", "Cancelación", "Ambiente", "Adaptativo"],
    battery: "BATERÍA",
    placements: ["Sin conexión", "En el oído", "Fuera del oído", "En el estuche", "Estuche cerrado"],
    hifi: "Alta fidelidad",
    headset: "Manos libres (con micrófono)"
  } : {
    notFound: "No Galaxy Buds paired",
    connected: "Connected",
    disconnected: "Disconnected",
    connecting: "Connecting…",
    disconnecting: "Disconnecting…",
    connect: "Connect",
    disconnect: "Disconnect",
    left: "Left",
    right: "Right",
    caseLabel: "Case",
    profile: "AUDIO PROFILE",
    noise: "NOISE CONTROL",
    noiseModes: ["Off", "Cancelling", "Ambient", "Adaptive"],
    battery: "BATTERY",
    placements: ["Disconnected", "In ear", "Out of ear", "In case", "Case closed"],
    hifi: "High fidelity",
    headset: "Hands-free (with mic)"
  }

  readonly property string earbudsIcon: String.fromCodePoint(0xF184F)
  readonly property string earbudsOffIcon: String.fromCodePoint(0xF1850)

  // Lowest bud battery among the buds that report one, or -1.
  readonly property int lowestBattery: {
    var values = [buds.left, buds.right].filter(function(v) { return v !== undefined && v >= 0 })
    return values.length ? Math.min.apply(null, values) : -1
  }

  readonly property string statusText: {
    if (!buds.found) return strings.notFound
    if (pendingAction === "connect") return strings.connecting
    if (pendingAction === "disconnect") return strings.disconnecting
    return connected ? strings.connected : strings.disconnected
  }

  function batteryText(value) {
    return value !== undefined && value >= 0 ? value + "%" : "—"
  }

  function placementText(value) {
    return strings.placements[value] || ""
  }

  function batteryGlyph(value) {
    if (value === undefined || value < 0) return "󰂑"
    var glyphs = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
    return glyphs[Math.min(9, Math.floor(value / 10))]
  }

  // "a2dp-sink" -> "High fidelity · AAC", from PipeWire's description codec.
  function profileLabel(profile) {
    var codec = /codec ([^)]+)\)/.exec(profile.label || "")
    var kind = profile.id.indexOf("a2dp") === 0 ? strings.hifi
             : profile.id.indexOf("headset") === 0 ? strings.headset
             : profile.label
    return codec ? kind + " · " + codec[1] : kind
  }

  readonly property var profileOptions: (buds.profiles || []).map(function(p) {
    return { value: p.id, label: root.profileLabel(p) }
  })

  function toggleConnection() {
    if (!buds.found || !buds.address || pendingAction !== "") return
    pendingAction = connected ? "disconnect" : "connect"
    pendingTimeout.restart()
    Quickshell.execDetached(["omarchy-bluetooth-device", pendingAction, buds.address])
  }

  // Values match the buds' protocol: 0 off, 1 noise cancelling, 2 ambient, 3 adaptive.
  readonly property var noiseOptions: [1, 3, 2, 0].map(function(mode) {
    return { value: String(mode), label: root.strings.noiseModes[mode] }
  })

  function setNoise(mode) {
    if (!connected || mode === buds.noise || !statusProc.running) return
    pendingNoise = mode
    pendingTimeout.restart()
    statusProc.write("noise " + mode + "\n")
  }

  function setProfile(profile) {
    if (!buds.card || profile === buds.profile) return
    pendingProfile = profile
    Quickshell.execDetached(["pactl", "set-card-profile", buds.card, profile])
  }

  onBudsChanged: {
    if ((pendingAction === "connect" && connected) || (pendingAction === "disconnect" && !connected))
      pendingAction = ""
    if (pendingProfile !== "" && buds.profile === pendingProfile) pendingProfile = ""
    if (pendingNoise >= 0 && buds.noise === pendingNoise) pendingNoise = -1
  }

  readonly property string budsScript: Qt.resolvedUrl("buds-status.py").toString().replace("file://", "")

  Process {
    id: statusProc
    command: ["python3", "-I", root.budsScript, String(root.setting("address", ""))]
    // stdin must be open before the process starts, so start it only once
    // every property is set rather than through a `running: true` binding.
    stdinEnabled: true
    Component.onCompleted: running = true
    stdout: SplitParser {
      onRead: function(line) {
        try { root.buds = JSON.parse(line) } catch (e) {}
      }
    }
    onExited: restartTimer.restart()
  }

  // The helper only exits on a crash; bring it back without spinning.
  Timer {
    id: restartTimer
    interval: 5000
    onTriggered: statusProc.running = true
  }

  Timer {
    id: pendingTimeout
    interval: 20000
    onTriggered: { root.pendingAction = ""; root.pendingProfile = ""; root.pendingNoise = -1 }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    readonly property bool withPercentage: root.showPercentage && root.connected && root.lowestBattery >= 0 && !vertical
    // The icon goes in `text` and the percentage in `labelText`: BarIconButton
    // fits `text` into the icon canvas, so a "99% icon" string gets shrunk.
    text: root.connected ? root.earbudsIcon : root.earbudsOffIcon
    labelText: withPercentage ? root.lowestBattery + "%" : ""
    slotSize: Style.bar.iconSlot * (withPercentage ? 2 : 1)
    opacity: root.connected ? 1.0 : 0.6
    tooltipText: root.opened ? ""
      : root.connected
        ? root.strings.left[0] + " " + root.batteryText(root.buds.left) + " · "
          + root.strings.right[0] + " " + root.batteryText(root.buds.right) + " · "
          + root.strings.caseLabel + " " + root.batteryText(root.buds.case)
        : root.statusText
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleConnection()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: root.toggleConnection()

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(14)

        // ---------- Hero: earbuds icon · name · connect switch ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, connectSwitch.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.connected ? root.earbudsIcon : root.earbudsOffIcon
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            opacity: root.connected ? 1.0 : 0.5
          }

          ToggleSwitch {
            id: connectSwitch
            visible: root.buds.found === true
            checked: root.connected
            busy: root.pendingAction !== ""
            foreground: root.bar.foreground
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onToggled: root.toggleConnection()

            PanelToolTip {
              visible: connectSwitch.containsMouse
              text: root.connected ? root.strings.disconnect : root.strings.connect
              fontFamily: root.bar.fontFamily
            }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.rightMargin: connectSwitch.visible ? connectSwitch.width + Style.space(12) : 0
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: root.buds.name || "Galaxy Buds"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.statusText.toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }
        }

        PanelSeparator {
          visible: root.connected
          foreground: root.bar.foreground
        }

        // ---------- Battery: left · right · case ----------
        Column {
          visible: root.connected
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: root.strings.battery
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: batteryRow
            width: parent.width

            Repeater {
              model: [
                { label: root.strings.left, value: root.buds.left, placement: root.buds.leftPlacement },
                { label: root.strings.right, value: root.buds.right, placement: root.buds.rightPlacement },
                { label: root.strings.caseLabel, value: root.buds["case"], placement: -1 }
              ]

              Column {
                required property var modelData
                width: batteryRow.width / 3
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: root.batteryGlyph(modelData.value) + " " + root.batteryText(modelData.value)
                  color: modelData.value >= 0 && modelData.value <= 15 ? Commons.Color.urgent : root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.heading
                  opacity: modelData.value >= 0 ? 1.0 : 0.5
                }
                Text {
                  textFormat: Text.PlainText
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: modelData.label
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  textFormat: Text.PlainText
                  anchors.horizontalCenter: parent.horizontalCenter
                  visible: modelData.placement >= 0
                  text: root.placementText(modelData.placement)
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        PanelSeparator {
          visible: noiseControl.visible
          foreground: root.bar.foreground
        }

        // ---------- Noise control ----------
        Column {
          id: noiseControl
          visible: root.connected && root.buds.noise !== undefined && root.buds.noise >= 0
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: root.strings.noise
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          ButtonGroup {
            options: root.noiseOptions
            value: String(root.pendingNoise >= 0 ? root.pendingNoise : root.buds.noise)
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            focusable: false
            onChanged: function(value) { root.setNoise(parseInt(value)) }
          }
        }

        PanelSeparator {
          visible: root.connected && root.profileOptions.length > 0
          foreground: root.bar.foreground
        }

        // ---------- Audio profile ----------
        Column {
          id: profileList
          visible: root.connected && root.profileOptions.length > 0
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: root.strings.profile
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Repeater {
            model: root.profileOptions

            Button {
              required property var modelData
              width: profileList.width
              leftAlign: true
              text: modelData.label
              selected: (root.pendingProfile || root.buds.profile) === modelData.value
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              onClicked: root.setProfile(modelData.value)
            }
          }
        }
      }
    }
  }
}
