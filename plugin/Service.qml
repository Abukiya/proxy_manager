import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  // Injected by omarchy-shell (the service loader).
  property var shell: null
  property var manifest: null

  readonly property string scriptPath: root.manifest
    ? root.manifest.__sourceDir + "/proxy-manager.sh"
    : ""

  // Last known status JSON, refreshed on load and after every command.
  property string cachedStatus: "{}"
  property bool busy: false
  property var commandQueue: []

  function refreshStatus() {
    runScript(["status"])
  }

  function runScript(args) {
    if (root.scriptPath === "") return
    // Serialize: queue commands instead of dropping them when one is running,
    // so rapid IPC calls (e.g. toggle then status) always apply in order.
    root.commandQueue.push(args)
    root.drainQueue()
  }

  function drainQueue() {
    if (root.busy || root.commandQueue.length === 0) return
    root.busy = true
    managerProcess.command = ["bash", root.scriptPath].concat(root.commandQueue.shift())
    managerProcess.running = true
  }

  function onOutput(output) {
    var text = String(output || "").trim()
    if (text !== "") root.cachedStatus = text
  }

  Process {
    id: managerProcess
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onOutput(text)
    }
    onExited: {
      root.busy = false
      Qt.callLater(root.drainQueue)
    }
  }

  IpcHandler {
    target: "abukiya.proxy"

    function status(): string {
      return root.cachedStatus
    }

    function enable(): string {
      root.runScript(["enable"])
      return "ok"
    }

    function disable(): string {
      root.runScript(["disable"])
      return "ok"
    }

    function toggle(): string {
      var enabled = false
      try {
        enabled = JSON.parse(root.cachedStatus).enabled === true
      } catch (e) {}
      root.runScript(enabled ? ["disable"] : ["enable"])
      return enabled ? "disabled" : "enabled"
    }
  }

  Component.onCompleted: Qt.callLater(refreshStatus)
  onManifestChanged: Qt.callLater(refreshStatus)
}