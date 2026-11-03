import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: Model.PLUGIN_ID

  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(moduleName) : null
  readonly property bool live: service ? service.live === true : false
  readonly property int threats: service ? service.threatCount : 0
  readonly property int blocked: service ? service.blockCount : 0
  readonly property color barColor: bar ? bar.barForeground : Color.foreground
  readonly property color iconColor: live ? barColor : Qt.darker(barColor, 1.6)

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = root.service
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onServiceChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.service ? Model.tooltipText(root.service.tooltip) : "Firewall Map+"
    labelText: root.threats > 0 ? String(root.threats) : ""
    iconComponent: Component {
      Item {
        Canvas {
          id: shield
          anchors.fill: parent
          property bool live: root.live
          property int threatCount: root.threats
          onLiveChanged: requestPaint()
          onThreatCountChanged: requestPaint()
          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var w = width, h = height
            if (w <= 0 || h <= 0) return
            ctx.strokeStyle = root.iconColor
            ctx.lineWidth = Math.max(1, w * 0.09)
            ctx.lineJoin = "round"
            ctx.beginPath()
            ctx.moveTo(w * 0.16, h * 0.10)
            ctx.lineTo(w * 0.84, h * 0.10)
            ctx.lineTo(w * 0.84, h * 0.46)
            ctx.quadraticCurveTo(w * 0.84, h * 0.78, w * 0.5, h * 0.93)
            ctx.quadraticCurveTo(w * 0.16, h * 0.78, w * 0.16, h * 0.46)
            ctx.closePath()
            ctx.stroke()

            // A tiny globe: one meridian and one parallel inside the shield.
            ctx.globalAlpha = root.live ? 0.9 : 0.45
            ctx.beginPath()
            ctx.moveTo(w * 0.5, h * 0.27)
            ctx.lineTo(w * 0.5, h * 0.66)
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(w * 0.28, h * 0.45)
            ctx.quadraticCurveTo(w * 0.5, h * 0.36, w * 0.72, h * 0.45)
            ctx.moveTo(w * 0.28, h * 0.45)
            ctx.quadraticCurveTo(w * 0.5, h * 0.54, w * 0.72, h * 0.45)
            ctx.stroke()
            ctx.globalAlpha = 1
          }
        }

        Rectangle {
          visible: root.threats > 0
          width: Math.max(4, shield.width * 0.34)
          height: width
          radius: width / 2
          color: "#ff5d7a"
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.rightMargin: -1
          anchors.bottomMargin: -1
          border.width: 1
          border.color: bar ? bar.background : Color.background
        }
      }
    }
    onPressed: function(mouse) {
      if (!root.bar) return
      if (mouse === Qt.RightButton) {
        if (root.service) root.service.openFirewallPage()
      } else if (mouse === Qt.MiddleButton) {
        if (root.service) root.service.restartBridge()
      } else {
        root.toggle()
      }
    }
  }
}
