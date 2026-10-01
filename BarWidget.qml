import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "abukiya.proxy"

  property bool proxyEnabled: false
  property bool opened: false

  // Reuse the Service singleton's cachedStatus instead of spawning a separate
  // Process every 3s. `bar.shell.serviceFor` is the same object the Panel
  // reads via its injected `service` prop -- no extra wakeups, and status is
  // available even when the panel is closed.
  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("abukiya.proxy") : null
  readonly property string cachedStatus: service ? service.cachedStatus : ""

  function open() {
    if (!root.bar) return
    root.bar.run("omarchy-shell shell toggle abukiya.proxy")
  }

  function close() {
    if (!root.bar || !root.opened) return
    root.bar.run("omarchy-shell shell toggle abukiya.proxy")
  }

  function refresh() {
    // Fallback IPC poll for the case the service is not yet available
    // (e.g. shell just started and the service instance hasn't mounted).
    if (root.service && root.service.cachedStatus && root.service.cachedStatus !== "{}") return
    statusProc.running = true
  }

  readonly property bool iconActive: root.proxyEnabled

  function onStatus(raw) {
    var obj = null
    try { obj = JSON.parse(String(raw || "").trim()) } catch (e) {}
    if (!obj) return
    root.proxyEnabled = obj.enabled === true
  }

  onCachedStatusChanged: root.onStatus(root.cachedStatus)

  // Keep initial value in sync when the service appears or changes.
  onServiceChanged: {
    if (root.cachedStatus) root.onStatus(root.cachedStatus)
  }

  Component.onCompleted: {
    if (root.cachedStatus) root.onStatus(root.cachedStatus)
  }

  Process {
    id: statusProc
    command: ["omarchy-shell", "abukiya.proxy", "status"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onStatus(text)
    }
  }

  // Lightweight heartbeat for the fallback path only: when service is
  // unavailable we still need to poll IPC. Once the service appears,
  // this timer keeps firing but refresh() short-circuits immediately,
  // so no Process is spawned. Interval slightly longer than the old 3s
  // since the service path is near-instant.
  Timer {
    id: pollTimer
    interval: 3000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: " "
    keepSpace: true
    tooltipText: root.proxyEnabled
      ? "Proxy on \u2014 click to open the panel"
      : "Proxy off \u2014 click to open the panel"
    activeColor: bar ? bar.barForeground : Color.foreground
    active: root.iconActive
    fixedWidth: root.bar && root.bar.vertical ? -1 : Style.space(27)
    fixedHeight: root.bar && root.bar.vertical ? Style.space(26) : -1
    onPressed: function(b) {
      if (b !== 1) return
      root.open()
    }

    ProxyIcon {
      anchors.centerIn: parent
      iconSize: Style.font.icon
      width: Style.font.icon
      height: Style.font.icon
      color: button.active && button.useActiveColor ? button.activeColor : button.foreground
      opacity: root.proxyEnabled ? 1 : 0.7
    }
  }
}
