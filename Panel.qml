import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: Model.PLUGIN_ID
  ipcTarget: Model.PLUGIN_ID
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null

  readonly property var barIdentity: hostWidget || root
  readonly property var summary: service ? service.summary : ({})
  readonly property bool live: service ? service.live === true : false
  readonly property string statusLine: service ? service.statusLine : "Connecting…"
  readonly property int flowCount: service ? service.flowCount : 0
  readonly property int blockCount: service ? service.blockCount : 0
  readonly property int threatCount: service ? service.threatCount : 0
  readonly property int trackedFlows: service ? service.trackedFlows : 0
  property string talkerMode: "remote"
  property string selectedIp: ""
  property string selectedName: ""
  property var mapCandidates: []
  property string mapMode: "remote"
  readonly property var talkers: talkerMode === "map"
    ? Model.refreshMapHosts(summary, mapCandidates, mapMode) : talkerMode === "sources"
    ? Model.hostsForBlocks(summary, summary.blocks || []) : talkerMode === "blocked"
    ? (service ? service.blockedHosts.map(function(host) {
        return {ip: host.ip, label: host.ip, name: "", rate: 0, flows: 0,
          location: {}, complete: host.complete}
      }) : []) : Model.topTalkers(summary,
        talkerMode === "threats" ? Math.max(1, (summary.flows || []).length) : 4, talkerMode)
  readonly property var config: service ? service.config : Model.defaults()
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property bool canManageHosts: service && service.connected && service.hostsReady && !service.actionBusy
  readonly property string hostActionStatus: {
    if (!service) return "Connecting to firewall…"
    if (service.actionBusy && service.actionMessage) return service.actionMessage
    if (!service.connected) return service.statusLine
    if (service.blockingError) return service.blockingError
    if (service.actionMessage && (!root.selectedIp || service.actionIp === root.selectedIp)) return service.actionMessage
    if (!service.hostsReady) return "Checking firewall block status…"
    return "Blocks this IP until you unblock it."
  }

  property bool showSettings: false
  property string editUrl: ""
  property string editUser: ""
  property string editPassword: ""
  property string editInterval: ""
  property bool editHostnames: true

  function selectHost(ip, name) {
    selectedIp = String(ip || "")
    selectedName = String(name || ip || "")
  }

  function clearHostSelection() {
    selectHost("", "")
    mapCandidates = []
    if (talkerMode === "map") talkerMode = "remote"
  }

  function showHostList(mode) {
    clearHostSelection()
    talkerMode = mode
    showSettings = false
    if (service && mode === "blocked") service.sendCommand({action: "hosts"})
  }

  function changeHost(ip, name) {
    selectHost(ip, name)
    if (service) service.changeHost(selectedIp, !service.hostBlocked(selectedIp))
  }

  function selectMapHosts(hosts, mode) {
    mapCandidates = hosts
    mapMode = mode
    talkerMode = "map"
    selectHost(hosts.length === 1 ? hosts[0].ip : "", hosts.length === 1 ? hosts[0].label : "")
  }

  function open() {
    root.controller.show()
    if (root.service) root.service.refresh()
    Qt.callLater(function() { if (root.opened) setCenterHoverRevealSuppressed(true) })
  }

  function openFromHotkey() {
    root.open()
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    showSettings = false
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function startSettings() {
    editUrl = config.url
    editUser = service ? service.username : ""
    editPassword = ""
    editInterval = String(config.interval)
    editHostnames = config.showHostnames
    showSettings = true
  }

  function saveSettings() {
    if (!service) return
    var interval = Math.max(1, Math.min(30, parseInt(editInterval, 10) || 1))
    var entry = Model.entryWith(service.config, {
      url: Model.normalizeUrl(editUrl),
      interval: interval,
      showHostnames: editHostnames
    })
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(Model.PLUGIN_ID, entry)
    service.updateCredentials(editUser, editPassword)
    showSettings = false
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(960))
    contentHeight: panel.fittedContentHeight(Style.space(680))

    content: PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.showSettings
      onCloseRequested: root.showSettings ? root.showSettings = false : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        anchors.fill: parent
        spacing: Style.space(12)

        // ---- header ---------------------------------------------------
        RowLayout {
          id: header
          width: parent.width
          spacing: Style.space(12)

          Item {
            implicitWidth: Style.space(26)
            implicitHeight: Style.space(26)
            Canvas {
              anchors.fill: parent
              onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var w = width, h = height
                ctx.strokeStyle = root.foreground
                ctx.lineWidth = 1.4
                ctx.beginPath()
                ctx.moveTo(w * 0.16, h * 0.12)
                ctx.lineTo(w * 0.84, h * 0.12)
                ctx.lineTo(w * 0.84, h * 0.46)
                ctx.quadraticCurveTo(w * 0.84, h * 0.78, w * 0.5, h * 0.92)
                ctx.quadraticCurveTo(w * 0.16, h * 0.78, w * 0.16, h * 0.46)
                ctx.closePath()
                ctx.stroke()
                ctx.fillStyle = root.live ? "#37d6a0" : Qt.darker(root.foreground, 1.8)
                ctx.beginPath()
                ctx.arc(w * 0.5, h * 0.44, w * 0.09, 0, Math.PI * 2)
                ctx.fill()
              }
            }
          }

          Column {
            Layout.alignment: Qt.AlignVCenter
            spacing: 1
            Text {
              textFormat: Text.PlainText
              text: "Firewall Map+"
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Text {
              textFormat: Text.PlainText
              text: root.statusLine
              color: root.live ? "#37d6a0" : (root.service && root.service.errorText ? Commons.Color.urgent : root.dim)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Item { Layout.fillWidth: true }

          Row {
            Layout.alignment: Qt.AlignVCenter
            spacing: Style.space(18)

            Repeater {
              model: [
                { label: "flows", key: "remote", value: root.flowCount, hint: "Show remote hosts" },
                { label: "blocked", key: "sources", value: root.blockCount, hint: "Show blocked traffic sources" },
                { label: "threats", key: "threats", value: root.threatCount, urgent: true, hint: "Show hosts with threat flows" }
              ]
              Button {
                objectName: "firewall-show-" + modelData.label
                text: Model.formatCount(modelData.value) + "\n" + modelData.label
                tooltipText: modelData.hint
                selected: !root.showSettings && root.talkerMode === modelData.key
                bordered: true
                horizontalPadding: Style.space(7)
                verticalPadding: Style.space(4)
                fontSize: Style.font.caption
                foreground: modelData.urgent && modelData.value > 0 ? Commons.Color.urgent : root.foreground
                Accessible.name: modelData.hint
                onClicked: root.showHostList(modelData.key)
              }
            }
          }

          Row {
            Layout.alignment: Qt.AlignVCenter
            spacing: Style.space(6)

            Button {
              text: "Open firewall"
              bordered: true
              fontSize: Style.font.caption
              foreground: root.foreground
              onClicked: if (root.service) root.service.openFirewallPage()
            }

            Button {
              text: root.showSettings ? "Close" : "Settings"
              bordered: true
              fontSize: Style.font.caption
              foreground: root.foreground
              onClicked: root.showSettings ? root.showSettings = false : root.startSettings()
            }
          }
        }

        // ---- map ------------------------------------------------------
        Map {
          id: map
          width: parent.width
          height: Math.max(Style.space(100), content.height - header.height - talkerFooter.height - legend.height - content.spacing * 3)
          visible: !root.showSettings
          summary: root.summary
          paused: !root.opened || root.showSettings
          foreground: root.foreground
          accent: Commons.Color.accent
          urgent: Commons.Color.urgent
          selectedIp: root.selectedIp
          onHostsSelected: function(hosts, mode) { root.selectMapHosts(hosts, mode) }
          onBackgroundClicked: root.showHostList("remote")

          Row {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(8)
            spacing: Style.space(4)
            Button {
              objectName: "firewall-map-zoom-out"
              text: "−"
              tooltipText: "Zoom out"
              enabled: map.zoom > 1
              bordered: true
              background: Commons.Color.background
              foreground: root.foreground
              fontSize: Style.font.caption
              onClicked: map.zoomAt(1 / 1.4, map.width / 2, map.height / 2)
            }
            Button {
              objectName: "firewall-map-zoom-in"
              text: "+"
              tooltipText: "Zoom in"
              enabled: map.zoom < 6
              bordered: true
              background: Commons.Color.background
              foreground: root.foreground
              fontSize: Style.font.caption
              onClicked: map.zoomAt(1.4, map.width / 2, map.height / 2)
            }
            Button {
              objectName: "firewall-map-fit"
              text: "Fit"
              tooltipText: "Fit the whole world"
              bordered: true
              background: Commons.Color.background
              foreground: root.foreground
              fontSize: Style.font.caption
              onClicked: map.fitWorld()
            }
          }
        }

        Column {
          id: legend
          objectName: "firewall-map-legend"
          width: parent.width
          visible: !root.showSettings
          spacing: Style.space(4)

          Flow {
            width: parent.width
            spacing: Style.space(16)
            Repeater {
              model: [
                { label: "Green: outbound / two-way", colour: map.outboundColor },
                { label: "Amber: inbound", colour: map.inboundColor },
                { label: "Red: blocked / threat", colour: map.blockedColor }
              ]
              Row {
                spacing: Style.space(6)
                Rectangle {
                  width: Style.space(22)
                  height: Style.space(2)
                  anchors.verticalCenter: parent.verticalCenter
                  color: modelData.colour
                }
                Text {
                  textFormat: Text.PlainText
                  text: modelData.label
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: "Drag to move · Scroll to zoom · Fit resets the view. Dots show direction; thicker lines carry more traffic."
              + (root.summary && root.summary.provider
                ? "  ·  " + String(root.summary.provider).toUpperCase() + "  ·  " + root.trackedFlows + " states" : "")
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // Individual host identities stay separate from the merged map arcs.
        Column {
          id: talkerFooter
          width: parent.width
          height: implicitHeight
          spacing: Style.space(6)
          visible: !root.showSettings

          RowLayout {
            width: parent.width
            Text {
              textFormat: Text.PlainText
              text: root.talkerMode === "map" ? "Map selection · " + root.talkers.length + " hosts"
                : root.talkerMode === "sources" ? "Blocked sources · " + root.talkers.length + " hosts"
                : root.talkerMode === "threats" ? "Threat hosts · " + root.talkers.length + " hosts"
                : root.talkerMode === "blocked" ? "Managed blocks" : "Top talkers"
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Item { Layout.fillWidth: true }
            Repeater {
              model: [{key: "local", label: "Local hosts"}, {key: "remote", label: "Remote hosts"},
                {key: "blocked", label: "Managed blocks (" + (root.service ? root.service.blockedHosts.length : 0) + ")"}]
              Button {
                objectName: "firewall-list-" + modelData.key
                text: modelData.label
                selected: root.talkerMode === modelData.key
                bordered: true
                fontSize: Style.font.caption
                foreground: root.foreground
                onClicked: root.showHostList(modelData.key)
              }
            }
          }

          Flickable {
            id: talkerViewport
            width: parent.width
            height: Style.space(168)
            contentWidth: width
            contentHeight: talkerRow.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            Connections {
              target: root
              function onTalkerModeChanged() { talkerViewport.contentY = 0 }
            }
            Column {
              id: talkerRow
              width: parent.width
              spacing: Style.space(4)
              Repeater {
                model: root.talkers
                Rectangle {
                  id: card
                  required property var modelData
                  width: talkerViewport.width
                  height: Style.space(39)
                  radius: Style.cornerRadius
                  color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
                    root.selectedIp === modelData.ip ? 0.12 : 0.04)
                  border.width: 1
                  border.color: root.selectedIp === modelData.ip ? Commons.Color.accent
                    : modelData.threat ? Commons.Color.urgent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
                  MouseArea {
                    id: cardMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.selectHost(card.modelData.ip, card.modelData.label)
                    }
                  }
                  ToolTip {
                    visible: cardMouse.containsMouse
                    delay: 350
                    contentItem: Text {
                      textFormat: Text.PlainText
                      text: card.modelData.label + (card.modelData.name ? "\n" + card.modelData.ip : "")
                        + (card.modelData.interface ? "\n" + card.modelData.interface : "")
                      color: root.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                  }
                  RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(10)
                    anchors.rightMargin: Style.space(10)
                    spacing: Style.space(12)
                    Column {
                      Layout.fillWidth: true
                      spacing: 1
                      Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        text: card.modelData.label
                        color: card.modelData.threat ? Commons.Color.urgent : root.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                      Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        text: card.modelData.name ? card.modelData.ip
                          : root.talkerMode === "blocked" ? (card.modelData.complete ? "Blocked in both directions" : "Partial block · select to remove")
                          : card.modelData.interface || "IP address"
                        color: root.dim
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                      }
                    }
                    Text {
                      Layout.preferredWidth: Style.space(170)
                      textFormat: Text.PlainText
                      horizontalAlignment: Text.AlignRight
                      text: root.talkerMode === "blocked" ? "Until unblocked"
                        : card.modelData.blockedSource ? card.modelData.hits + " blocked hits"
                        : "↓ " + Model.formatRate(card.modelData.rateIn) + "  ↑ " + Model.formatRate(card.modelData.rateOut)
                      color: root.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                    Text {
                      Layout.preferredWidth: Style.space(100)
                      textFormat: Text.PlainText
                      horizontalAlignment: Text.AlignRight
                      text: root.talkerMode === "blocked" ? "Select to unblock"
                        : card.modelData.blockedSource ? card.modelData.perMinute.toFixed(1) + "/min" : Model.formatRate(card.modelData.rate)
                      color: root.dim
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                    Button {
                      objectName: "firewall-row-block-" + card.modelData.ip
                      readonly property bool blockedHost: root.service ? root.service.hostBlocked(card.modelData.ip) : false
                      text: root.service && root.service.actionBusy ? "Working…" : blockedHost ? "Unblock" : "Block"
                      enabled: root.canManageHosts
                      bordered: true
                      fontSize: Style.font.caption
                      foreground: blockedHost ? root.foreground : Commons.Color.urgent
                      onClicked: root.changeHost(card.modelData.ip, card.modelData.label)
                    }
                  }
                }
              }
            }
            Text {
              anchors.centerIn: parent
              visible: root.talkers.length === 0
              width: parent.width
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: root.talkerMode === "blocked" ? (root.service && root.service.blockingError
                  ? root.service.blockingError : "No hosts blocked from this widget")
                : !root.live ? root.statusLine
                : root.talkerMode === "sources" ? "No blocked sources meet the current minimum-hit filter"
                : root.talkerMode === "threats" ? "No threat hosts in this sample"
                : root.live ? "No active hosts in this sample" : root.statusLine
              color: root.dim
              horizontalAlignment: Text.AlignHCenter
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          RowLayout {
            width: parent.width
            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              elide: Text.ElideMiddle
              text: root.selectedIp ? root.selectedName + (root.selectedName !== root.selectedIp ? " · " + root.selectedIp : "")
                : root.talkerMode === "map" ? "Several hosts share this point. Select a host from the list."
                : root.talkerMode === "sources" && Number(root.summary.blocks_below) > 0
                  ? root.summary.blocks_below + " low-hit sources omitted by the minimum-hit filter."
                : "Click a map point, a connection, or a host row to select it."
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Button {
              objectName: "firewall-clear-host"
              visible: root.selectedIp !== "" || root.talkerMode === "map"
              text: "×"
              tooltipText: "Clear selected host"
              bordered: true
              fontSize: Style.font.caption
              foreground: root.foreground
              Accessible.name: "Clear selected host"
              onClicked: root.clearHostSelection()
            }
          }
          Text {
            width: parent.width
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: root.hostActionStatus
            color: root.service && (root.service.actionFailed || root.service.blockingError) ? Commons.Color.urgent : root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // ---- settings ------------------------------------------------
        Column {
          width: parent.width
          spacing: Style.space(10)
          visible: root.showSettings

          Text {
            textFormat: Text.PlainText
            text: "OPNsense connection"
            color: root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.display
            font.bold: true
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: "Traffic is polled every second by default. The firewall normally produces a new sample every two seconds. Hostnames use the firewall's reverse DNS cache. The password is kept in a 0600 file outside shell.json."
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Row {
            width: parent.width
            spacing: Style.space(10)

            Column {
              width: (parent.width - parent.spacing) * 0.6
              spacing: 3
              Text { textFormat: Text.PlainText; text: "Address"; color: root.dim; font.family: Style.font.family; font.pixelSize: Style.font.caption }
              TextField {
                id: urlField
                width: parent.width
                text: root.editUrl
                placeholderText: Model.DEFAULT_URL
                foreground: root.foreground
                onTextChanged: root.editUrl = text
              }
            }

            Column {
              width: (parent.width - parent.spacing) * 0.4 - Style.space(10)
              spacing: 3
              Text { textFormat: Text.PlainText; text: "Poll interval (seconds)"; color: root.dim; font.family: Style.font.family; font.pixelSize: Style.font.caption }
              TextField {
                width: parent.width
                text: root.editInterval
                placeholderText: "1"
                foreground: root.foreground
                onTextChanged: root.editInterval = text
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(10)

            Column {
              width: (parent.width - parent.spacing) / 2
              spacing: 3
              Text { textFormat: Text.PlainText; text: "Username"; color: root.dim; font.family: Style.font.family; font.pixelSize: Style.font.caption }
              TextField {
                width: parent.width
                text: root.editUser
                foreground: root.foreground
                onTextChanged: root.editUser = text
              }
            }

            Column {
              width: (parent.width - parent.spacing) / 2
              spacing: 3
              Text { textFormat: Text.PlainText; text: root.editPassword === "" ? "Password (leave empty to keep)" : "Password"; color: root.dim; font.family: Style.font.family; font.pixelSize: Style.font.caption }
              TextField {
                width: parent.width
                password: true
                text: root.editPassword
                foreground: root.foreground
                onTextChanged: root.editPassword = text
              }
            }
          }

          Row {
            spacing: Style.space(8)
            Button {
              text: root.editHostnames ? "Hostnames: on" : "Hostnames: off"
              bordered: true
              selected: root.editHostnames
              foreground: root.foreground
              onClicked: root.editHostnames = !root.editHostnames
              tooltipText: "Resolve hostnames using the firewall's reverse DNS cache."
            }
            Button {
              text: "Save"
              bordered: true
              foreground: root.foreground
              onClicked: root.saveSettings()
            }
            Button {
              text: "Cancel"
              bordered: true
              foreground: root.foreground
              onClicked: root.showSettings = false
            }
            Button {
              text: "Open firewall page"
              bordered: true
              foreground: root.foreground
              onClicked: if (root.service) root.service.openFirewallPage()
            }
          }
        }
      }
    }
  }
}
