import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Plane icon for the bar, and the host for the flight monitor popup.
//
// Left click opens the panel, right click refreshes the position, middle
// click opens the panel with the flight field focused. The icon dims while
// nothing is being tracked; while the tracked flight is in the air the
// percentage of the trip done rides next to it (horizontal bars only).
BarWidget {
  id: root
  moduleName: "io.github.maluta.flight-monitor"

  readonly property var panelItem: panelLoader.item
  readonly property string flightCode: panelItem ? panelItem.flightCode : ""
  readonly property bool inFlight: panelItem ? panelItem.inFlight === true : false
  readonly property string percentLabel: inFlight ? Math.round((panelItem.fraction || 0) * 100) + "%" : ""
  readonly property bool showLabel: !vertical && percentLabel !== ""

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  function openAndEdit() {
    if (!panelLoader.item) return
    panelLoader.item.openFromHotkey()
    Qt.callLater(panelLoader.item.focusField)
  }

  // ---- Shape contract for shell.summon/hide/toggle routing:
  //      Bar.findPanelWidget requires open/close/opened on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity: Bar.requestPopout prefers closeForPopoutSwitch over close, and
  // KeyboardPanel reads popoutSwitchClosing back off its owner.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: showLabel ? labelButton.implicitWidth : button.implicitWidth
  implicitHeight: showLabel ? labelButton.implicitHeight : button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

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

  IpcHandler {
    target: "io.github.maluta.flight-monitor"

    function refresh(): void { root.broadcast("refresh") }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function edit(): void { root.openAndEdit() }
    function track(code: string): void {
      if (panelLoader.item) panelLoader.item.persistSettings({ flight: code })
    }
    function clear(): void {
      if (panelLoader.item) panelLoader.item.clearFlight()
    }
  }

  function handlePress(b) {
    if (b === Qt.RightButton) root.refresh()
    else if (b === Qt.MiddleButton) root.openAndEdit()
    else root.togglePanel()
  }

  // Icon-only slot: nothing tracked, scheduled, landed, or a vertical bar.
  BarIconButton {
    id: button
    anchors.fill: parent
    visible: !root.showLabel
    bar: root.bar
    text: root.panelItem ? root.panelItem.label : "󰀝"
    dimmed: root.flightCode === ""
    tooltipText: root.panelItem ? root.panelItem.summary : ""

    onPressed: function(b) { root.handlePress(b) }
  }

  // In flight: plane plus the share of the trip done, as one text label.
  WidgetButton {
    id: labelButton
    anchors.fill: parent
    visible: root.showLabel
    bar: root.bar
    text: (root.panelItem ? root.panelItem.label : "󰀝") + " " + root.percentLabel
    hasVisualContent: root.showLabel
    horizontalMargin: 8.75
    verticalPadding: 8.75
    tooltipText: root.panelItem ? root.panelItem.summary : ""

    onPressed: function(b) { root.handlePress(b) }
  }
}
