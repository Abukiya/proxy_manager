import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Proxy-manager panel. Summoned/toggled through the shell host:
//   omarchy-shell shell toggle abukiya.proxy
// The host calls open(payloadJson) / close() and reads `opened`.
//
// UI only: every state change goes through the EXISTING IPC commands
// (`omarchy-shell abukiya.proxy status|enable|disable`) served by Service.qml.
// No proxy logic lives here — this file just renders what the service reports
// and fires its commands. Because the status snapshot lags the real state by
// ~2s, toggling shows an optimistic "applying" state until a fresh snapshot
// converges on the requested value.
Item {
  id: root

  property bool opened: false
  readonly property string selfId: "abukiya.proxy"

  // Injected by the shell host: `shell` routes summon/close, `service` is the
  // live Service.qml singleton whose `cachedStatus` is exactly what the
  // `status` IPC returns (auto-refreshed on load and after every command).
  property var shell: null
  property var service: null

  // ------------------------------------------------------------------ style

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color dimmer: Qt.darker(foreground, 1.8)
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  // Slightly roomier than the stock panel padding so the card doesn't feel
  // cramped; the main column below breathes on Style.spacing.md per element.
  property int contentMargin: Math.max(Style.spacing.panelPadding, Style.space(20))
  property int contentSpacing: Style.space(12)

  // ------------------------------------------------------------- status model

  // Parsed status JSON from the `status` IPC (or null before the first
  // snapshot). {enabled, httpProxy, httpsProxy, noProxy, integrations, active}
  property var status: null
  property bool pending: false
  property bool targetEnabled: false

  // Value the toggle switch renders: optimistic while pending, otherwise the
  // authoritative enabled flag from the latest status snapshot.
  property bool displayEnabled: false

  // Safety net: if no snapshot converges on the target (command failed, status
  // unavailable), stop showing "applying" and render whatever is known.
  property Timer pendingGuard: Timer {
    interval: 8000
    onTriggered: {
      root.pending = false
    }
  }

  readonly property var integrationList: [
    { key: "git", label: "Git" },
    { key: "npm", label: "npm" },
    { key: "yarn", label: "yarn" },
    { key: "pip", label: "pip" },
    { key: "vscode", label: "VS Code" },
    { key: "browser", label: "Browser" },
    { key: "pacman", label: "Pacman / Yay" }
  ]

  function integrationActive(key) {
    return root.status && root.status.active ? root.status.active[key] === true : false
  }

  function parseStatus(raw) {
    var obj = null
    try { obj = JSON.parse(String(raw || "").trim()) } catch (e) {}
    if (!obj) return
    root.status = obj
    if (root.pending) {
      if (obj.enabled === root.targetEnabled) {
        root.pending = false
        root.pendingGuard.stop()
        root.displayEnabled = obj.enabled === true
      }
      // else: snapshot still reflects the pre-toggle state; keep showing the
      // optimistic value instead of flickering back to stale data.
    } else {
      root.displayEnabled = obj.enabled === true
    }
  }

  function refresh() {
    // Read through the service singleton when the host injected one; the
    // status IPC `status()` returns exactly its cachedStatus. Otherwise query
    // the IPC directly (identical data, one extra round-trip).
    if (root.service && root.service.cachedStatus) {
      root.parseStatus(root.service.cachedStatus)
    } else {
      statusProc.running = true
    }
  }

  function setTarget(next) {
    if (root.pending) return
    root.targetEnabled = next
    root.pending = true
    root.displayEnabled = next
    root.pendingGuard.restart()
    // Fire the existing IPC command; Service.qml does all the work.
    Util.execDetached("omarchy-shell abukiya.proxy " + (next ? "enable" : "disable"))
  }

  function toggleProxy() {
    root.setTarget(!root.displayEnabled)
  }

  Connections {
    target: root.service
    function onCachedStatusChanged() {
      root.parseStatus(root.service.cachedStatus)
    }
  }

  // Direct IPC fallback (and manual `r` refresh): calls `status` exactly the
  // way `omarchy-shell abukiya.proxy status` does.
  Process {
    id: statusProc
    command: ["omarchy-shell", "abukiya.proxy", "status"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseStatus(text)
    }
  }

  // ------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    root.opened = true
    root.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    if (!root.opened) return
    root.opened = false
    // Keep the host's openPanelIds in sync; hide() calls close() again and the
    // guard above breaks the recursion.
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.selfId)
  }

  // Self-restore: after the host's panel Instantiator rebuilds (e.g. plugin
  // reload), our `opened` resets but the host's openPanelIds survives.
  onShellChanged: {
    if (!root.opened && root.shell && root.shell.openPanelIds
        && root.shell.openPanelIds[root.selfId] === true)
      root.open("{}")
  }

  // ------------------------------------------------------------------- UI

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-proxy"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      // Fixed-ish card; only clamps when the screen is genuinely small.
      width: Math.min(Style.space(400), panel.width - Style.gapsOut * 2)
      height: Math.min(contentCol.implicitHeight + card.contentTopInset + card.contentBottomInset,
                       panel.height - Style.gapsOut * 2)
      anchors.centerIn: parent
      radius: root.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin
      clip: true

      // Keep the card itself from being a click-through to the scrim.
      MouseArea { anchors.fill: parent; onClicked: {} }

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        onCloseRequested: root.close()
        onTextKey: function(t) {
          if (t === "q" || t === "Q") root.close()
          else if (t === "r" || t === "R") root.refresh()
        }
        onActivateRequested: root.toggleProxy()

        Column {
          id: contentCol
          width: parent.width
          spacing: root.contentSpacing

          // --------------------------------------------------------- header
          // PanelHero matches the first-party panel hero (network, bluetooth,
          // tailscale): glyph, title, status meta, trailing toggle. The
          // trailingControl/iconComponent inline components may not see this
          // file's `root`, so they reach panel state through `header`.
          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight

            readonly property bool toggleOn: root.displayEnabled
            readonly property bool toggleBusy: root.pending
            readonly property color iconColor: root.displayEnabled ? root.accent : root.dim
            readonly property color accent: root.accent
            readonly property string toggleTip: root.pending ? "Applying\u2026"
              : (root.displayEnabled ? "Disable proxy" : "Enable proxy")
            function requestToggle() { root.setTarget(!root.displayEnabled) }

            PanelHero {
              id: hero
              width: parent.width
              title: "Proxy"
              meta: root.pending ? "Applying\u2026"
                : (root.displayEnabled ? "Enabled" : "Disabled")
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: root.pending ? 0.7 : 1.0

              iconComponent: Component {
                Text {
                  text: "\uF04D3"
                  color: header.iconColor
                  font.family: hero.fontFamily
                  font.pixelSize: Style.font.display
                }
              }

              // Compact on/off switch pinned to the hero's trailing edge.
              trailingControl: Component {
                ToggleSwitch {
                  id: heroSwitch
                  checked: header.toggleOn
                  busy: header.toggleBusy
                  foreground: hero.foreground
                  accent: header.accent
                  onToggled: header.requestToggle()

                  PanelToolTip {
                    visible: heroSwitch.containsMouse
                    text: header.toggleTip
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          // -------------------------------------------------------- endpoint
          PanelSectionHeader {
            text: "ENDPOINT"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Item {
            width: parent.width
            implicitHeight: Math.max(epLabel.implicitHeight, epChip.implicitHeight)

            Text {
              id: epLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Gateway"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            // The address in a pill, eliding the middle so a long
            // phone-hotspot URL keeps its recognizable tail.
            BorderSurface {
              id: epChip
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, parent.width - epLabel.implicitWidth - Style.space(16))
              implicitWidth: epValue.implicitWidth + Style.space(14)
              implicitHeight: epValue.implicitHeight + Style.space(6)
              radius: Style.cornerRadius
              color: "transparent"
              borderSpec: Border.controlSpec("normal", root.foreground, root.accent)

              Text {
                id: epValue
                anchors.centerIn: parent
                width: parent.width - Style.space(14)
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideMiddle
                text: root.status && root.status.httpProxy ? root.status.httpProxy
                  : (root.status ? "Not configured" : "Reading\u2026")
                color: root.status && root.status.httpProxy ? root.foreground : root.dimmer
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          // ----------------------------------------------------- integrations
          PanelSectionHeader {
            text: "INTEGRATIONS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Column {
            width: parent.width
            spacing: Style.spacing.md

            Repeater {
              model: root.integrationList

              delegate: Item {
                required property var modelData
                width: contentCol.width
                implicitHeight: Math.max(integLabel.implicitHeight, integPill.implicitHeight)

                readonly property bool active: root.integrationActive(modelData.key)

                Text {
                  id: integLabel
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: modelData.label
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                // ON/OFF as a small pill: accent-tinted when the integration
                // is active, dim when not.
                BorderSurface {
                  id: integPill
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  implicitWidth: integPillText.implicitWidth + Style.space(14)
                  implicitHeight: integPillText.implicitHeight + Style.space(5)
                  radius: Style.cornerRadius
                  color: parent.active ? Style.selectedFillFor(root.foreground, root.accent) : "transparent"
                  borderSpec: Border.controlSpec(parent.active ? "selected" : "normal", root.foreground, root.accent)

                  Text {
                    id: integPillText
                    anchors.centerIn: parent
                    text: parent.parent.active ? "ON" : "OFF"
                    color: parent.parent.active ? root.accent : root.dimmer
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1.0
                  }
                }
              }
            }
          }

          // ---------------------------------------------------------- footer
          Item {
            width: parent.width
            height: Style.font.caption + Style.spacing.xs

            Text {
              anchors.left: parent.left
              text: root.status === null ? "Reading status\u2026" : "status via abukiya.proxy"
              color: root.dim
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.right: parent.right
              text: "esc close \u00b7 r refresh \u00b7 space toggle"
              color: root.dim
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }
}