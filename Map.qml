import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model
import "World.js" as World

// A live, native rendering of the Firewall Map+ world map: land outlines in
// a fitted world view, an arch for every flow, pulsing traffic dots, red
// embers for blocked sources and a marker for the firewall itself.
Item {
  id: root

  property var summary: ({})
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property color urgent: Commons.Color.urgent
  property bool paused: true
  property int maxArcs: 150
  property string selectedIp: ""

  property var arcs: []
  property var blocks: []
  property var homeLocation: null
  property string hoverText: ""
  property var hoverArc: null
  property real hoverX: 0
  property real hoverY: 0
  property real elapsed: 0
  property real zoom: 1
  property real panX: 0
  property real panY: 0
  readonly property real mapPadding: Style.space(16)
  readonly property real mapScale: Math.max(0, Math.min(
    (width - mapPadding * 2) / 360, (height - mapPadding * 2) / 180))

  signal hostsSelected(var hosts, string mode)
  signal backgroundClicked()

  onSelectedIpChanged: flow.requestPaint()

  readonly property color outboundColor: "#37d6a0"
  readonly property color inboundColor: "#f3a45c"
  readonly property color blockedColor: "#ff5d7a"
  readonly property color landColor: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.10)
  readonly property color coastColor: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.26)
  readonly property color gridColor: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.055)

  function project(latitude, longitude) {
    var lon = Number(longitude)
    var lat = Number(latitude)
    if (!isFinite(lon) || !isFinite(lat)) return null
    // Fit all latitudes without clamping southern land to the bottom edge.
    // One scale for both axes keeps the geography consistent on short popups.
    var scale = mapScale * zoom
    return {
      x: width / 2 + panX + lon * scale,
      y: height / 2 + panY - Math.max(-90, Math.min(90, lat)) * scale
    }
  }

  function clearHover() {
    hoverArc = null
    hoverText = ""
  }

  function clampPan() {
    var limitX = Math.max(width / 2, (360 * mapScale * zoom - width) / 2 + mapPadding)
    var limitY = Math.max(height / 2, (180 * mapScale * zoom - height) / 2 + mapPadding)
    panX = Math.max(-limitX, Math.min(limitX, panX))
    panY = Math.max(-limitY, Math.min(limitY, panY))
  }

  function panBy(dx, dy) {
    panX += dx
    panY += dy
    clampPan()
    clearHover()
  }

  function zoomAt(factor, x, y) {
    var next = Math.max(1, Math.min(6, zoom * factor))
    var ratio = next / zoom
    panX = (x - width / 2) * (1 - ratio) + panX * ratio
    panY = (y - height / 2) * (1 - ratio) + panY * ratio
    zoom = next
    clampPan()
    clearHover()
  }

  function fitWorld() {
    zoom = 1
    panX = 0
    panY = 0
    clearHover()
  }

  function rebuild() {
    arcs = Model.buildArcs(summary)
    blocks = Model.buildBlocks(summary)
    homeLocation = Model.home(summary)
    flow.requestPaint()
  }

  function repaint() {
    if (land.available) land.requestPaint()
    if (flow.available) flow.requestPaint()
  }

  onSummaryChanged: rebuild()
  Component.onCompleted: { rebuild(); Qt.callLater(repaint) }

  // A hidden popup can lose its canvas texture. Repaint both layers on
  // return, even when the collector has sent an unchanged heartbeat.
  onVisibleChanged: if (visible) Qt.callLater(repaint)
  onPausedChanged: if (!paused) Qt.callLater(repaint)
  onForegroundChanged: Qt.callLater(repaint)
  onAccentChanged: Qt.callLater(repaint)
  onZoomChanged: Qt.callLater(repaint)
  onPanXChanged: Qt.callLater(repaint)
  onPanYChanged: Qt.callLater(repaint)
  onWidthChanged: Qt.callLater(repaint)
  onHeightChanged: Qt.callLater(repaint)

  Timer {
    interval: 33
    running: !root.paused && root.visible && flow.available
    repeat: true
    onTriggered: {
      root.elapsed = Date.now() / 1000
      flow.requestPaint()
    }
  }

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.035)
    border.width: 1
    border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.10)
    clip: true

    Canvas {
      id: land
      objectName: "firewall-map-land"
      anchors.fill: parent
      onAvailableChanged: if (available) requestPaint()
      onPaint: {
        var ctx = getContext("2d")
        if (!ctx) return
        ctx.reset()
        if (width <= 0 || height <= 0) return

        // Graticule
        ctx.strokeStyle = root.gridColor
        ctx.lineWidth = 1
        for (var lon = -150; lon <= 150; lon += 30) {
          var x = root.project(0, lon).x
          ctx.beginPath()
          ctx.moveTo(x, 0)
          ctx.lineTo(x, height)
          ctx.stroke()
        }
        for (var lat = -30; lat <= 60; lat += 30) {
          var y = root.project(lat, 0).y
          ctx.beginPath()
          ctx.moveTo(0, y)
          ctx.lineTo(width, y)
          ctx.stroke()
        }

        // Draw every land ring, including the southern continents and poles.
        ctx.fillStyle = root.landColor
        ctx.strokeStyle = root.coastColor
        ctx.lineWidth = 1
        var rings = World.WORLD_LAND
        for (var r = 0; r < rings.length; r++) {
          var ring = rings[r]
          ctx.beginPath()
          for (var i = 0; i < ring.length; i++) {
            var point = root.project(ring[i][1], ring[i][0])
            if (!point) continue
            if (i === 0) ctx.moveTo(point.x, point.y)
            else ctx.lineTo(point.x, point.y)
          }
          ctx.closePath()
          ctx.fill()
          ctx.stroke()
        }
      }
    }

    Canvas {
      id: flow
      objectName: "firewall-map-flows"
      anchors.fill: parent
      onAvailableChanged: if (available) requestPaint()
      onPaint: root.paintFlows(getContext("2d"))
    }
  }

  function arcColor(arc) {
    if (arc.threat) return blockedColor
    if (arc.direction === "in") return inboundColor
    if (arc.direction === "both") return Qt.rgba(outboundColor.r, outboundColor.g, outboundColor.b, 0.8)
    return outboundColor
  }

  function arcWidth(rate) {
    return 0.8 + Math.max(0, Math.min(2.2, Math.log(1 + Math.max(0, rate)) / 8))
  }

  function bendFor(arc, origin, dest) {
    var dx = dest.x - origin.x
    var dy = dest.y - origin.y
    var distance = Math.hypot(dx, dy)
    if (distance < 1) return null
    var direction = Model.hash01(arc.key) < 0.5 ? -1 : 1
    var bend = Math.min(70, distance * 0.22) * direction
    return {
      x: (origin.x + dest.x) / 2 - dy / distance * bend,
      y: (origin.y + dest.y) / 2 + dx / distance * bend
    }
  }

  function pointOn(origin, control, dest, t) {
    var u = 1 - t
    return {
      x: u * u * origin.x + 2 * u * t * control.x + t * t * dest.x,
      y: u * u * origin.y + 2 * u * t * control.y + t * t * dest.y
    }
  }

  function paintFlows(ctx) {
    if (!ctx) return
    ctx.reset()
    if (width <= 0 || height <= 0) return

    var now = root.elapsed || (Date.now() / 1000)
    var origin = root.homeLocation ? root.project(root.homeLocation.lat, root.homeLocation.lon) : null
    if (!origin) return
    var homeX = origin.x
    var homeY = origin.y

    var count = Math.min(root.arcs.length, root.maxArcs)
    for (var i = 0; i < count; i++) {
      var arc = root.arcs[i]
      var from = root.project(arc.origin.lat, arc.origin.lon)
      var to = root.project(arc.dest.lat, arc.dest.lon)
      if (!from || !to) continue
      // The arch always joins the flow's two ends. Data pulses travel towards
      // the firewall for inbound traffic, away for outbound, one each way for
      // balanced connections.
      var start = from
      var end = to
      var control = root.bendFor(arc, start, end)
      if (!control) continue

      var colour = root.arcColor(arc)
      var highlighted = (root.hoverArc && root.hoverArc.key === arc.key)
        || (root.selectedIp !== "" && (arc.flowMembers || []).some(function(member) {
          return member.origin === root.selectedIp || member.dest === root.selectedIp
            || (member.inside || []).some(function(host) { return host.ip === root.selectedIp })
        }))
      var strokeWidth = highlighted ? root.arcWidth(arc.rate) + 1.4 : root.arcWidth(arc.rate)
      var alpha = 0.32 + Math.min(0.5, Math.log(1 + arc.rate) / 20)
      if (arc.threat) alpha = Math.max(alpha, 0.6)
      ctx.strokeStyle = Qt.rgba(colour.r, colour.g, colour.b, alpha)
      ctx.lineWidth = strokeWidth
      ctx.beginPath()
      ctx.moveTo(start.x, start.y)
      ctx.quadraticCurveTo(control.x, control.y, end.x, end.y)
      ctx.stroke()

      // A pulse or two per arch; the speed follows the data rate, so busy
      // connections visibly move faster.
      var speed = 0.10 + Math.min(0.5, Math.log(1 + Math.max(0, arc.rate)) / 30)
      var phase = Model.hash01(arc.key)
      var burst = arc.rate > 250000 ? 2 : 1
      var forward = arc.direction !== "in"
      var reverse = arc.direction !== "out"
      for (var p = 0; p < burst; p++) {
        var base = (now * speed + phase + p * 0.5) % 1
        if (forward) {
          var outboundDot = root.pointOn(start, control, end, base)
          ctx.fillStyle = Qt.rgba(colour.r, colour.g, colour.b, 0.95)
          ctx.beginPath()
          ctx.arc(outboundDot.x, outboundDot.y, arc.threat ? 2.1 : 1.5, 0, Math.PI * 2)
          ctx.fill()
        }
        if (reverse) {
          var inboundDot = root.pointOn(start, control, end, 1 - base)
          ctx.fillStyle = Qt.rgba(colour.r, colour.g, colour.b, 0.95)
          ctx.beginPath()
          ctx.arc(inboundDot.x, inboundDot.y, arc.threat ? 2.1 : 1.5, 0, Math.PI * 2)
          ctx.fill()
        }
      }

      // Remote endpoints get a dot in either connection direction.
      ctx.fillStyle = Qt.rgba(colour.r, colour.g, colour.b, 0.9)
      var endpoints = []
      if (arc.origin.local !== true) endpoints.push(start)
      if (arc.dest.local !== true) endpoints.push(end)
      for (var e = 0; e < endpoints.length; e++) {
        ctx.beginPath()
        ctx.arc(endpoints[e].x, endpoints[e].y, highlighted ? 3.5 : 2.5, 0, Math.PI * 2)
        ctx.fill()
      }
      if (arc.threat) {
        ctx.strokeStyle = Qt.rgba(root.blockedColor.r, root.blockedColor.g, root.blockedColor.b, 0.8)
        ctx.lineWidth = 1
        ctx.beginPath()
        ctx.arc(end.x, end.y, 4.5 + Math.sin(now * 3 + phase * 6) * 1.2, 0, Math.PI * 2)
        ctx.stroke()
      }
    }

    // Blocked sources pulse towards the firewall.
    var blockLimit = Math.min(root.blocks.length, 70)
    for (var b = 0; b < blockLimit; b++) {
      var block = root.blocks[b]
      var source = root.project(block.lat, block.lon)
      if (!source) continue
      ctx.fillStyle = Qt.rgba(root.blockedColor.r, root.blockedColor.g, root.blockedColor.b, 0.9)
      ctx.beginPath()
      ctx.arc(source.x, source.y, block.source === root.selectedIp ? 4 : 2.5, 0, Math.PI * 2)
      ctx.fill()
      ctx.strokeStyle = Qt.rgba(root.blockedColor.r, root.blockedColor.g, root.blockedColor.b, 0.13)
      ctx.lineWidth = 1
      ctx.beginPath()
      ctx.moveTo(source.x, source.y)
      ctx.lineTo(homeX, homeY)
      ctx.stroke()
      var travel = (now * (0.25 + Math.min(0.35, block.perMinute / 60)) + Model.hash01(block.key)) % 1
      var px = source.x + (homeX - source.x) * travel
      var py = source.y + (homeY - source.y) * travel
      ctx.fillStyle = Qt.rgba(root.blockedColor.r, root.blockedColor.g, root.blockedColor.b, 0.9)
      ctx.beginPath()
      ctx.arc(px, py, 1.7, 0, Math.PI * 2)
      ctx.fill()
    }

    // The firewall: a ring that breathes, plus a small house.
    var halo = 8 + Math.sin(now * 2.2) * 2
    ctx.strokeStyle = Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.45)
    ctx.lineWidth = 1
    ctx.beginPath()
    ctx.arc(homeX, homeY, halo, 0, Math.PI * 2)
    ctx.stroke()
    ctx.fillStyle = Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.95)
    ctx.beginPath()
    ctx.arc(homeX, homeY, 3.4, 0, Math.PI * 2)
    ctx.fill()
    ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.55)
    ctx.lineWidth = 1
    ctx.beginPath()
    ctx.arc(homeX, homeY, 1.4, 0, Math.PI * 2)
    ctx.stroke()
  }

  // ---- hover -----------------------------------------------------------

  property real mouseX: -1
  property real mouseY: -1

  function nearestArc(mx, my) {
    var origin = root.homeLocation ? root.project(root.homeLocation.lat, root.homeLocation.lon) : null
    if (!origin) return null
    var best = null
    var bestDistance = 12
    var count = Math.min(root.arcs.length, root.maxArcs)
    for (var i = 0; i < count; i++) {
      var arc = root.arcs[i]
      var from = root.project(arc.origin.lat, arc.origin.lon)
      var to = root.project(arc.dest.lat, arc.dest.lon)
      if (!from || !to) continue
      var start = from
      var end = to
      var control = root.bendFor(arc, start, end)
      if (!control) continue
      var previous = start
      for (var s = 1; s <= 24; s++) {
        var point = root.pointOn(start, control, end, s / 24)
        var distance = Model.segmentDistance(mx, my, previous, point)
        previous = point
        if (distance < bestDistance) {
          bestDistance = distance
          best = arc
        }
      }
    }
    return best
  }

  function pickAt(mx, my) {
    var home = root.homeLocation ? root.project(root.homeLocation.lat, root.homeLocation.lon) : null
    if (!home) return null
    var localHosts = Math.hypot(home.x - mx, home.y - my) <= Style.space(12)
      ? Model.topTalkers(summary, Math.max(1, (summary.flows || []).length), "local") : []
    var arcsAtPoint = []
    var count = Math.min(root.arcs.length, root.maxArcs)
    for (var i = 0; i < count; i++) {
      var arc = root.arcs[i]
      var ends = [arc.origin, arc.dest]
      for (var j = 0; j < ends.length; j++) {
        if (ends[j].local === true) continue
        var point = root.project(ends[j].lat, ends[j].lon)
        if (point && Math.hypot(point.x - mx, point.y - my) <= Style.space(10)) {
          arcsAtPoint.push(arc)
          break
        }
      }
    }
    var blocksAtPoint = []
    for (var b = 0; b < Math.min(root.blocks.length, 70); b++) {
      var block = root.blocks[b]
      var source = root.project(block.lat, block.lon)
      if (source && Math.hypot(source.x - mx, source.y - my) <= Style.space(10)) blocksAtPoint.push(block)
    }
    var hosts = Model.hostsForArcs(summary, arcsAtPoint)
    var blockedHosts = Model.hostsForBlocks(summary, blocksAtPoint)
    if (localHosts.length) {
      if (!hosts.length && !blockedHosts.length) return {hosts: localHosts, mode: "local"}
      hosts = hosts.concat(localHosts)
    }
    if (hosts.length) {
      for (var h = 0; h < blockedHosts.length; h++) {
        var candidate = blockedHosts[h]
        if (!hosts.some(function(host) { return host.ip === candidate.ip })) hosts.push(candidate)
      }
      return {hosts: hosts, mode: localHosts.length ? "mixed" : "remote"}
    }
    if (blockedHosts.length) return {hosts: blockedHosts, mode: "blocked"}
    var nearest = root.nearestArc(mx, my)
    if (!nearest) return null
    hosts = Model.hostsForArcs(summary, [nearest])
    return hosts.length ? {hosts: hosts, mode: "remote"} : null
  }

  function selectAt(mx, my) {
    var selection = pickAt(mx, my)
    if (selection) hostsSelected(selection.hosts, selection.mode)
    else backgroundClicked()
  }

  MouseArea {
    id: interaction
    objectName: "firewall-map-interaction"
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton
    property real pressX: 0
    property real pressY: 0
    property real lastX: 0
    property real lastY: 0
    property bool dragged: false
    cursorShape: pressed && dragged ? Qt.ClosedHandCursor
      : root.hoverText !== "" ? Qt.PointingHandCursor : Qt.OpenHandCursor
    onPressed: function(mouse) {
      pressX = lastX = mouse.x
      pressY = lastY = mouse.y
      dragged = false
    }
    onPositionChanged: function(mouse) {
      if (pressed && (dragged || Math.hypot(mouse.x - pressX, mouse.y - pressY) > Style.space(4))) {
        dragged = true
        root.panBy(mouse.x - lastX, mouse.y - lastY)
        lastX = mouse.x
        lastY = mouse.y
        return
      }
      var arc = root.nearestArc(mouse.x, mouse.y)
      root.hoverArc = arc
      root.hoverX = mouse.x
      root.hoverY = mouse.y
      var selection = root.pickAt(mouse.x, mouse.y)
      if (selection) {
        var hosts = selection.hosts
        root.hoverText = (hosts.length === 1 ? hosts[0].label : hosts.length + " hosts · click to choose")
          + (arc ? "\n" + Model.describeFlow(arc) : "")
      } else root.hoverText = ""
      flow.requestPaint()
    }
    onExited: {
      root.hoverArc = null
      root.hoverText = ""
      flow.requestPaint()
    }
    onClicked: function(mouse) { if (!dragged) root.selectAt(mouse.x, mouse.y) }
    onWheel: function(wheel) {
      var delta = wheel.angleDelta.y || wheel.pixelDelta.y
      if (delta) root.zoomAt(Math.pow(1.0015, delta), wheel.x, wheel.y)
      wheel.accepted = true
    }
  }

  Rectangle {
    visible: root.hoverText !== ""
    x: Math.max(6, Math.min(root.width - width - 6, root.hoverX + 12))
    y: Math.max(6, Math.min(root.height - height - 6, root.hoverY + 12))
    width: Math.min(root.width - 12, hoverLabel.implicitWidth + Style.space(14))
    height: hoverLabel.contentHeight + Style.space(10)
    radius: Style.cornerRadius
    color: Qt.rgba(0.06, 0.07, 0.09, 0.92)
    border.width: 1
    border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.18)

    Text {
      id: hoverLabel
      anchors.centerIn: parent
      width: parent.width - Style.space(14)
      wrapMode: Text.WrapAnywhere
      textFormat: Text.PlainText
      text: root.hoverText
      color: "#f4f5f7"
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }
}
