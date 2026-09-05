// Pure flight-number, geo, and formatting logic for the flight monitor.
// Nothing here touches Qt so it can be exercised from node:
//   node -e 'var M=require("./Model.js"); console.log(M.normalizeFlightCode("la 3195"))'

var EARTH_RADIUS_KM = 6371.0088
var KNOT_KMH = 1.852

// IATA airline code -> ICAO callsign prefixes seen on ADS-B. adsbdb resolves
// most flight numbers to a single ICAO callsign, but airline groups fly one
// IATA code under several ICAO prefixes (LATAM's LA3195 broadcasts as
// TAM3195 in Brazil, LAN3195 from Chile), and the route database can be
// missing a flight entirely. These are tried in order when looking for the
// live aircraft.
var CALLSIGN_PREFIXES = {
  "LA": ["TAM", "LAN", "LPE", "LXP"],
  "JJ": ["TAM"],
  "AD": ["AZU"],
  "G3": ["GLO"],
  "2Z": ["PTB"],
  "AR": ["ARG"],
  "AV": ["AVA"],
  "CM": ["CMP"],
  "AM": ["AMX"],
  "AA": ["AAL"],
  "UA": ["UAL"],
  "DL": ["DAL"],
  "WN": ["SWA"],
  "B6": ["JBU"],
  "AS": ["ASA"],
  "NK": ["NKS"],
  "F9": ["FFT"],
  "AC": ["ACA"],
  "WS": ["WJA"],
  "BA": ["BAW"],
  "VS": ["VIR"],
  "AF": ["AFR"],
  "KL": ["KLM"],
  "LH": ["DLH"],
  "LX": ["SWR"],
  "OS": ["AUA"],
  "SN": ["BEL"],
  "IB": ["IBE"],
  "VY": ["VLG"],
  "UX": ["AEA"],
  "TP": ["TAP"],
  "AZ": ["ITY"],
  "FR": ["RYR"],
  "U2": ["EZY", "EJU"],
  "W6": ["WZZ"],
  "SK": ["SAS"],
  "AY": ["FIN"],
  "DY": ["NOZ", "NAX"],
  "LO": ["LOT"],
  "TK": ["THY"],
  "EK": ["UAE"],
  "QR": ["QTR"],
  "EY": ["ETD"],
  "SV": ["SVA"],
  "ET": ["ETH"],
  "SA": ["SAA"],
  "KE": ["KAL"],
  "OZ": ["AAR"],
  "JL": ["JAL"],
  "NH": ["ANA"],
  "CX": ["CPA"],
  "SQ": ["SIA"],
  "TG": ["THA"],
  "MH": ["MAS"],
  "GA": ["GIA"],
  "QF": ["QFA"],
  "NZ": ["ANZ"],
  "AI": ["AIC"],
  "6E": ["IGO"],
  "CA": ["CCA"],
  "MU": ["CES"],
  "CZ": ["CSN"],
  "CI": ["CAL"],
  "BR": ["EVA"]
}

// ---- Flight numbers ------------------------------------------------------

// "la 3195", "LA-3195", "tam3195" -> "LA3195", "TAM3195". Anything that does
// not look like an airline code followed by a flight number comes back as "".
function normalizeFlightCode(input) {
  var raw = String(input === undefined || input === null ? "" : input)
  var code = raw.toUpperCase().replace(/[^A-Z0-9]/g, "")
  return splitFlightCode(code) ? code : ""
}

// Splits a code into its airline designator and number. Two-character
// designators are IATA (letters or one digit: "LA", "G3", "2Z"); three
// letters are an ICAO callsign prefix ("TAM"). Returns null on no match.
function splitFlightCode(code) {
  var m = String(code || "").match(/^([A-Z]{3}|[A-Z][A-Z0-9]|[0-9][A-Z])([0-9]{1,4}[A-Z]?)$/)
  if (!m) return null
  return { airline: m[1], number: m[2], icao: m[1].length === 3 }
}

// The ICAO callsigns worth asking the ADS-B feed for, most likely first.
// A callsign that answered last time leads, then the route lookup's answer,
// then the airline-group aliases. A code typed as an ICAO callsign is kept
// as-is so it works even when the route database has never heard of it;
// an IATA code is not, because nothing broadcasts one.
function liveCallsignCandidates(code, route, preferred, schedule) {
  var list = []
  function push(value) {
    var v = String(value || "").toUpperCase().replace(/[^A-Z0-9]/g, "")
    if (v !== "" && list.indexOf(v) === -1) list.push(v)
  }
  var parsed = splitFlightCode(code)
  push(preferred)
  if (schedule && schedule.callsign) push(schedule.callsign)
  if (route && route.callsignIcao) push(route.callsignIcao)
  if (parsed && !parsed.icao) {
    var prefixes = CALLSIGN_PREFIXES[parsed.airline] || []
    for (var i = 0; i < prefixes.length; i++) push(prefixes[i] + parsed.number)
    if (route && route.airlineIcao) push(route.airlineIcao + parsed.number)
  } else {
    push(code)
  }
  return list
}

// ---- API parsing ---------------------------------------------------------

function num(value) {
  var n = parseFloat(value)
  return isFinite(n) ? n : null
}

function parseAirport(raw) {
  if (!raw || typeof raw !== "object") return null
  var lat = num(raw.latitude)
  var lon = num(raw.longitude)
  if (lat === null || lon === null) return null
  return {
    iata: String(raw.iata_code || ""),
    icao: String(raw.icao_code || ""),
    name: String(raw.name || ""),
    city: String(raw.municipality || ""),
    country: String(raw.country_iso_name || ""),
    lat: lat,
    lon: lon
  }
}

// adsbdb /v0/callsign/<code> -> route, or null when the flight is unknown.
function parseRoute(text) {
  var parsed
  try { parsed = JSON.parse(String(text || "")) } catch (e) { return null }
  var fr = parsed && parsed.response && parsed.response.flightroute
  if (!fr || typeof fr !== "object") return null
  var origin = parseAirport(fr.origin)
  var destination = parseAirport(fr.destination)
  if (!origin || !destination) return null
  var airline = fr.airline || {}
  return {
    callsign: String(fr.callsign || ""),
    callsignIcao: String(fr.callsign_icao || ""),
    callsignIata: String(fr.callsign_iata || ""),
    airlineName: String(airline.name || ""),
    airlineIcao: String(airline.icao || ""),
    airlineIata: String(airline.iata || ""),
    origin: origin,
    destination: destination,
    distanceKm: distanceKm(origin.lat, origin.lon, destination.lat, destination.lon)
  }
}

// adsb.lol /v2/callsign/<callsign> -> the freshest positioned aircraft, or
// null when nothing matching is in the air.
function parseLive(text) {
  var parsed
  try { parsed = JSON.parse(String(text || "")) } catch (e) { return null }
  var list = parsed && parsed.ac
  if (!Array.isArray(list)) return null
  var best = null
  for (var i = 0; i < list.length; i++) {
    var ac = list[i]
    if (!ac || num(ac.lat) === null || num(ac.lon) === null) continue
    var seen = num(ac.seen_pos)
    if (seen === null) seen = num(ac.seen)
    if (seen === null) seen = 1e9
    if (!best || seen < best.seenPos) {
      var onGround = ac.alt_baro === "ground"
      best = {
        hex: String(ac.hex || ""),
        callsign: String(ac.flight || "").trim(),
        registration: String(ac.r || ""),
        type: String(ac.t || ""),
        lat: num(ac.lat),
        lon: num(ac.lon),
        onGround: onGround,
        altitudeFt: onGround ? 0 : num(ac.alt_baro),
        groundSpeedKt: num(ac.gs),
        track: num(ac.track),
        verticalRateFpm: num(ac.baro_rate) !== null ? num(ac.baro_rate) : num(ac.geom_rate),
        seenPos: seen
      }
    }
  }
  return best
}


// ---- Flightradar24 schedule ---------------------------------------------

function fr24Airport(raw) {
  if (!raw || typeof raw !== "object") return null
  var pos = raw.position || {}
  var lat = num(pos.latitude), lon = num(pos.longitude)
  if (lat === null || lon === null) return null
  var code = raw.code || {}
  var tz = raw.timezone || {}
  return {
    iata: String(code.iata || ""),
    icao: String(code.icao || ""),
    name: String(raw.name || ""),
    city: String((pos.region && pos.region.city) || ""),
    country: String((pos.country && pos.country.code) || ""),
    lat: lat,
    lon: lon,
    tzOffset: num(tz.offset) !== null ? num(tz.offset) : 0,
    tzName: String(tz.name || "")
  }
}

function fr24Instance(raw) {
  if (!raw || typeof raw !== "object") return null
  var time = raw.time || {}
  var sched = time.scheduled || {}, est = time.estimated || {}, real = time.real || {}, other = time.other || {}
  var ident = raw.identification || {}
  var aircraft = raw.aircraft || {}
  var status = raw.status || {}
  var airports = raw.airport || {}
  var origin = fr24Airport(airports.origin)
  var destination = fr24Airport(airports.destination)
  if (!origin || !destination) return null
  var model = aircraft.model || {}
  return {
    number: String((ident.number && ident.number.default) || ""),
    callsign: String(ident.callsign || ""),
    flightId: String(ident.id || ""),
    hex: String(aircraft.hex || "").toLowerCase(),
    registration: String(aircraft.registration || ""),
    aircraftModel: String(model.code || ""),
    aircraftName: String(model.text || ""),
    statusText: String(status.text || ""),
    live: status.live === true,
    origin: origin,
    destination: destination,
    scheduledDeparture: num(sched.departure),
    scheduledArrival: num(sched.arrival),
    estimatedDeparture: num(est.departure),
    estimatedArrival: num(est.arrival),
    realDeparture: num(real.departure),
    realArrival: num(real.arrival),
    eta: num(other.eta)
  }
}

// FR24 flight list -> the instance worth showing right now: the one that
// is live; else the next one still to arrive (which covers a flight that
// has departed but is not being tracked); else the most recent landed one.
// Null when the body is not JSON (Cloudflare interstitial) or empty.
function parseSchedule(text, nowSeconds) {
  var parsed
  try { parsed = JSON.parse(String(text || "")) } catch (e) { return null }
  var data = parsed && parsed.result && parsed.result.response && parsed.result.response.data
  if (!Array.isArray(data)) return null
  var now = nowSeconds || Math.floor(Date.now() / 1000)
  var items = []
  for (var i = 0; i < data.length; i++) {
    var item = fr24Instance(data[i])
    if (item) items.push(item)
  }
  if (items.length === 0) return null

  // A live flag can linger on a stale row; only trust it while the flight
  // could still plausibly be in the air.
  for (var l = 0; l < items.length; l++) {
    var arrivalGuess = arrivalEstimate(items[l])
    if (items[l].live && (arrivalGuess === null || arrivalGuess > now - 7200)) return items[l]
  }

  var upcoming = null
  for (var u = 0; u < items.length; u++) {
    var it = items[u]
    var arrival = it.realArrival || it.estimatedArrival || it.scheduledArrival
    if (it.realArrival !== null) continue
    if (arrival !== null && arrival < now - 3600) continue
    if (it.scheduledDeparture === null) continue
    if (!upcoming || it.scheduledDeparture < upcoming.scheduledDeparture) upcoming = it
  }
  if (upcoming) return upcoming

  var landed = null
  for (var d = 0; d < items.length; d++) {
    var la = items[d]
    if (la.realArrival === null) continue
    if (!landed || la.realArrival > landed.realArrival) landed = la
  }
  return landed || items[items.length - 1]
}

// A route in the same shape parseRoute returns, so the panel can draw the
// map from the schedule alone when adsbdb is down or disagrees.
function routeFromSchedule(schedule) {
  if (!schedule) return null
  return {
    callsign: schedule.number,
    callsignIcao: schedule.callsign,
    callsignIata: schedule.number,
    airlineName: "",
    airlineIcao: schedule.callsign ? schedule.callsign.replace(/[0-9].*$/, "") : "",
    airlineIata: "",
    origin: schedule.origin,
    destination: schedule.destination,
    distanceKm: distanceKm(schedule.origin.lat, schedule.origin.lon, schedule.destination.lat, schedule.destination.lon),
    source: "fr24"
  }
}

// FR24 clickhandler -> latest trail point in parseLive's shape plus the
// path flown so far (oldest first) for the map.
function parseTrail(text, nowSeconds) {
  var parsed
  try { parsed = JSON.parse(String(text || "")) } catch (e) { return null }
  var trail = parsed && parsed.trail
  if (!Array.isArray(trail) || trail.length === 0) return null
  var now = nowSeconds || Math.floor(Date.now() / 1000)
  var points = []
  for (var i = trail.length - 1; i >= 0; i--) {
    var p = trail[i]
    var lat = num(p && p.lat), lon = num(p && p.lng)
    if (lat === null || lon === null) continue
    points.push({ lat: lat, lon: lon })
  }
  if (points.length === 0) return null
  // Thin a long trail so the map polyline stays cheap.
  var step = Math.max(1, Math.ceil(points.length / 200))
  var thinned = []
  for (var t = 0; t < points.length; t += step) thinned.push(points[t])
  if (thinned[thinned.length - 1] !== points[points.length - 1]) thinned.push(points[points.length - 1])

  var latest = trail[0]
  var aircraft = parsed.aircraft || {}
  var ident = parsed.identification || {}
  var alt = num(latest.alt)
  var ts = num(latest.ts)
  return {
    live: {
      hex: String(aircraft.hex || "").toLowerCase(),
      callsign: String(ident.callsign || ""),
      registration: String(aircraft.registration || ""),
      type: String((aircraft.model && aircraft.model.code) || ""),
      lat: num(latest.lat),
      lon: num(latest.lng),
      onGround: alt !== null && alt <= 0,
      altitudeFt: alt,
      groundSpeedKt: num(latest.spd),
      track: num(latest.hd),
      verticalRateFpm: null,
      seenPos: ts !== null ? Math.max(0, now - ts) : 0,
      source: "fr24"
    },
    points: thinned
  }
}

// scheduled -> departed -> landed, from what the schedule has recorded.
function flightPhase(schedule) {
  if (!schedule) return "unknown"
  if (schedule.realArrival !== null) return "landed"
  if (schedule.realDeparture !== null || schedule.live) return "departed"
  return "scheduled"
}

function arrivalEstimate(schedule) {
  if (!schedule) return null
  return schedule.eta || schedule.estimatedArrival || schedule.scheduledArrival
}

function departureEstimate(schedule) {
  if (!schedule) return null
  return schedule.realDeparture || schedule.estimatedDeparture || schedule.scheduledDeparture
}

// Share of the flight done by the clock: from the real departure to the
// best arrival estimate. The fallback when no position is available.
function timeProgress(schedule, nowSeconds) {
  if (flightPhase(schedule) !== "departed") return null
  var start = schedule.realDeparture || schedule.estimatedDeparture || schedule.scheduledDeparture
  var end = arrivalEstimate(schedule)
  if (start === null || end === null || end <= start) return null
  var now = nowSeconds || Math.floor(Date.now() / 1000)
  return Math.max(0, Math.min(1, (now - start) / (end - start)))
}

// ---- Time formatting -----------------------------------------------------

function pad2(n) { return (n < 10 ? "0" : "") + n }

// Wall-clock time at an airport: shift the epoch by the airport's UTC
// offset and read the result as UTC.
function formatLocalTime(ts, tzOffset) {
  if (ts === null || ts === undefined || !isFinite(ts)) return "—"
  var d = new Date((ts + (tzOffset || 0)) * 1000)
  return pad2(d.getUTCHours()) + ":" + pad2(d.getUTCMinutes())
}

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function formatDateShort(ts, tzOffset) {
  if (ts === null || ts === undefined || !isFinite(ts)) return ""
  var d = new Date((ts + (tzOffset || 0)) * 1000)
  return MONTHS[d.getUTCMonth()] + " " + d.getUTCDate()
}

function formatDuration(seconds) {
  if (seconds === null || seconds === undefined || !isFinite(seconds)) return "—"
  var minutes = Math.round(Math.max(0, seconds) / 60)
  var h = Math.floor(minutes / 60), m = minutes % 60
  if (h === 0) return m + " min"
  return h + "h " + pad2(m) + "m"
}

// Minutes of delay as words. Anything inside five minutes is "on time".
function formatDelay(scheduled, actual) {
  if (scheduled === null || actual === null || scheduled === undefined || actual === undefined) return ""
  var minutes = Math.round((actual - scheduled) / 60)
  if (Math.abs(minutes) < 5) return "on time"
  if (minutes < 0) return (-minutes) + " min early"
  return minutes + " min late"
}

function delayMinutes(scheduled, actual) {
  if (scheduled === null || actual === null || scheduled === undefined || actual === undefined) return 0
  return Math.round((actual - scheduled) / 60)
}

// One line for the panel: "Departed 19:05 · arriving 21:57 (on time)".
function statusLabel(schedule) {
  var phase = flightPhase(schedule)
  if (phase === "unknown") return ""
  var o = schedule.origin, d = schedule.destination
  if (phase === "landed")
    return "Landed " + formatLocalTime(schedule.realArrival, d.tzOffset)
      + " · " + formatDelay(schedule.scheduledArrival, schedule.realArrival)
  if (phase === "departed") {
    var dep = schedule.realDeparture
      ? "Departed " + formatLocalTime(schedule.realDeparture, o.tzOffset)
      : "In flight"
    var arr = arrivalEstimate(schedule)
    return dep + " · arriving " + formatLocalTime(arr, d.tzOffset)
      + " · " + formatDelay(schedule.scheduledArrival, arr)
  }
  var est = schedule.estimatedDeparture
  if (est && Math.abs(delayMinutes(schedule.scheduledDeparture, est)) >= 5)
    return "Scheduled · now departing " + formatLocalTime(est, o.tzOffset)
      + " · " + formatDelay(schedule.scheduledDeparture, est)
  return "Scheduled · departs " + formatLocalTime(schedule.scheduledDeparture, o.tzOffset)
}

// ---- Great-circle math ---------------------------------------------------

function toRad(deg) { return deg * Math.PI / 180 }
function toDeg(rad) { return rad * 180 / Math.PI }

function distanceKm(lat1, lon1, lat2, lon2) {
  var p1 = toRad(lat1), p2 = toRad(lat2)
  var dp = p2 - p1, dl = toRad(lon2 - lon1)
  var a = Math.sin(dp / 2) * Math.sin(dp / 2) + Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) * Math.sin(dl / 2)
  return 2 * EARTH_RADIUS_KM * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
}

function bearingDeg(lat1, lon1, lat2, lon2) {
  var p1 = toRad(lat1), p2 = toRad(lat2), dl = toRad(lon2 - lon1)
  var y = Math.sin(dl) * Math.cos(p2)
  var x = Math.cos(p1) * Math.sin(p2) - Math.sin(p1) * Math.cos(p2) * Math.cos(dl)
  return (toDeg(Math.atan2(y, x)) + 360) % 360
}

// Point a fraction f of the way along the great circle from a to b.
function intermediatePoint(lat1, lon1, lat2, lon2, f) {
  var p1 = toRad(lat1), l1 = toRad(lon1), p2 = toRad(lat2), l2 = toRad(lon2)
  var d = distanceKm(lat1, lon1, lat2, lon2) / EARTH_RADIUS_KM
  if (d < 1e-9) return { lat: lat1, lon: lon1 }
  var A = Math.sin((1 - f) * d) / Math.sin(d)
  var B = Math.sin(f * d) / Math.sin(d)
  var x = A * Math.cos(p1) * Math.cos(l1) + B * Math.cos(p2) * Math.cos(l2)
  var y = A * Math.cos(p1) * Math.sin(l1) + B * Math.cos(p2) * Math.sin(l2)
  var z = A * Math.sin(p1) + B * Math.sin(p2)
  return { lat: toDeg(Math.atan2(z, Math.sqrt(x * x + y * y))), lon: toDeg(Math.atan2(y, x)) }
}

function greatCirclePoints(a, b, steps) {
  var n = Math.max(2, steps || 32)
  var out = []
  for (var i = 0; i <= n; i++) out.push(intermediatePoint(a.lat, a.lon, b.lat, b.lon, i / n))
  return out
}

// How far along the trip the aircraft is, as the share of "distance flown
// from origin" over "flown + still to go". Measuring both legs from the
// aircraft's own position keeps the number sane when it is off the direct
// track (airways, weather deviations, holding).
function routeProgress(origin, destination, position) {
  if (!origin || !destination || !position) return null
  var flown = distanceKm(origin.lat, origin.lon, position.lat, position.lon)
  var remaining = distanceKm(position.lat, position.lon, destination.lat, destination.lon)
  var total = flown + remaining
  return {
    flownKm: flown,
    remainingKm: remaining,
    fraction: total > 0 ? Math.max(0, Math.min(1, flown / total)) : 0
  }
}

// ---- Globe (orthographic) projection -------------------------------------
//
// The map card is a globe seen from space, centred on the route. A view is
// { lat0, lon0, radius, cx, cy }: the surface point under the eye, the disc
// radius in pixels, and where the disc centre sits on the card. North is
// up; points on the far hemisphere are "not visible".

function orthographic(lat, lon, view) {
  var p = toRad(lat), l = toRad(lon - view.lon0)
  var p0 = toRad(view.lat0)
  var cosP = Math.cos(p), sinP = Math.sin(p), cosP0 = Math.cos(p0), sinP0 = Math.sin(p0)
  var depth = sinP0 * sinP + cosP0 * cosP * Math.cos(l)
  return {
    x: view.cx + view.radius * cosP * Math.sin(l),
    y: view.cy - view.radius * (cosP0 * sinP - sinP0 * cosP * Math.cos(l)),
    visible: depth >= 0,
    depth: depth
  }
}

function angularDistanceRad(lat1, lon1, lat2, lon2) {
  return distanceKm(lat1, lon1, lat2, lon2) / EARTH_RADIUS_KM
}

// Centre on the route's midpoint and zoom so every point of interest fits
// inside the card with some air, never closer than minRadiusDeg of the
// surface so the curvature still reads on a short hop. The disc may be
// larger than the card: the card clips it and shows the curved surface.
function globeView(points, width, height, padding, minRadiusDeg) {
  var pts = (points || []).filter(function(p) { return p && isFinite(p.lat) && isFinite(p.lon) })
  if (pts.length === 0 || !(width > 0) || !(height > 0)) return null
  var centre = pts.length >= 2
    ? intermediatePoint(pts[0].lat, pts[0].lon, pts[1].lat, pts[1].lon, 0.5)
    : { lat: pts[0].lat, lon: pts[0].lon }
  var angMax = 0
  for (var i = 0; i < pts.length; i++)
    angMax = Math.max(angMax, angularDistanceRad(centre.lat, centre.lon, pts[i].lat, pts[i].lon))
  var minRad = toRad(minRadiusDeg || 22)
  var a = Math.min(toRad(89), Math.max(angMax * 1.35, minRad))
  var halfMin = Math.min(width, height) / 2
  var radius = Math.max(1, halfMin - (padding || 0)) / Math.sin(a)
  return {
    lat0: centre.lat,
    lon0: centre.lon,
    radius: radius,
    cx: width / 2,
    cy: height / 2,
    fitsCard: radius <= halfMin
  }
}

// A polyline as the runs that are on the near side, so a line disappears
// behind the horizon instead of cutting across the disc.
function projectPolylineVisible(points, view) {
  var runs = [], run = []
  for (var i = 0; i < points.length; i++) {
    var p = points[i]
    var q = orthographic(p.lat, p.lon, view)
    if (q.visible) {
      run.push({ x: q.x, y: q.y })
    } else if (run.length > 0) {
      if (run.length > 1) runs.push(run)
      run = []
    }
  }
  if (run.length > 1) runs.push(run)
  return runs
}

// A closed ring for filling: hidden vertices are pulled to the nearest
// point on the disc's rim, which keeps the polygon closed and inside the
// disc. Null when nothing of the ring is on the near side.
function projectRingClamped(ring, view) {
  var out = [], anyVisible = false
  for (var i = 0; i < ring.length; i++) {
    var q = orthographic(ring[i].lat, ring[i].lon, view)
    if (q.visible) {
      anyVisible = true
      out.push({ x: q.x, y: q.y })
    } else {
      var dx = q.x - view.cx, dy = q.y - view.cy
      var len = Math.sqrt(dx * dx + dy * dy)
      if (len < 1e-6) { dx = 0; dy = 1; len = 1 }
      out.push({ x: view.cx + view.radius * dx / len, y: view.cy + view.radius * dy / len })
    }
  }
  return anyVisible ? out : null
}

// Meridians and parallels every stepDeg, as {lat, lon} polylines. Built
// once per step and cached: the set never changes, only its projection.
var GRATICULE_CACHE = {}

function graticule(stepDeg) {
  var step = stepDeg || 15
  if (GRATICULE_CACHE[step]) return GRATICULE_CACHE[step]
  var lines = []
  for (var lon = -180; lon < 180; lon += step) {
    var meridian = []
    for (var lat = -90; lat <= 90; lat += 3) meridian.push({ lat: lat, lon: lon })
    lines.push(meridian)
  }
  for (var plat = -90 + step; plat < 90; plat += step) {
    var parallel = []
    for (var plon = -180; plon <= 180; plon += 3) parallel.push({ lat: plat, lon: plon })
    lines.push(parallel)
  }
  GRATICULE_CACHE[step] = lines
  return lines
}

// World.js stores rings as [lat, lon] pairs; expand once into objects.
var LAND_RINGS_CACHE = null

function landRings(landPairs) {
  if (LAND_RINGS_CACHE) return LAND_RINGS_CACHE
  var rings = []
  for (var i = 0; i < landPairs.length; i++) {
    var ring = []
    for (var j = 0; j < landPairs[i].length; j++) ring.push({ lat: landPairs[i][j][0], lon: landPairs[i][j][1] })
    rings.push(ring)
  }
  LAND_RINGS_CACHE = rings
  return rings
}

// ---- Formatting ----------------------------------------------------------

function groupThousands(n) {
  var s = String(Math.round(n))
  var out = ""
  while (s.length > 3) {
    out = "," + s.slice(-3) + out
    s = s.slice(0, -3)
  }
  return s + out
}

function formatAltitude(live) {
  if (!live) return "—"
  if (live.onGround) return "Ground"
  if (live.altitudeFt === null) return "—"
  return groupThousands(live.altitudeFt) + " ft"
}

function formatSpeed(kt) {
  if (kt === null || kt === undefined) return "—"
  return groupThousands(kt * KNOT_KMH) + " km/h"
}

function formatHeading(track) {
  if (track === null || track === undefined) return "—"
  var names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
  var idx = Math.round(((track % 360) + 360) % 360 / 45) % 8
  return Math.round(track) + "° " + names[idx]
}

function formatDistance(km) {
  if (km === null || km === undefined) return "—"
  return groupThousands(km) + " km"
}

function formatVerticalRate(fpm) {
  if (fpm === null || fpm === undefined) return ""
  if (Math.abs(fpm) < 100) return "level"
  return (fpm > 0 ? "climbing" : "descending")
}

// Time to go at the current ground speed. Blank below taxi speed so a
// parked aircraft does not promise a 9,000-hour flight.
function formatEta(remainingKm, groundSpeedKt) {
  if (remainingKm === null || groundSpeedKt === null || groundSpeedKt === undefined) return "—"
  var kmh = groundSpeedKt * KNOT_KMH
  if (kmh < 80) return "—"
  var minutes = Math.round(remainingKm / kmh * 60)
  if (minutes < 1) return "now"
  var h = Math.floor(minutes / 60), m = minutes % 60
  if (h === 0) return m + " min"
  return h + "h " + (m < 10 ? "0" : "") + m + "m"
}

function formatAgo(seconds) {
  if (seconds === null || seconds === undefined || !isFinite(seconds)) return ""
  var s = Math.max(0, Math.round(seconds))
  if (s < 5) return "just now"
  if (s < 60) return s + "s ago"
  var m = Math.round(s / 60)
  if (m < 60) return m + " min ago"
  return Math.round(m / 60) + " h ago"
}

function airportLabel(airport) {
  if (!airport) return ""
  return airport.iata || airport.icao || "?"
}

function airportCity(airport) {
  if (!airport) return ""
  return airport.city || airport.name || ""
}

// One line for the bar tooltip: "LA3195 · THE → GRU · 62% · 36,000 ft".
function summaryLine(code, route, live, fraction, schedule) {
  if (!code) return "Flight monitor — click to track a flight"
  var parts = [code]
  if (route) parts.push(airportLabel(route.origin) + " → " + airportLabel(route.destination))
  var phase = flightPhase(schedule)
  if (phase === "departed") {
    if (fraction !== null && fraction !== undefined) parts.push(Math.round(fraction * 100) + "%")
    parts.push("arriving " + formatLocalTime(arrivalEstimate(schedule), schedule.destination.tzOffset))
  } else if (phase === "landed") {
    parts.push("landed " + formatLocalTime(schedule.realArrival, schedule.destination.tzOffset))
  } else if (phase === "scheduled") {
    parts.push("departs " + formatLocalTime(departureEstimate(schedule), schedule.origin.tzOffset))
  } else if (live) {
    parts.push(formatAltitude(live))
  } else if (route) {
    parts.push("not airborne")
  }
  return parts.join(" · ")
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    normalizeFlightCode: normalizeFlightCode,
    splitFlightCode: splitFlightCode,
    liveCallsignCandidates: liveCallsignCandidates,
    parseRoute: parseRoute,
    parseLive: parseLive,
    distanceKm: distanceKm,
    bearingDeg: bearingDeg,
    intermediatePoint: intermediatePoint,
    greatCirclePoints: greatCirclePoints,
    routeProgress: routeProgress,
    orthographic: orthographic,
    globeView: globeView,
    projectPolylineVisible: projectPolylineVisible,
    projectRingClamped: projectRingClamped,
    graticule: graticule,
    landRings: landRings,
    formatAltitude: formatAltitude,
    formatSpeed: formatSpeed,
    formatHeading: formatHeading,
    formatDistance: formatDistance,
    formatEta: formatEta,
    formatAgo: formatAgo,
    summaryLine: summaryLine,
    parseSchedule: parseSchedule,
    routeFromSchedule: routeFromSchedule,
    parseTrail: parseTrail,
    flightPhase: flightPhase,
    timeProgress: timeProgress,
    arrivalEstimate: arrivalEstimate,
    departureEstimate: departureEstimate,
    formatLocalTime: formatLocalTime,
    formatDateShort: formatDateShort,
    formatDuration: formatDuration,
    formatDelay: formatDelay,
    delayMinutes: delayMinutes,
    statusLabel: statusLabel
  }
}
