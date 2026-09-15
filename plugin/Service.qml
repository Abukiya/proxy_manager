import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var shell: null
  property var manifest: null

  // Resolve the sibling script from this file's location, NOT the manifest:
  // the shell strips `__sourceDir` from the manifest it injects into
  // third-party plugins, so `manifest.__sourceDir` would always be empty and
  // every IPC command would silently no-op (panel showed "Failed to enable").
  readonly property string scriptPath: {
    var u = Qt.resolvedUrl("proxy-manager.sh").toString()
    return u.startsWith("file://") ? u.slice(7) : u
  }

  property string cachedStatus: "{}"
  property bool busy: false
  property var commandQueue: []

  function refreshStatus() {
    runScript(["status"])
  }

  function runScript(args) {
    if (root.scriptPath === "") return
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

    function refresh(): string {
      root.refreshStatus()
      return "ok"
    }
  }

  Component.onCompleted: Qt.callLater(refreshStatus)
  onManifestChanged: Qt.callLater(refreshStatus)
}
