import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "abukiya.proxy"

  property bool proxyEnabled: false
  property bool opened: false

  function open() {
    if (!root.bar) return
    root.bar.run("omarchy-shell shell toggle abukiya.proxy")
  }

  function close() {
    if (!root.bar || !root.opened) return
    root.bar.run("omarchy-shell shell toggle abukiya.proxy")
  }

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
    text: root.iconText
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
  }
}
