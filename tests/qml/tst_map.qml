import QtQuick
import QtTest 1.3
import "../.." as Plugin
import "../../World.js" as World

TestCase {
  id: test
  name: "FirewallMapRendering"
  width: 900
  height: 350
  visible: true
  when: windowShown

  Plugin.Map {
    id: map
    anchors.fill: parent
    paused: true
    summary: ({locations: [
      {id: "home", local: true, lat: 40, lon: -70},
      {id: "remote", local: false, lat: 30, lon: 20}],
      flows: [{origin: "home", dest: "remote", rate: 12345, rate_in: 10000, rate_out: 2345}]})
  }
  SignalSpy { id: landPaint; signalName: "paint" }
  SignalSpy { id: flowPaint; signalName: "paint" }

  function initTestCase() {
    landPaint.target = findChild(map, "firewall-map-land")
    flowPaint.target = findChild(map, "firewall-map-flows")
    verify(landPaint.target !== null)
    verify(flowPaint.target !== null)
    tryCompare(landPaint.target, "available", true)
    tryCompare(flowPaint.target, "available", true)
    wait(80)
  }
  SignalSpy { id: backgroundClick; target: map; signalName: "backgroundClicked" }
  SignalSpy { id: hostClick; target: map; signalName: "hostsSelected" }

  function test_full_world_fits() {
    for (var size of [[900,180],[900,350],[350,700]]) {
      test.width=size[0]; test.height=size[1]; map.fitWorld()
      for (var ring of World.WORLD_LAND) for (var coord of ring) {
        var point=map.project(coord[1],coord[0])
        verify(point.x >= 0 && point.x <= map.width && point.y >= 0 && point.y <= map.height)
      }
    }
    test.width=900; test.height=350
  }
  function test_mouse_pan_and_clicks() {
    map.fitWorld()
    backgroundClick.clear()
    hostClick.clear()
    mouseDrag(map, 40, 200, 80, 40)
    verify(map.panX > 30 && map.panY > 10)
    compare(backgroundClick.count, 0)
    compare(hostClick.count, 0)
    mouseClick(map, 40, 280)
    compare(backgroundClick.count, 1)
    map.fitWorld()
    var endpoint=map.project(30,20)
    mouseClick(map, endpoint.x, endpoint.y)
    compare(hostClick.count, 1)
  }
  function test_wheel_zoom_and_fit() {
    map.fitWorld()
    var endpoint=map.project(30,20)
    mouseWheel(map, endpoint.x, endpoint.y, 0, 120)
    verify(map.zoom > 1)
    var after=map.project(30,20)
    verify(Math.abs(after.x-endpoint.x)<1 && Math.abs(after.y-endpoint.y)<1)
    map.fitWorld()
    compare(map.zoom,1)
    compare(map.panX,0)
    compare(map.panY,0)
  }
  function test_repaint_after_reopen() {
    for (var i = 0; i < 4; i++) {
      map.visible = false
      wait(40)
      landPaint.clear()
      flowPaint.clear()
      map.visible = true
      tryVerify(function() { return landPaint.count > 0 && flowPaint.count > 0 })
      var image = grabImage(map)
      compare(image.width, 900)
      verify(image.alpha(300, 100) > 0)
    }
  }
  function test_repaint_after_resume() {
    map.paused = true
    wait(50)
    landPaint.clear()
    map.paused = false
    tryVerify(function() { return landPaint.count > 0 })
    map.paused = true
  }
  function test_repaint_after_palette_change() {
    landPaint.clear()
    map.foreground = "#00ff00"
    tryVerify(function() { return landPaint.count > 0 })
    map.foreground = "#f0f0f0"
    wait(50)
  }
  function test_static_land_survives_traffic_updates() {
    wait(50)
    landPaint.clear()
    flowPaint.clear()
    map.summary = JSON.parse(JSON.stringify(map.summary))
    tryVerify(function() { return flowPaint.count > 0 })
    compare(landPaint.count, 0)
    var image = grabImage(map)
    verify(image.width > 0)
  }
  function test_hidden_map_stops_animation() {
    map.paused = false
    map.visible = false
    wait(80)
    var elapsed = map.elapsed
    wait(100)
    compare(map.elapsed, elapsed)
    map.visible = true
    tryVerify(function() { return map.elapsed !== elapsed })
    map.paused = true
  }
}
