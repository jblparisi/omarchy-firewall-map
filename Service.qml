import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Owns the bridge that logs in to OPNsense and polls Firewall Map+. One
// instance runs for the whole shell, shared by every monitor's bar widget.
Item {
  id: root

  property var shell: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string credentialsPath: home + Model.CREDENTIALS_PATH
  readonly property string bridgePath: Qt.resolvedUrl("bridge.py").toString().replace(/^file:\/\//, "")
  readonly property string credentialsWriterPath: Qt.resolvedUrl("credentials.py").toString().replace(/^file:\/\//, "")
  readonly property var config: Model.pluginSettings(shell ? { bar: shell.barConfig } : null, Model.PLUGIN_ID)

  property var summary: ({})
  property real receivedAt: 0
  property int nowTick: 0
  property bool connected: false
  property bool bridgeRunning: false
  property bool credentialsReady: false
  property string username: ""
  property string errorText: ""
  property string stateText: "Waiting for credentials"
  property string startedConfig: ""
  property var blockedHosts: []
  property string blockingError: ""
  property bool hostsReady: false
  property bool actionBusy: false
  property bool actionFailed: false
  property string actionMessage: ""
  property string actionIp: ""
  property string lastPayload: ""
  property real sampleAge: 0
  property string pendingCredentials: ""
  property string credentialsError: ""

  readonly property int flowCount: summary && Array.isArray(summary.flows) ? summary.flows.length : 0
  readonly property int blockCount: Model.blockedTotal(summary)
  readonly property int threatCount: Model.threatCount(summary)
  readonly property int trackedFlows: summary ? Number(summary.tracked_flows) || 0 : 0
  readonly property real age: {
    var tick = nowTick // re-evaluate four times per second
    if (!summary || !receivedAt) return -1
    return sampleAge + Math.max(0, (Date.now() - receivedAt) / 1000)
  }
  readonly property bool live: connected && age >= 0 && age < 15
  readonly property string statusLine: {
    if (credentialsError !== "") return credentialsError
    if (!credentialsReady) return "Not configured"
    if (live) return "Live · " + Model.formatAge(age) + " old · polling " + config.interval + "s"
    if (errorText !== "") return errorText
    if (connected && age >= 0) return "Stale · " + Model.formatAge(age) + " old"
    return "Connecting…"
  }
  readonly property string tooltip: {
    if (!credentialsReady) return "Firewall Map+: set credentials"
    if (live) {
      var line = "Firewall Map+: " + flowCount + " flows · " + blockCount + " blocked · " + threatCount + " threats"
      var top = Model.topTalkers(summary, 1)
      if (top.length > 0) line += " · top " + top[0].label + " " + Model.formatRate(top[0].rate)
      return line
    }
    return "Firewall Map+: " + statusLine
  }

  function restartBridge() {
    connected = false
    hostsReady = false
    startedConfig = signature()
    if (bridge.running) bridge.running = false
    starter.restart()
  }

  function signature() {
    return config.url + "|" + config.interval + "|" + config.blocksMin + "|" + config.showHostnames
  }

  function startBridge() {
    if (!credentialsReady || bridge.running) return
    startedConfig = signature()
    bridge.command = [
      "python3", bridgePath,
      "--base", config.url,
      "--credentials", credentialsPath,
      "--interval", String(config.interval),
      "--blocks-min", String(config.blocksMin)
    ]
    if (!config.showHostnames) bridge.command = bridge.command.concat(["--no-hostnames"])
    bridge.running = true
  }

  function handleLine(line) {
    var text = String(line || "").trim()
    if (text === "") return
    var document
    try {
      document = JSON.parse(text)
    } catch (error) {
      return
    }
    if (document && document.type === "action") {
      actionBusy = false
      hostsReady = false
      actionFailed = document.ok !== true
      actionMessage = String(document.message || "No response from firewall")
      return
    }
    if (document && document.type === "hosts") {
      blockingError = String(document.error || "")
      hostsReady = blockingError === ""
      if (hostsReady) blockedHosts = Array.isArray(document.hosts) ? document.hosts : []
      return
    }
    if (!document || document.status === "bridge_error") {
      connected = false
      errorText = document && document.error ? String(document.error) : "Cannot reach OPNsense"
      stateText = errorText
      return
    }
    if (document.status !== "ok") {
      connected = false
      errorText = document.reason ? String(document.reason).replace(/_/g, " ") : String(document.status || "Unavailable")
      stateText = errorText
      return
    }
    // Heartbeats refresh age without repainting unchanged maps.
    var payload = JSON.stringify([document.sampled_at, document.flows, document.locations,
      document.blocks, document.hostnames, document.tracked_flows, document.blocks_below])
    if (payload !== lastPayload) {
      summary = document
      lastPayload = payload
    }
    sampleAge = Math.max(0, Number(document.age) || 0)
    receivedAt = Date.now()
    connected = true
    errorText = ""
    stateText = "Live"
  }

  function sendCommand(command) {
    if (!bridge.running) return false
    bridge.write(JSON.stringify(command) + "\n")
    return true
  }

  function refresh() { if (!sendCommand({action: "refresh"})) restartBridge() }

  function hostBlocked(ip) {
    return blockedHosts.some(function(host) { return host.ip === ip })
  }

  function changeHost(ip, block) {
    if (actionBusy) return
    actionIp = String(ip)
    if (!connected || !hostsReady) {
      actionFailed = true
      actionMessage = !connected ? "Connect to the firewall before changing a host block"
        : blockingError || "Checking firewall block status; try again in a moment"
      if (connected) sendCommand({action: "hosts"})
      return
    }
    actionBusy = true
    actionFailed = false
    actionMessage = (block ? "Blocking " : "Unblocking ") + ip + "…"
    if (!sendCommand({action: block ? "block" : "unblock", ip: String(ip)})) {
      actionBusy = false
      actionFailed = true
      actionMessage = "Bridge stopped; reconnect and try again"
    }
  }

  function updateCredentials(user, password) {
    if (credentialsWriter.running) return
    var nextUser = String(user || "").trim()
    var nextPassword = String(password || "")
    if (nextPassword === "") {
      nextPassword = Model.parseCredentials(credentialsFile.text()).password
    }
    credentialsError = ""
    pendingCredentials = Model.credentialsText(nextUser, nextPassword)
    credentialsWriter.running = true
  }

  function openFirewallPage() {
    openPage.command = ["omarchy", "launch", "browser", config.url + "/ui/firewallmap"]
    openPage.running = true
  }

  FileView {
    id: credentialsFile
    path: root.credentialsPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      var text = credentialsFile.text()
      root.credentialsReady = Model.hasCredentials(text)
      root.username = Model.parseCredentials(text).username
      if (root.credentialsReady) root.startBridge()
    }
    onFileChanged: reload()
    onLoadFailed: {
      root.credentialsReady = false
      root.username = ""
      root.connected = false
      if (bridge.running) bridge.running = false
    }
  }

  Process {
    id: credentialsWriter
    command: ["python3", root.credentialsWriterPath, root.credentialsPath]
    stdinEnabled: true
    onStarted: {
      write(root.pendingCredentials)
      root.pendingCredentials = ""
    }
    onExited: function(exitCode) {
      root.pendingCredentials = ""
      if (exitCode === 0) credentialsFile.reload()
      else root.credentialsError = "Could not save credentials; check the fields and directory permissions."
    }
  }

  Process {
    id: bridge
    command: []
    stdinEnabled: true
    onRunningChanged: root.bridgeRunning = running
    stdout: SplitParser {
      onRead: function(line) { root.handleLine(line) }
    }
    stderr: SplitParser {
      onRead: function(line) {
        var text = String(line || "")
        if (text.indexOf("Traceback") !== -1 || text.indexOf("Error") !== -1)
          console.warn("firewall-map bridge:", text)
      }
    }
    onExited: {
      root.connected = false
      root.hostsReady = false
      if (root.actionBusy) {
        root.actionBusy = false
        root.actionFailed = true
        root.actionMessage = "Connection interrupted; refresh blocked hosts to check the result"
      }
      if (root.errorText === "") root.stateText = "Bridge stopped"
      retry.restart()
    }
  }

  Process {
    id: openPage
    command: []
  }

  Timer {
    id: starter
    interval: 400
    repeat: false
    onTriggered: root.startBridge()
  }

  Timer {
    id: retry
    interval: 3000
    repeat: false
    onTriggered: root.startBridge()
  }

  // Keep the age display responsive; catch shell.json edits too.
  Timer {
    interval: 250
    running: true
    repeat: true
    onTriggered: {
      root.nowTick++
      if (root.signature() !== root.startedConfig && root.credentialsReady) root.restartBridge()
    }
  }
}
