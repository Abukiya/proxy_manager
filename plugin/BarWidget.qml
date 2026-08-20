import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar icon for the proxy manager. Reflects the current proxy state; clicking
// only opens/closes the panel — the proxy is toggled from the switch inside
// the panel, never from the icon.
//   left-click -> toggles the host panel open/closed (exactly like the sibling
//                 panel+widget plugins route `shell toggle <id>`).
// State is polled through the existing `abukiya.proxy status` IPC, which lags
// the real state by ~2s; the panel owns the optimistic "applying" state.
BarWidget {
  id: root
  moduleName: "abukiya.proxy"

  property bool proxyEnabled: false

  function refresh() {
    statusProc.running = true
  }

  readonly property string iconText: "\uF04D3"
  readonly property bool iconActive: root.proxyEnabled

  function onStatus(raw) {
    var obj = null
    try { obj = JSON.parse(String(raw || "").trim()) } catch (e) {}
    if (!obj) return
    root.proxyEnabled = obj.enabled === true
  }

  Process {
    id: statusProc
    command: ["omarchy-shell", "abukiya.proxy", "status"]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onStatus(text)
    }
  }

  Timer {
    id: pollTimer
    interval: 3000
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
    text: root.iconText
    tooltipText: root.proxyEnabled
      ? "Proxy on \u2014 click to open the panel"
      : "Proxy off \u2014 click to open the panel"
    foreground: Qt.darker(Color.accent, 1.6)
    activeColor: Color.accent
    active: root.iconActive
    fixedWidth: root.bar && root.bar.vertical ? -1 : Style.space(27)
    fixedHeight: root.bar && root.bar.vertical ? Style.space(26) : -1
    onPressed: function(b) {
      if (b !== 1) return
      if (!root.bar) return
      // Open/close the panel surface only. Proxy state is changed from the
      // panel's toggle switch (via `abukiya.proxy enable|disable` IPC).
      root.bar.run("omarchy-shell shell toggle abukiya.proxy")
    }
  }
}