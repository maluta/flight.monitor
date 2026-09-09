import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "World.js" as World

// The flight monitor popup: a flight-number field on top, then the route
// (origin → destination with scheduled times and the aircraft's progress
// between them), a globe card with the continents, the great-circle track
// and the live position, and a row of flight stats. BarWidget.qml owns the
// bar icon and hands this panel the button to anchor against.
//
// Data comes from keyless public endpoints:
//   flightradar24  flight number → schedule, status, aircraft, airports
//                  (and a position trail when no ADS-B receiver hears it)
//   adsb.lol       hex / ICAO callsign → live ADS-B position, altitude, track
//   adsbdb.com     airline name, and the route when FR24 does not answer
// A flight number is an IATA code (LA3195); the aircraft broadcasts an ICAO
// callsign (TAM3195). Airline groups use several prefixes, so the callsign
// lookup walks a short candidate list and remembers the winner.
Panel {
  id: root
  moduleName: "io.github.maluta.flight-monitor"
  ipcTarget: "io.github.maluta.flight-monitor"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel, so everything the bar identifies a panel by has to be that
  // widget (popout coordinator, open-panel dot, switchPanelFrom).
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string userAgent: "omarchy-flight-monitor/1.0"
  // Flightradar24 sits behind Cloudflare and answers a plain curl with an
  // interstitial page; a browser user agent gets the JSON.
  readonly property string browserAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"

  // ---- Persisted settings (inline in shell.json).
  readonly property string flightCode: Model.normalizeFlightCode(setting("flight", ""))
  readonly property int refreshSeconds: Math.max(15, Math.min(600, parseInt(setting("refreshSeconds", 60)) || 60))

  // ---- Fetched state.
  property var schedule: null           // Model.parseSchedule (FR24): times, status, aircraft
  property string scheduleStatus: "idle" // idle | loading | ok | unknown | offline
  property double scheduleUpdatedAt: 0
  property var route: null              // airports + distance; FR24 when it answers, else adsbdb
  property string routeStatus: "idle"   // adsbdb: idle | loading | ok | unknown | offline
  property string airlineName: ""       // from adsbdb (FR24's list has none)
  property var adsbLive: null           // adsb.lol position (Model.parseLive)
  property var trailLive: null          // FR24 latest trail point, same shape
  property var trailPoints: []          // FR24 path flown, oldest first
  property string liveStatus: "idle"    // idle | loading | ok | none | offline
  property var candidates: []           // [{ kind: "hex" | "callsign", value }]
  property int candidateIndex: 0
  property string liveCallsign: ""      // callsign that answered last, tried first next time
  property double liveUpdatedAt: 0
  property double trailUpdatedAt: 0
  property double now: Date.now()
  property string fieldError: ""

  readonly property bool hasFlight: flightCode !== ""
  readonly property bool hasRoute: route !== null
  readonly property real nowSeconds: now / 1000
  readonly property bool busy: scheduleProc.running || routeProc.running || liveProc.running || trailProc.running

  // ADS-B first: it is the direct signal. FR24's trail fills in where no
  // receiver hears the aircraft (satellite, MLAT, or just their network).
  readonly property var live: adsbLive || trailLive
  readonly property bool airborne: live !== null
  readonly property string phase: Model.flightPhase(schedule)   // scheduled | departed | landed | unknown
  readonly property bool inFlight: phase === "departed" || (phase === "unknown" && airborne)

  // Progress: by position when there is one, by the clock otherwise.
  readonly property var progress: Model.routeProgress(route ? route.origin : null, route ? route.destination : null, live)
  readonly property var timeFraction: Model.timeProgress(schedule, nowSeconds)
  readonly property bool positionEstimated: !airborne && timeFraction !== null && route !== null
  readonly property real fraction: progress ? progress.fraction
    : (timeFraction !== null ? timeFraction : (phase === "landed" ? 1 : 0))
  readonly property var estimatedPoint: positionEstimated
    ? Model.intermediatePoint(route.origin.lat, route.origin.lon, route.destination.lat, route.destination.lon, timeFraction)
    : null
  readonly property real timeLeftSeconds: schedule && phase === "departed"
    ? Math.max(0, (Model.arrivalEstimate(schedule) || nowSeconds) - nowSeconds) : 0

  readonly property real liveAgeSeconds: live
    ? Math.max(0, (now - (live === adsbLive ? liveUpdatedAt : trailUpdatedAt)) / 1000 + (live.seenPos || 0)) : 0
  readonly property bool liveStale: live && liveAgeSeconds > 120
  // The route database can lag the schedule: when flown-plus-remaining is
  // well over the direct distance the aircraft is not on the listed leg.
  readonly property bool offRoute: progress && route && (progress.flownKm + progress.remainingKm) > route.distanceKm * 1.3

  // Points the map has to fit: both airports plus the aircraft when known.
  readonly property var mapPoints: {
    var pts = []
    if (route) { pts.push(route.origin); pts.push(route.destination) }
    if (live) pts.push({ lat: live.lat, lon: live.lon })
    else if (estimatedPoint) pts.push(estimatedPoint)
    for (var i = 0; i < trailPoints.length; i += 8) pts.push(trailPoints[i])
    return pts
  }

  // Shared with the bar widget.
  readonly property string label: "󰀝"
  readonly property string summary: Model.summaryLine(flightCode, route, live, inFlight ? fraction : null, schedule)

  // Guarded so the panel renders before the bar is injected (the bar-widget
  // contract instantiates it bare).
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(contentForeground, 1.5)
  readonly property color faint: Qt.darker(contentForeground, 2.0)
  readonly property color accentColor: Style.selectedStateColor(contentForeground, Color.accent)

  function tint(alpha) {
    return Qt.rgba(contentForeground.r, contentForeground.g, contentForeground.b, alpha)
  }

  // ---- Open / close ------------------------------------------------------

  // Show and hide come first: the reveal flag is cosmetic and must never
  // keep the panel from opening or closing.
  function open() {
    openedFromHotkey = false
    root.controller.show()
    setCenterHoverRevealSuppressed(false)
    afterOpen()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    afterOpen()
    // Set after showing, not before: showing hands the popout coordinator
    // over, which closes whichever panel was open, and that close clears the
    // shared flag. Deferring means the panel taking over always wins.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function afterOpen() {
    root.now = Date.now()
    root.refresh()
    // With nothing tracked yet the field is the only thing to do, so it
    // takes focus straight away.
    if (!root.hasFlight) Qt.callLater(root.focusField)
  }

  function close() {
    root.controller.hide()
    root.fieldError = ""
    setCenterHoverRevealSuppressed(false)
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Third-party widgets get a PluginBarApi facade, where the flag is read-only
  // and writes go through a method; the shell's own panels see the real Bar.
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- Settings ----------------------------------------------------------

  // Applied locally first so the panel reacts on the keystroke itself; the
  // shell.json write comes back through the bar as the same value. The host
  // widget is kept in step so it does not write a stale copy back out.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function focusField() {
    flightField.selectAll()
    flightField.forceActiveFocus()
  }

  function blurField() {
    if (keyCatcher) keyCatcher.forceActiveFocus()
  }

  function commitField() {
    var typed = String(flightField.text || "").trim()
    if (typed === "") {
      clearFlight()
      blurField()
      return
    }
    var code = Model.normalizeFlightCode(typed)
    if (code === "") {
      root.fieldError = "That does not look like a flight number"
      return
    }
    root.fieldError = ""
    flightField.text = code
    if (code !== root.flightCode) persistSettings({ flight: code })
    else root.refresh()
    blurField()
  }

  function cancelField() {
    root.fieldError = ""
    flightField.text = root.flightCode
    blurField()
  }

  function clearFlight() {
    root.fieldError = ""
    flightField.text = ""
    if (root.flightCode !== "") persistSettings({ flight: "" })
  }

  // ---- Fetching ----------------------------------------------------------
  //
  // Order per poll: FR24 schedule (at most once a minute) → adsbdb once,
  // for the airline name or as the route fallback → adsb.lol position by
  // hex then callsigns → FR24 trail when the flight is in the air.

  onFlightCodeChanged: {
    if (!flightField.activeFocus) flightField.text = flightCode
    reload()
  }

  // Full restart: forget everything about the previous flight.
  function reload() {
    scheduleProc.running = false
    routeProc.running = false
    liveProc.running = false
    trailProc.running = false
    schedule = null
    scheduleUpdatedAt = 0
    route = null
    airlineName = ""
    adsbLive = null
    trailLive = null
    trailPoints = []
    liveCallsign = ""
    candidates = []
    candidateIndex = 0
    liveStatus = "idle"
    routeStatus = "idle"
    scheduleStatus = hasFlight ? "loading" : "idle"
    if (hasFlight) startSchedule()
  }

  function refresh() {
    if (!hasFlight || busy) return
    now = Date.now()
    if (scheduleStatus === "idle" || scheduleStatus === "offline" || now - scheduleUpdatedAt > 60000) startSchedule()
    else afterSchedule()
  }

  // ---- Bounded fetches.
  //
  // Every response is capped at the producer: curl refuses a body whose
  // announced size is over the limit, and head cuts a chunked one at
  // limit + 1 bytes. A body that arrives at limit + 1 is an overflow and is
  // dropped unparsed (readBounded returns null), so a hostile or broken
  // endpoint can at most cost one wasted poll. Arguments reach the shell
  // as positional parameters, never spliced into the command text, and
  // only https without redirects is allowed.
  readonly property int scheduleMaxBytes: 1024 * 1024
  readonly property int routeMaxBytes: 256 * 1024
  readonly property int liveMaxBytes: 512 * 1024
  readonly property int trailMaxBytes: 4 * 1024 * 1024

  function fetchCommand(url, agent, maxTime, maxBytes) {
    return ["/usr/bin/sh", "-c",
      '/usr/bin/curl -sS --proto =https --max-time "$1" --max-filesize "$2" -A "$3" -- "$4" | /usr/bin/head -c "$5"',
      "sh", String(maxTime), String(maxBytes), agent, url, String(maxBytes + 1)]
  }

  // The collector's text, or null when the body hit the cap.
  function readBounded(collector, maxBytes) {
    var size = collector.data ? collector.data.byteLength : 0
    if (size > maxBytes) return null
    return String(collector.text || "").trim()
  }

  function startSchedule() {
    scheduleStatus = "loading"
    scheduleProc.command = fetchCommand(
      "https://api.flightradar24.com/common/v1/flight/list.json?query=" + flightCode + "&fetchBy=flight&limit=25&page=1",
      browserAgent, 10, scheduleMaxBytes)
    scheduleProc.running = true
  }

  // With a schedule the airports come from it and adsbdb only supplies the
  // airline name, once. Without one adsbdb is the route.
  function afterSchedule() {
    if (routeStatus === "idle" || (routeStatus === "offline" && !route)) startRoute()
    else startLive(true)
  }

  function startRoute() {
    routeStatus = "loading"
    routeProc.command = fetchCommand("https://api.adsbdb.com/v0/callsign/" + flightCode, userAgent, 8, routeMaxBytes)
    routeProc.running = true
  }

  function startLive(restart) {
    // Nobody is in the air to look for well before departure or after
    // landing; skip the feed rather than walk every callsign each poll.
    var departure = Model.departureEstimate(schedule)
    if ((phase === "scheduled" && departure !== null && departure > nowSeconds + 1800) || phase === "landed") {
      adsbLive = null
      liveStatus = "none"
      startTrail()
      return
    }
    if (restart) {
      var list = []
      if (schedule && schedule.hex !== "") list.push({ kind: "hex", value: schedule.hex })
      var callsigns = Model.liveCallsignCandidates(flightCode, route, liveCallsign, schedule)
      for (var i = 0; i < callsigns.length; i++) list.push({ kind: "callsign", value: callsigns[i] })
      candidates = list
      candidateIndex = 0
    }
    if (candidateIndex >= candidates.length) {
      adsbLive = null
      liveStatus = "none"
      startTrail()
      return
    }
    if (!adsbLive) liveStatus = "loading"
    var candidate = candidates[candidateIndex]
    liveProc.command = fetchCommand(
      "https://api.adsb.lol/v2/" + (candidate.kind === "hex" ? "hex/" : "callsign/") + candidate.value,
      userAgent, 8, liveMaxBytes)
    liveProc.running = true
  }

  function startTrail() {
    if (!schedule || !schedule.flightId || phase !== "departed") {
      trailLive = null
      trailPoints = []
      return
    }
    trailProc.command = fetchCommand(
      "https://data-live.flightradar24.com/clickhandler/?flight=" + schedule.flightId + "&version=1.5",
      browserAgent, 10, trailMaxBytes)
    trailProc.running = true
  }

  // Results are handled on exit rather than on the collector's own signal:
  // with waitForEnd the process only counts as exited once stdout is fully
  // read, so by then `running` is false and the next request can start.
  Process {
    id: scheduleProc
    stdout: StdioCollector { id: scheduleOut; waitForEnd: true }
    onExited: function(exitCode) {
      var raw = root.readBounded(scheduleOut, root.scheduleMaxBytes)
      // Overflow counts as an unusable body, not as the network being down.
      if (raw === null) raw = "overflow"
      var parsed = raw === "" ? null : Model.parseSchedule(raw, root.nowSeconds)
      if (parsed) {
        root.schedule = parsed
        root.scheduleStatus = "ok"
        root.scheduleUpdatedAt = Date.now()
        root.route = Model.routeFromSchedule(parsed)
      } else {
        // Empty is the network; a body that is not the list is Cloudflare
        // or an unknown number. Either way adsbdb still gives a route.
        root.scheduleStatus = raw === "" ? "offline" : "unknown"
        root.scheduleUpdatedAt = Date.now()
      }
      root.afterSchedule()
    }
  }

  Process {
    id: routeProc
    stdout: StdioCollector { id: routeOut; waitForEnd: true }
    onExited: function(exitCode) {
      var raw = root.readBounded(routeOut, root.routeMaxBytes)
      if (raw === null) raw = "overflow"
      if (raw === "") {
        root.routeStatus = "offline"
        if (!root.route) retryTimer.restart()
        else root.startLive(true)
        return
      }
      var parsed = Model.parseRoute(raw)
      root.routeStatus = parsed ? "ok" : "unknown"
      if (parsed) {
        root.airlineName = parsed.airlineName
        if (!root.route) root.route = parsed
      }
      // Unknown to the route database is not the same as not flying: an
      // ICAO callsign typed directly can still be found on ADS-B.
      root.startLive(true)
    }
  }

  Process {
    id: liveProc
    stdout: StdioCollector { id: liveOut; waitForEnd: true }
    onExited: function(exitCode) {
      var raw = root.readBounded(liveOut, root.liveMaxBytes)
      if (raw === null) raw = "overflow"
      if (raw === "") {
        root.liveStatus = "offline"
        root.startTrail()
        return
      }
      var parsed = Model.parseLive(raw)
      if (parsed) {
        root.adsbLive = parsed
        var candidate = root.candidates[root.candidateIndex]
        if (candidate && candidate.kind === "callsign") root.liveCallsign = candidate.value
        root.liveUpdatedAt = Date.now()
        root.now = root.liveUpdatedAt
        root.liveStatus = "ok"
        root.startTrail()
        return
      }
      root.candidateIndex++
      root.startLive(false)
    }
  }

  Process {
    id: trailProc
    stdout: StdioCollector { id: trailOut; waitForEnd: true }
    onExited: function(exitCode) {
      var raw = root.readBounded(trailOut, root.trailMaxBytes)
      var parsed = raw === null ? null : Model.parseTrail(raw, root.nowSeconds)
      if (!parsed) return
      root.trailLive = parsed.live
      root.trailPoints = parsed.points
      root.trailUpdatedAt = Date.now()
      root.now = root.trailUpdatedAt
    }
  }

  // A dropped request (waking before the network is back, a flaky hop)
  // gets one quick retry rather than waiting out the poll interval.
  Timer {
    id: retryTimer
    interval: 4000
    onTriggered: root.refresh()
  }

  // Faster while someone is looking at it, slower in the background so the
  // bar tooltip stays roughly right without hammering the feed.
  Timer {
    id: pollTimer
    interval: (root.opened ? 15 : root.refreshSeconds) * 1000
    running: root.hasFlight
    repeat: true
    onTriggered: root.refresh()
  }

  // Drives the "12s ago" read-out and the time-based progress while the
  // panel is open.
  Timer {
    interval: 1000
    running: root.opened && root.hasFlight
    repeat: true
    onTriggered: root.now = Date.now()
  }

  // IPC lives on BarWidget.qml, which owns the target and forwards here.

  // ---- Status copy -------------------------------------------------------

  readonly property string statusText: {
    if (!hasFlight) return ""
    if (scheduleStatus === "loading" && !schedule && !route) return "Looking up " + flightCode + "…"
    if (routeStatus === "loading" && !route) return "Looking up " + flightCode + "…"
    if (scheduleStatus === "offline" && routeStatus === "offline" && !route) return "Could not reach the flight services"
    if (live) {
      var parts = ["Position " + Model.formatAgo(liveAgeSeconds) + (live.source === "fr24" ? " via FR24" : " via ADS-B")]
      if (liveStale) parts.push("signal lost")
      if (offRoute) parts.push("not on the listed " + Model.airportLabel(route.origin) + "–" + Model.airportLabel(route.destination) + " leg")
      return parts.join(" · ")
    }
    if (liveStatus === "loading" && inFlight) return "Searching for the aircraft…"
    if (positionEstimated) return "Position estimated from the schedule · no live signal yet"
    if (phase === "scheduled" || phase === "landed") return "Local airport times"
    if (liveStatus === "offline") return "Could not reach the ADS-B feed"
    if (liveStatus === "none") {
      if (!route) return "No route or aircraft found for " + flightCode
      return "Not airborne right now"
    }
    return ""
  }

  readonly property string metaLine: {
    var parts = []
    if (airlineName) parts.push(airlineName)
    var type = (live && live.type) || (schedule && schedule.aircraftModel) || ""
    var reg = (live && live.registration) || (schedule && schedule.registration) || ""
    if (type || reg) parts.push((type + " " + reg).trim())
    var callsign = (live && live.callsign) || (schedule && schedule.callsign) || (route && route.callsignIcao) || ""
    if (callsign) parts.push(callsign)
    return parts.join("  ·  ")
  }

  // "Sep 4 · Departed 19:05 · arriving 21:57 · on time"
  readonly property string scheduleLine: schedule
    ? Model.formatDateShort(schedule.scheduledDeparture, schedule.origin.tzOffset) + " · " + Model.statusLabel(schedule) : ""
  readonly property color scheduleDotColor: phase === "departed" ? accentColor : (phase === "landed" ? contentForeground : faint)

  // The small line under each airport's scheduled time.
  readonly property string departureNote: {
    if (!schedule) return ""
    if (schedule.realDeparture !== null) return "Departed " + Model.formatLocalTime(schedule.realDeparture, schedule.origin.tzOffset)
    if (schedule.estimatedDeparture !== null && Math.abs(Model.delayMinutes(schedule.scheduledDeparture, schedule.estimatedDeparture)) >= 5)
      return "Est. " + Model.formatLocalTime(schedule.estimatedDeparture, schedule.origin.tzOffset)
    return ""
  }
  readonly property bool departureLate: schedule && Model.delayMinutes(schedule.scheduledDeparture, Model.departureEstimate(schedule)) > 10

  readonly property string arrivalNote: {
    if (!schedule) return ""
    if (schedule.realArrival !== null) return "Landed " + Model.formatLocalTime(schedule.realArrival, schedule.destination.tzOffset)
    if (phase === "departed") return "Arriving " + Model.formatLocalTime(Model.arrivalEstimate(schedule), schedule.destination.tzOffset)
    if (schedule.estimatedArrival !== null && Math.abs(Model.delayMinutes(schedule.scheduledArrival, schedule.estimatedArrival)) >= 5)
      return "Est. " + Model.formatLocalTime(schedule.estimatedArrival, schedule.destination.tzOffset)
    return ""
  }
  readonly property bool arrivalLate: schedule && Model.delayMinutes(schedule.scheduledArrival, Model.arrivalEstimate(schedule)) > 10

  readonly property string railLabel: {
    if (inFlight) {
      var pct = Math.round(fraction * 100) + "%"
      return schedule && phase === "departed" ? pct + " · " + Model.formatDuration(timeLeftSeconds) + " left" : pct
    }
    if (phase === "landed") return "Landed"
    if (schedule && schedule.scheduledDeparture !== null && schedule.scheduledArrival !== null)
      return Model.formatDuration(schedule.scheduledArrival - schedule.scheduledDeparture)
    return ""
  }

  // ---- UI ----------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: flightField.activeFocus
      onReturnRequested: root.focusField()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "/" || t === "f" || t === "F") root.focusField()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(14)

        // ---- Flight number field, always on top: it is the one control the
        //      panel exists for.
        Item {
          width: parent.width
          height: fieldRow.height + (root.fieldError !== "" ? errorText.height + Style.space(4) : 0)

          Row {
            id: fieldRow
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: flightField
              width: parent.width - clearButton.width - parent.spacing
              placeholderText: "Flight number, e.g. LA3195"
              foreground: root.contentForeground
              font.family: root.contentFontFamily
              font.letterSpacing: 1
              text: root.flightCode

              onTextChanged: if (root.fieldError !== "") root.fieldError = ""

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  root.cancelField()
                  event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.commitField()
                  event.accepted = true
                }
              }
            }

            // Stop tracking. While a lookup is in flight the same slot spins.
            Rectangle {
              id: clearButton
              width: flightField.height
              height: flightField.height
              radius: Style.cornerRadius
              color: !root.busy && clearArea.containsMouse ? Style.hoverFillFor(root.contentForeground, Color.accent) : "transparent"
              border.width: Style.spacing.hairline
              border.color: root.tint(0.15)

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: root.busy ? "󰦖" : (root.hasFlight ? "✕" : "󰍉")
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.icon
                color: root.dim

                RotationAnimator on rotation {
                  running: root.busy
                  from: 0; to: 360
                  duration: 800
                  loops: Animation.Infinite
                }
              }

              MouseArea {
                id: clearArea
                anchors.fill: parent
                enabled: !root.busy
                hoverEnabled: true
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                  if (root.hasFlight) root.clearFlight()
                  else root.commitField()
                }
              }

              PanelToolTip {
                visible: clearArea.containsMouse && !root.busy
                text: root.hasFlight ? "Stop tracking" : "Track"
                fontFamily: root.contentFontFamily
              }
            }
          }

          Text {
            id: errorText
            textFormat: Text.PlainText
            anchors.top: fieldRow.bottom
            anchors.topMargin: Style.space(4)
            visible: root.fieldError !== ""
            text: root.fieldError
            color: Color.urgent
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---- Empty state.
        Column {
          visible: !root.hasFlight
          width: parent.width
          spacing: Style.space(6)
          topPadding: Style.space(18)
          bottomPadding: Style.space(18)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "󰀝"
            color: root.faint
            font.family: root.contentFontFamily
            font.pixelSize: 56
          }

          Text {
            textFormat: Text.PlainText
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Type a flight number and press Enter"
            color: root.dim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            textFormat: Text.PlainText
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Airline code plus number: LA3195, AD4242, BA247, or an ICAO callsign like TAM3195"
            color: root.faint
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            width: parent.width - Style.space(40)
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }
        }

        // ---- Route hero: origin, progress rail, destination. Under each
        //      code sits the scheduled time in that airport's own clock,
        //      then what actually happened to it.
        Item {
          visible: root.hasRoute
          width: parent.width
          height: heroRow.height

          Row {
            id: heroRow
            width: parent.width
            spacing: Style.space(16)

            Column {
              id: originColumn
              width: Style.space(120)
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: Model.airportLabel(root.route ? root.route.origin : null)
                color: root.contentForeground
                font.family: root.contentFontFamily
                // Hero airport codes; deliberately outside the Style.font.*
                // scale, like the weather panel's temperature.
                font.pixelSize: 36
                font.bold: true
              }
              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: Model.airportCity(root.route ? root.route.origin : null).toUpperCase()
                color: root.dim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
                elide: Text.ElideRight
              }
              Text {
                textFormat: Text.PlainText
                visible: root.schedule !== null
                topPadding: Style.space(6)
                text: root.schedule ? Model.formatLocalTime(root.schedule.scheduledDeparture, root.schedule.origin.tzOffset) : ""
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.heading
              }
              Text {
                textFormat: Text.PlainText
                visible: root.departureNote !== ""
                text: root.departureNote
                color: root.departureLate ? Color.urgent : root.dim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }

            // The rail: how much of the trip is behind the aircraft. The
            // plane glyph rides the boundary between the flown and the
            // remaining track; by the clock when no one can see the plane.
            Item {
              id: rail
              width: parent.width - originColumn.width - destinationColumn.width - parent.spacing * 2
              height: originColumn.height
              anchors.verticalCenter: parent.verticalCenter

              readonly property real inset: Style.space(6)
              readonly property real span: width - inset * 2
              readonly property real planeX: inset + span * root.fraction
              readonly property bool showProgress: root.inFlight || root.phase === "landed"

              Rectangle {
                id: railTrack
                x: rail.inset
                y: Math.round(originColumn.height * 0.32)
                width: rail.span
                height: Style.space(2)
                color: root.tint(0.15)
              }

              Rectangle {
                x: rail.inset
                anchors.verticalCenter: railTrack.verticalCenter
                width: rail.showProgress ? Math.round(rail.span * root.fraction) : 0
                height: railTrack.height
                color: root.accentColor
                opacity: root.positionEstimated ? 0.6 : 1
                Behavior on width { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
              }

              Rectangle {
                x: rail.inset - width / 2
                anchors.verticalCenter: railTrack.verticalCenter
                width: Style.space(6); height: width; radius: width / 2
                color: rail.showProgress ? root.accentColor : root.tint(0.35)
              }

              Rectangle {
                x: rail.inset + rail.span - width / 2
                anchors.verticalCenter: railTrack.verticalCenter
                width: Style.space(6); height: width; radius: width / 2
                color: root.phase === "landed" ? root.accentColor : "transparent"
                border.width: Style.spacing.hairline
                border.color: root.tint(0.5)
              }

              Text {
                visible: root.inFlight
                x: rail.planeX - width / 2
                anchors.verticalCenter: railTrack.verticalCenter
                text: "󰀝"
                rotation: 90
                color: root.contentForeground
                opacity: root.positionEstimated ? 0.5 : 1
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.iconLarge
                Behavior on x { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
              }

              Text {
                textFormat: Text.PlainText
                visible: root.railLabel !== ""
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: railTrack.bottom
                anchors.topMargin: Style.space(8)
                text: root.railLabel
                color: root.inFlight ? root.contentForeground : root.dim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                textFormat: Text.PlainText
                visible: root.positionEstimated
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: railTrack.bottom
                anchors.topMargin: Style.space(8) + Style.font.bodySmall + Style.space(4)
                text: "estimated"
                color: root.faint
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
            }

            Column {
              id: destinationColumn
              width: Style.space(120)
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                horizontalAlignment: Text.AlignRight
                text: Model.airportLabel(root.route ? root.route.destination : null)
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: 36
                font.bold: true
              }
              Text {
                textFormat: Text.PlainText
                width: parent.width
                horizontalAlignment: Text.AlignRight
                text: Model.airportCity(root.route ? root.route.destination : null).toUpperCase()
                color: root.dim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
                elide: Text.ElideRight
              }
              Text {
                textFormat: Text.PlainText
                visible: root.schedule !== null
                width: parent.width
                horizontalAlignment: Text.AlignRight
                topPadding: Style.space(6)
                text: root.schedule ? Model.formatLocalTime(root.schedule.scheduledArrival, root.schedule.destination.tzOffset) : ""
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.heading
              }
              Text {
                textFormat: Text.PlainText
                visible: root.arrivalNote !== ""
                width: parent.width
                horizontalAlignment: Text.AlignRight
                text: root.arrivalNote
                color: root.arrivalLate ? Color.urgent : root.dim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        // ---- Status line: the date and where the flight stands.
        Row {
          visible: root.scheduleLine !== ""
          width: parent.width
          spacing: Style.space(8)

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(8); height: width; radius: width / 2
            color: root.scheduleDotColor

            SequentialAnimation on opacity {
              running: root.phase === "departed"
              loops: Animation.Infinite
              NumberAnimation { from: 1; to: 0.35; duration: 1200; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.35; to: 1; duration: 1200; easing.type: Easing.InOutSine }
            }
          }

          Text {
            textFormat: Text.PlainText
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Style.space(16)
            text: root.scheduleLine
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }
        }

        Text {
          textFormat: Text.PlainText
          visible: root.metaLine !== ""
          width: parent.width
          text: root.metaLine
          color: root.dim
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        // ---- Globe card: the Earth seen from above the route, with the
        //      continents, a graticule, the great-circle track and the
        //      aircraft. Zoomed so the route fills the card; the disc may
        //      be larger than the card, which then shows the curved surface.
        Rectangle {
          id: mapCard
          visible: root.mapPoints.length > 0
          width: parent.width
          height: Style.space(230)
          radius: Style.cornerRadius
          color: root.tint(0.03)
          border.width: Style.spacing.hairline
          border.color: root.tint(0.1)
          clip: true

          readonly property real pad: Style.space(26)
          readonly property var view: Model.globeView(root.mapPoints, width, height, pad, 22)
          readonly property real globeRadius: view ? view.radius : 0
          readonly property real globeX: view ? view.cx : width / 2
          readonly property real globeY: view ? view.cy : height / 2

          function at(point) {
            if (!view) return { x: 0, y: 0, visible: false }
            return Model.orthographic(point.lat, point.lon, view)
          }

          function multiline(runs) {
            var out = []
            for (var i = 0; i < runs.length; i++) {
              var run = []
              for (var j = 0; j < runs[i].length; j++) run.push(Qt.point(runs[i][j].x, runs[i][j].y))
              out.push(run)
            }
            return out
          }

          function visibleLines(points) {
            return view ? multiline(Model.projectPolylineVisible(points, view)) : []
          }

          // Continents: filled rings (hidden vertices pulled to the rim so
          // the polygon stays closed) plus the coastline as visible runs.
          readonly property var landRings: {
            if (!view) return []
            var rings = Model.landRings(World.LAND)
            var out = []
            for (var i = 0; i < rings.length; i++) {
              var ring = Model.projectRingClamped(rings[i], view)
              if (ring) out.push(ring)
            }
            return multiline(out)
          }
          readonly property var coastLines: {
            if (!view) return []
            var rings = Model.landRings(World.LAND)
            var out = []
            for (var i = 0; i < rings.length; i++) {
              var closed = rings[i].concat([rings[i][0]])
              var runs = Model.projectPolylineVisible(closed, view)
              for (var r = 0; r < runs.length; r++) out.push(runs[r])
            }
            return multiline(out)
          }
          readonly property var graticuleLines: {
            if (!view) return []
            var lines = Model.graticule(15)
            var out = []
            for (var i = 0; i < lines.length; i++) {
              var runs = Model.projectPolylineVisible(lines[i], view)
              for (var r = 0; r < runs.length; r++) out.push(runs[r])
            }
            return multiline(out)
          }

          readonly property var fullArc: root.route
            ? visibleLines(Model.greatCirclePoints(root.route.origin, root.route.destination, 64)) : []
          // The part flown: the real path when FR24 has one, else a great
          // circle to the position, else to where the clock puts it.
          readonly property var flownArc: {
            if (!root.route || !view) return []
            if (root.trailPoints.length > 1) return visibleLines(root.trailPoints)
            if (root.live) return visibleLines(Model.greatCirclePoints(root.route.origin, root.live, 32))
            if (root.estimatedPoint) return visibleLines(Model.greatCirclePoints(root.route.origin, root.estimatedPoint, 32))
            return []
          }
          readonly property var planePoint: root.live || root.estimatedPoint
          readonly property var planeAt: planePoint && view ? at(planePoint) : null
          readonly property real planeTrack: root.live && root.live.track !== null
            ? root.live.track
            : (root.estimatedPoint && root.route
              ? Model.bearingDeg(root.estimatedPoint.lat, root.estimatedPoint.lon, root.route.destination.lat, root.route.destination.lon) : 0)

          // The planet: a shaded disc with a thin atmosphere around it.
          Shape {
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
              strokeWidth: 0
              strokeColor: "transparent"
              fillGradient: RadialGradient {
                centerX: mapCard.globeX - mapCard.globeRadius * 0.25
                centerY: mapCard.globeY - mapCard.globeRadius * 0.25
                centerRadius: mapCard.globeRadius * 1.3
                focalX: centerX
                focalY: centerY
                GradientStop { position: 0; color: root.tint(0.13) }
                GradientStop { position: 0.6; color: root.tint(0.07) }
                GradientStop { position: 1; color: root.tint(0.02) }
              }
              PathAngleArc {
                centerX: mapCard.globeX
                centerY: mapCard.globeY
                radiusX: mapCard.globeRadius
                radiusY: mapCard.globeRadius
                startAngle: 0
                sweepAngle: 360
              }
            }

            ShapePath {
              strokeWidth: Style.space(3)
              strokeColor: root.tint(0.05)
              fillColor: "transparent"
              PathAngleArc {
                centerX: mapCard.globeX
                centerY: mapCard.globeY
                radiusX: mapCard.globeRadius + Style.space(2)
                radiusY: mapCard.globeRadius + Style.space(2)
                startAngle: 0
                sweepAngle: 360
              }
            }

            ShapePath {
              strokeWidth: 1
              strokeColor: root.tint(0.18)
              fillColor: "transparent"
              PathAngleArc {
                centerX: mapCard.globeX
                centerY: mapCard.globeY
                radiusX: mapCard.globeRadius
                radiusY: mapCard.globeRadius
                startAngle: 0
                sweepAngle: 360
              }
            }

            // Meridians and parallels.
            ShapePath {
              strokeWidth: 1
              strokeColor: root.tint(0.06)
              fillColor: "transparent"
              PathMultiline { paths: mapCard.graticuleLines }
            }

            // Land, filled, then its coastline.
            ShapePath {
              strokeWidth: 0
              strokeColor: "transparent"
              fillColor: root.tint(0.10)
              fillRule: ShapePath.WindingFill
              PathMultiline { paths: mapCard.landRings }
            }

            ShapePath {
              strokeWidth: 1
              strokeColor: root.tint(0.26)
              joinStyle: ShapePath.RoundJoin
              fillColor: "transparent"
              PathMultiline { paths: mapCard.coastLines }
            }

            // The whole route, dashed and quiet.
            ShapePath {
              strokeColor: root.tint(0.4)
              strokeWidth: Style.space(1.5)
              strokeStyle: ShapePath.DashLine
              dashPattern: [1, 4]
              capStyle: ShapePath.RoundCap
              fillColor: "transparent"
              PathMultiline { paths: mapCard.fullArc }
            }

            // The part already flown, solid.
            ShapePath {
              strokeColor: root.positionEstimated
                ? Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.5) : root.accentColor
              strokeWidth: Style.space(2)
              capStyle: ShapePath.RoundCap
              joinStyle: ShapePath.RoundJoin
              fillColor: "transparent"
              PathMultiline { paths: mapCard.flownArc }
            }
          }

          // Airports.
          Repeater {
            model: root.route ? [
              { airport: root.route.origin, origin: true },
              { airport: root.route.destination, origin: false }
            ] : []

            Item {
              required property var modelData
              readonly property var pos: mapCard.at(modelData.airport)
              visible: pos.visible
              x: pos.x
              y: pos.y

              Rectangle {
                anchors.centerIn: parent
                width: Style.space(7); height: width; radius: width / 2
                color: modelData.origin ? (root.inFlight || root.phase === "landed" ? root.accentColor : root.tint(0.5)) : mapCard.color
                border.width: modelData.origin ? 0 : Style.spacing.hairline
                border.color: root.tint(0.6)
              }

              Text {
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: Style.space(7)
                text: Model.airportLabel(modelData.airport)
                color: root.dim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1
              }
            }
          }

          // The aircraft, nose pointed along its track.
          Item {
            visible: mapCard.planeAt !== null && mapCard.planeAt.visible
            x: mapCard.planeAt ? mapCard.planeAt.x : 0
            y: mapCard.planeAt ? mapCard.planeAt.y : 0
            Behavior on x { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
            Behavior on y { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }

            Rectangle {
              anchors.centerIn: parent
              visible: root.airborne
              width: Style.space(26); height: width; radius: width / 2
              color: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, root.liveStale ? 0.06 : 0.16)

              SequentialAnimation on scale {
                running: root.airborne && !root.liveStale
                loops: Animation.Infinite
                NumberAnimation { from: 0.85; to: 1.15; duration: 1400; easing.type: Easing.InOutSine }
                NumberAnimation { from: 1.15; to: 0.85; duration: 1400; easing.type: Easing.InOutSine }
              }
            }

            Text {
              anchors.centerIn: parent
              text: "󰀝"
              rotation: mapCard.planeTrack
              color: root.liveStale ? root.dim : root.contentForeground
              opacity: root.positionEstimated ? 0.5 : 1
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.iconLarge
              Behavior on rotation { RotationAnimation { duration: 600; direction: RotationAnimation.Shortest } }
            }
          }

          // Scale note in the corner: total route length.
          Text {
            textFormat: Text.PlainText
            visible: root.hasRoute
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: Style.space(8)
            text: root.route ? Model.formatDistance(root.route.distanceKm) + " route" : ""
            color: root.faint
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---- Stats.
        Row {
          visible: root.airborne
          width: parent.width

          Repeater {
            model: [
              { label: "ALTITUDE", value: Model.formatAltitude(root.live), note: Model.formatVerticalRate(root.live ? root.live.verticalRateFpm : null) },
              { label: "SPEED", value: Model.formatSpeed(root.live ? root.live.groundSpeedKt : null), note: root.live && root.live.groundSpeedKt !== null ? Math.round(root.live.groundSpeedKt) + " kt" : "" },
              { label: "HEADING", value: Model.formatHeading(root.live ? root.live.track : null), note: "" },
              { label: "TO GO", value: Model.formatDistance(root.progress ? root.progress.remainingKm : null), note: root.progress ? Model.formatDistance(root.progress.flownKm) + " flown" : "" },
              root.schedule && root.phase === "departed"
                ? { label: "ETA", value: Model.formatLocalTime(Model.arrivalEstimate(root.schedule), root.schedule.destination.tzOffset), note: Model.formatDuration(root.timeLeftSeconds) + " left" }
                : { label: "ETA", value: Model.formatEta(root.progress ? root.progress.remainingKm : null, root.live ? root.live.groundSpeedKt : null), note: "at current speed" }
            ]

            Column {
              required property var modelData
              width: parent.width / 5
              spacing: Style.space(3)

              Text {
                textFormat: Text.PlainText
                text: modelData.label
                color: root.dim
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
              Text {
                textFormat: Text.PlainText
                text: modelData.value
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Text {
                textFormat: Text.PlainText
                visible: modelData.note !== ""
                text: modelData.note
                color: root.faint
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        // ---- Footer: what is going on, and a way to poke it.
        Item {
          visible: root.hasFlight
          width: parent.width
          height: Math.max(statusLabel.implicitHeight, refreshButton.height)

          Text {
            id: statusLabel
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: refreshButton.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: root.statusText
            color: root.liveStale || root.liveStatus === "offline" || root.routeStatus === "offline" ? Color.urgent : root.dim
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          PanelActionButton {
            id: refreshButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰑐"
            tooltipText: "Refresh"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: root.refresh()
          }
        }
      }
    }
  }
}
