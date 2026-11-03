var PLUGIN_ID = "jblparisi.firewall-map"
var DEFAULT_URL = "https://192.168.1.1"
var CREDENTIALS_PATH = "/.local/state/omarchy/firewall-map-credentials.json"
var BUCKET_COUNT = 24

function defaults() {
  return {
    url: DEFAULT_URL,
    interval: 1,
    blocksMin: 2,
    showHostnames: true
  }
}

function normalizeUrl(url) {
  var value = String(url || "").replace(/^\s+|\s+$/g, "").replace(/\/+$/, "")
  return value || DEFAULT_URL
}

function intInRange(value, fallback, low, high) {
  var number = parseInt(value, 10)
  if (!isFinite(number)) number = fallback
  return Math.max(low, Math.min(high, number))
}

// Read this widget's inline shell.json entry. Entries may live in any bar
// section, including the centered ones, so scan them all.
function pluginSettings(config, id) {
  var key = String(id || PLUGIN_ID)
  var settings = defaults()
  if (!config || typeof config !== "object") return settings
  var bar = config.bar && config.bar.layout ? config.bar.layout : {}
  var sections = ["left", "centerBegin", "center", "centerEnd", "right", "tray"]
  for (var s = 0; s < sections.length; s++) {
    var entries = bar[sections[s]] || []
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      if (!entry || String(entry.id || "") !== key) continue
      settings.url = normalizeUrl(entry.url)
      settings.interval = intInRange(entry.interval, settings.interval, 1, 30)
      settings.blocksMin = intInRange(entry.blocksMin, settings.blocksMin, 1, 100)
      settings.showHostnames = entry.showHostnames !== false
      return settings
    }
  }
  return settings
}

function entryWith(settings, values) {
  var entry = { id: PLUGIN_ID }
  for (var key in settings) entry[key] = settings[key]
  for (var changed in values) entry[changed] = values[changed]
  return entry
}

function parseCredentials(text) {
  try {
    var document = JSON.parse(String(text || ""))
    if (!document || typeof document !== "object") return { username: "", password: "" }
    return {
      username: String(document.username || ""),
      password: String(document.password || "")
    }
  } catch (error) {
    return { username: "", password: "" }
  }
}

function credentialsText(username, password) {
  return JSON.stringify({ username: String(username || ""), password: String(password || "") }) + "\n"
}

function hasCredentials(text) {
  var credentials = parseCredentials(text)
  return credentials.username !== "" && credentials.password !== ""
}

// ---- formatting ---------------------------------------------------------

function formatRate(bytes) {
  var value = Number(bytes) || 0
  if (value < 1000) return Math.round(value) + " B/s"
  if (value < 1000 * 1000) return (value / 1000).toFixed(value < 10000 ? 1 : 0) + " kB/s"
  if (value < 1000 * 1000 * 1000) return (value / 1e6).toFixed(value < 1e7 ? 1 : 0) + " MB/s"
  return (value / 1e9).toFixed(1) + " GB/s"
}

// The shared bar tooltip may infer rich text; hostnames and API errors are
// untrusted. Preserve readable text without letting markup create resources.
function tooltipText(value) {
  return String(value || "").replace(/</g, "‹").replace(/>/g, "›")
}

function formatCount(value) {
  var number = Number(value) || 0
  if (number < 1000) return String(Math.round(number))
  if (number < 1e6) return (number / 1000).toFixed(number < 1e4 ? 1 : 0) + "k"
  return (number / 1e6).toFixed(1) + "M"
}

function formatAge(seconds) {
  var value = Number(seconds)
  if (!isFinite(value) || value < 0) return "—"
  if (value < 10) return value.toFixed(1) + "s"
  if (value < 90) return Math.round(value) + "s"
  if (value < 5400) return Math.round(value / 60) + "m"
  return Math.round(value / 3600) + "h"
}

function flag(countryCode) {
  var code = String(countryCode || "").toUpperCase()
  if (code.length !== 2 || code < "AA" || code > "ZZ") return ""
  return String.fromCodePoint(0x1f1e6 + code.charCodeAt(0) - 65, 0x1f1e6 + code.charCodeAt(1) - 65)
}

function place(location) {
  if (!location) return "Unknown"
  var name = location.city || location.name || location.country || location.id || "Unknown"
  return name
}

function serviceLabel(flow) {
  if (!flow || !flow.services || flow.services.length === 0) return ""
  var name = String(flow.services[0] || "")
  var ports = flow.service_ports || {}
  var port = ports[name] ? String(ports[name]) : ""
  return port ? name + " " + port : name
}

function threatCount(summary) {
  if (!summary) return 0
  var count = 0
  for (var i = 0; i < (summary.flows || []).length; i++) {
    if (summary.flows[i] && summary.flows[i].threat === true) count++
  }
  return count
}

function blockedTotal(summary) {
  if (!summary) return 0
  return (summary.blocks || []).length + (Number(summary.blocks_below) || 0)
}

// ---- map data -----------------------------------------------------------

function locationMap(summary) {
  var map = Object.create(null)
  var locations = summary && Array.isArray(summary.locations) ? summary.locations : []
  for (var i = 0; i < locations.length; i++) {
    var location = locations[i]
    if (location && location.id) map[String(location.id)] = location
  }
  return map
}

function home(summary) {
  var locations = summary && Array.isArray(summary.locations) ? summary.locations : []
  var fallback = null
  for (var i = 0; i < locations.length; i++) {
    var location = locations[i]
    if (!location || location.local !== true) continue
    if (location.home === "ipv4_wan") return location
    if (!fallback) fallback = location
  }
  return fallback
}

// One arch per origin→destination pair, merging the addresses GeoIP puts at
// the same point, exactly like the Firewall Map+ page does.
function buildArcs(summary) {
  var locations = locationMap(summary)
  var merged = {}
  var flows = summary && Array.isArray(summary.flows) ? summary.flows : []
  for (var i = 0; i < flows.length; i++) {
    var flow = flows[i]
    if (!flow) continue
    var origin = locations[String(flow.origin)]
    var dest = locations[String(flow.dest)]
    if (!origin || !dest) continue
    // IPv4 and IPv6 addresses of the same firewall resolve to one point, so
    // merge by coordinates: otherwise several arches stack invisibly.
    var key = String(origin.lat) + "," + String(origin.lon) + ">" + String(dest.lat) + "," + String(dest.lon)
    var rate = Number(flow.rate) || Number(flow.count) || 0
    var arc = merged[key]
    if (arc) {
      arc.rate += rate
      arc.rateIn += Number(flow.rate_in) || 0
      arc.rateOut += Number(flow.rate_out) || 0
      arc.members = (arc.members || 1) + 1
      arc.flowMembers.push(flow)
      if (flow.threat === true) arc.threat = true
      continue
    }
    merged[key] = {
      key: key,
      origin: origin,
      dest: dest,
      rate: rate,
      rateIn: Number(flow.rate_in) || 0,
      rateOut: Number(flow.rate_out) || 0,
      members: 1,
      flowMembers: [flow],
      direction: flow.initiated === "remote" ? "in" : (flow.initiated === "both" ? "both" : "out"),
      threat: flow.threat === true || (Array.isArray(flow.lists) && flow.lists.length > 0),
      services: Array.isArray(flow.services) ? flow.services : [],
      servicePorts: flow.service_ports || {},
      inside: Array.isArray(flow.inside) ? flow.inside : [],
      initiated: flow.initiated,
      age: Number(flow.age) || 0,
      transferred: Array.isArray(flow.transferred) ? flow.transferred : null,
      rule: flow.rule || "",
      presence: flow.presence || "",
      ids: flow.ids || null
    }
  }
  var arcs = []
  for (var id in merged) arcs.push(merged[id])
  for (var a = 0; a < arcs.length; a++) {
    var entry = arcs[a]
    var total = entry.rateIn + entry.rateOut
    // Follow Firewall Map+: the arch colour and pulse direction describe where
    // the bytes flow, not only who opened the connection. A near-even split
    // counts as both ways.
    var inShare = total > 0 ? entry.rateIn / total : (entry.initiated === "remote" ? 1 : 0)
    entry.direction = inShare >= 0.75 ? "in" : (inShare <= 0.25 ? "out" : "both")
  }
  arcs.sort(function(a, b) { return b.rate - a.rate })
  return arcs
}

function buildBlocks(summary) {
  var blocks = summary && Array.isArray(summary.blocks) ? summary.blocks : []
  var result = []
  for (var i = 0; i < blocks.length; i++) {
    var block = blocks[i]
    if (!block || typeof block.lat !== "number" || typeof block.lon !== "number") continue
    result.push({
      key: "block:" + String(block.source || i),
      source: String(block.source || ""),
      lat: block.lat,
      lon: block.lon,
      hits: Number(block.hits) || 0,
      perMinute: Number(block.hits_per_minute) || 0,
      threat: block.threat === true,
      services: Array.isArray(block.services) ? block.services : [],
      ports: Array.isArray(block.ports) ? block.ports : [],
      country: block.country || "",
      countryCode: block.country_code || "",
      city: block.city || "",
      asOrg: block.as_org || "",
      rule: block.rule || "",
      interface: block.interface || "",
      seconds: Number(block.seconds) || 0
    })
  }
  result.sort(function(a, b) { return b.hits - a.hits })
  return result
}

function topTalkers(summary, limit, mode) {
  // Rank raw flows: map arcs deliberately merge different IPs at the same
  // coordinates, which loses the identity needed for labels and blocking.
  var locations = locationMap(summary)
  var flows = summary && Array.isArray(summary.flows) ? summary.flows : []
  var names = summary && summary.hostnames ? summary.hostnames : {}
  var groups = Object.create(null)
  for (var i = 0; i < flows.length; i++) {
    var flow = flows[i]
    if (!flow) continue
    if (mode === "threats" && flow.threat !== true) continue
    var origin = locations[String(flow.origin)] || {}
    var dest = locations[String(flow.dest)] || {}
    var remote = origin.local === true ? dest : (dest.local === true ? origin
      : (flow.initiated === "remote" ? origin : dest))
    var hosts = mode === "local" ? (flow.inside || []).slice(0, 1)
      : [{ip: remote.id || (flow.initiated === "remote" ? flow.origin : flow.dest)}]
    for (var h = 0; h < hosts.length; h++) {
      var host = hosts[h]
      if (!host || !host.ip) continue
      var key = String(host.ip)
      var name = host.name || names[key] || ""
      if (typeof name !== "string") name = ""
      var group = groups[key]
      if (!group) {
        group = groups[key] = { key: key, ip: key, name: name,
          label: name || key, location: remote, rate: 0, rateIn: 0, rateOut: 0,
          threat: false, flows: 0, interface: host.interface || "",
          service: flow.services && flow.services.length ? String(flow.services[0]) : "" }
      }
      group.rate += Math.max(0, Number(flow.rate) || 0)
      group.rateIn += Math.max(0, Number(flow.rate_in) || 0)
      group.rateOut += Math.max(0, Number(flow.rate_out) || 0)
      group.flows++
      if (flow.threat === true) group.threat = true
    }
  }
  var result = []
  for (var id in groups) result.push(groups[id])
  result.sort(function(a, b) { return b.rate - a.rate })
  return result.slice(0, Math.max(1, Number(limit) || 5))
}

function hostsForArcs(summary, arcs) {
  // A map line can represent many IPs in one city. Preserve every member so
  // clicking it offers the actual addresses rather than choosing one for you.
  var flows = []
  for (var i = 0; i < arcs.length; i++) {
    var members = arcs[i].flowMembers || []
    for (var j = 0; j < members.length; j++) {
      if (flows.indexOf(members[j]) === -1) flows.push(members[j])
    }
  }
  return topTalkers({flows: flows, locations: summary.locations || [],
    hostnames: summary.hostnames || {}}, Math.max(1, flows.length), "remote")
}

function segmentDistance(x, y, start, end) {
  var dx = end.x - start.x, dy = end.y - start.y
  var length = dx * dx + dy * dy
  var t = length ? Math.max(0, Math.min(1, ((x - start.x) * dx + (y - start.y) * dy) / length)) : 0
  return Math.hypot(x - start.x - dx * t, y - start.y - dy * t)
}

function hostsForBlocks(summary, blocks) {
  var names = summary.hostnames || {}
  var groups = Object.create(null)
  for (var i = 0; i < blocks.length; i++) {
    var block = blocks[i]
    var ip = String(block.source || "")
    if (!ip || groups[ip]) continue
    var name = typeof names[ip] === "string" ? names[ip] : ""
    groups[ip] = {ip: ip, key: ip, name: name, label: name || ip,
      location: block, threat: true, blockedSource: true, hits: Number(block.hits) || 0,
      perMinute: Number(block.hits_per_minute || block.perMinute) || 0,
      rate: 0, rateIn: 0, rateOut: 0, flows: 0}
  }
  return Object.keys(groups).map(function(ip) { return groups[ip] })
}

function refreshMapHosts(summary, selected, mode) {
  var flows = summary && Array.isArray(summary.flows) ? summary.flows : []
  var current = mode === "blocked"
    ? hostsForBlocks(summary, summary.blocks || [])
    : topTalkers(summary, Math.max(1, flows.length), mode)
  if (mode === "mixed") current = current.concat(topTalkers(summary, Math.max(1, flows.length), "local"))
  if (mode !== "blocked") current = hostsForBlocks(summary, summary.blocks || []).concat(current)
  var byIp = Object.create(null)
  for (var i = 0; i < current.length; i++) byIp[current[i].ip] = current[i]
  return selected.map(function(host) {
    return byIp[host.ip] || {ip: host.ip, key: host.ip, name: host.name || "",
      label: host.label || host.ip, location: host.location || {},
      rate: 0, rateIn: 0, rateOut: 0, flows: 0, threat: host.threat === true}
  })
}

// Stable 0..1 from a string, so arcs keep their pulse phase across refreshes.
function hash01(text) {
  var value = 0
  var string = String(text || "")
  for (var i = 0; i < string.length; i++) {
    value = (value * 31 + string.charCodeAt(i)) | 0
  }
  return (value >>> 0) / 4294967296
}

function positionName(location) {
  if (!location) return "Unknown"
  var parts = []
  var city = location.city || location.name
  if (city) parts.push(city)
  var country = location.country_code || location.country
  if (country) parts.push(flag(String(location.country_code || "")) || String(country))
  return parts.join(", ")
}

function describeFlow(arc) {
  if (!arc) return ""
  var parts = []
  parts.push(arc.direction === "in" ? "inbound" : (arc.direction === "both" ? "both ways" : "outbound"))
  var service = arc.services && arc.services.length ? String(arc.services[0]) : ""
  if (service) {
    var port = arc.servicePorts && arc.servicePorts[service] ? String(arc.servicePorts[service]) : ""
    parts.push(port ? service + " " + port : service)
  }
  parts.push(formatRate(arc.rate))
  var place = positionName(arc.dest)
  if (place) parts.push(place)
  return parts.join("  ·  ")
}
