import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// FortiClient VPN in the bar. All VPN work goes through the `forticlient-vpn`
// script next to this file, which drives FortiClient's own CLI; passwords are
// written to that script's stdin and never kept here longer than the call.
Panel {
  id: root
  moduleName: "io.github.fivefold3.forticlient"
  ipcTarget: "forticlient"
  manageIpc: false

  readonly property string backend: decodeURIComponent(Qt.resolvedUrl("forticlient-vpn").toString().replace(/^file:\/\//, ""))
  readonly property int refreshIntervalSec: Math.max(3, parseInt(setting("refreshIntervalSec", 10), 10) || 10)

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string glyph: "󰦝"

  // --- FortiClient state, from `forticlient-vpn status` ---
  property bool loaded: false
  property bool installed: true
  property string service: ""
  property string vpnState: "disconnected"
  property var conn: ({})
  property var profiles: []

  readonly property bool serviceUp: installed && service === "active"
  readonly property bool connected: serviceUp && vpnState === "connected"
  readonly property bool transitional: serviceUp && ["connecting", "reconnecting", "authenticating"].indexOf(vpnState) !== -1
  readonly property bool busy: actionProc.running || connectProc.running

  // --- Action state ---
  property string message: ""
  property bool messageIsError: false
  property string connectingName: ""
  property var prompt: null          // { secret, text, context } while the CLI waits on us
  readonly property bool promptYesNo: prompt !== null && !prompt.secret && /\(y\/n\)/.test(prompt.text)
  property bool verifyConnect: false // connect exited quietly; the next settled status says how it went
  property string afterAction: ""    // what to run once actionProc finishes
  property bool cancelled: false
  property double failedAt: 0       // the service says "connecting" for a moment after a failure

  // --- Panel state ---
  property int cursor: 0             // row index; profiles.length is "New profile"
  property bool cursorActive: false
  property string expanded: ""       // profile whose connect form is open
  property string editing: ""        // "" closed, "\n" new, else the profile being edited
  property string confirmRemove: ""
  property bool typing: false        // a text field owns the keyboard

  // Connect form, shared by whichever profile is expanded.
  property string formUser: ""
  property string formPassword: ""
  property bool formSave: false
  property bool formAuto: false
  property bool formAlways: false

  // Profile editor.
  property string editName: ""
  property string editHost: ""
  property string editPort: "443"
  property string editAuth: "save"
  property string editUser: ""

  readonly property string barTooltip: !installed ? "FortiClient VPN isn't installed"
    : !serviceUp ? "FortiClient service is off"
    : connected ? "VPN connected · " + (conn.name || "") + (conn.ip ? " · " + conn.ip : "")
    : transitional ? "VPN connecting…" : "VPN disconnected"

  readonly property string heroMeta: !loaded ? "Checking…"
    : !installed ? "Not installed"
    : !serviceUp ? "Service off"
    : connected ? "Connected · " + (conn.name || "")
    : transitional ? (vpnState === "reconnecting" ? "Reconnecting…" : "Connecting…")
    : "Disconnected"

  function profile(name) {
    for (var i = 0; i < profiles.length; i++) if (profiles[i].name === name) return profiles[i]
    return null
  }

  function say(text, isError) {
    message = text || ""
    messageIsError = !!isError
  }

  function formatBytes(n) {
    var v = Number(n) || 0
    var units = ["B", "KB", "MB", "GB", "TB"]
    var i = 0
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i++ }
    return (i === 0 ? v : v.toFixed(1)) + " " + units[i]
  }

  // --- Backend calls ---

  function refresh() {
    if (!statusProc.running && !busy) statusProc.running = true
  }

  function loadProfiles() {
    if (!profilesProc.running && serviceUp) profilesProc.running = true
  }

  function run(args, then) {
    if (busy) return
    afterAction = then || ""
    say("", false)
    actionProc.command = [backend].concat(args)
    actionProc.running = true
  }

  function connectProfile(name) {
    var p = profile(name)
    if (!p || busy) return
    var args = ["connect", name]
    var user = p.auth === "save" ? p.username : formUser.trim()
    if (p.auth !== "none") {
      if (user === "") { say("Enter your username.", true); return }
      args.push("-u", user)
      if (formPassword !== "") args.push("-p")
      else if (!p.savePassword) { say("Enter your password.", true); return }
    }
    if (formSave) args.push("-s")
    if (formAuto) args.push("-a")
    if (formAlways) args.push("-w")
    connectProc.secret = formPassword
    formPassword = ""
    cancelled = false
    verifyConnect = false
    connectingName = name
    prompt = null
    vpnState = "connecting"
    say("", false)
    connectProc.command = [backend].concat(args)
    connectProc.running = true
    focusList()
  }

  // Open first, so the panel's own focus handling runs before the answer
  // field claims the keyboard; the timer covers the panel mapping late.
  function showPrompt(secret, text, context) {
    if (!opened) open()
    prompt = { secret: secret, text: text, context: context }
    promptFocus.restart()
  }

  function answerPrompt(text) {
    if (!prompt || !connectProc.running) return
    connectProc.write(text + "\n")
    prompt = null
    focusList()
  }

  function cancelConnect() {
    if (!connectProc.running) return
    cancelled = true
    prompt = null
    connectProc.running = false
  }

  function disconnect() {
    if (connectProc.running) cancelConnect()
    else run(["disconnect"], "refresh")
  }

  function startService() {
    // Polkit shows its password prompt over everything; get out of its way.
    close()
    run(["start-service"], "refresh")
  }

  function runSetup() {
    close()
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", Util.shellQuote(backend) + " setup"])
  }

  // --- Panel actions ---

  function expand(name) {
    var p = profile(name)
    // Take focus back before the old form hides: Qt leaves it on hidden fields.
    keyCatcher.forceActiveFocus()
    editing = ""
    confirmRemove = ""
    if (!p || expanded === name) { expanded = ""; return }
    expanded = name
    formUser = ""
    formPassword = ""
    formSave = p.savePassword
    formAuto = p.autoConnect
    formAlways = p.alwaysUp
    say("", false)
  }

  function openEditor(name) {
    var p = name ? profile(name) : null
    keyCatcher.forceActiveFocus()
    expanded = ""
    confirmRemove = ""
    editing = p ? p.name : "\n"
    editName = p ? p.name : ""
    editHost = p ? p.host : ""
    editPort = p ? String(p.port) : "443"
    editAuth = p ? p.auth : "save"
    editUser = p ? p.username : ""
    say("", false)
  }

  function closeEditor() {
    editing = ""
    focusList()
  }

  function saveEditor() {
    var name = editing === "\n" ? editName.trim() : editing
    if (name === "") { say("Give the profile a name.", true); return }
    if (editing === "\n" && profile(name)) { say("A profile named " + name + " already exists.", true); return }
    var args = ["save", name, editHost.trim(), editPort.trim(), editAuth]
    if (editAuth === "save") args.push(editUser.trim())
    run(args, "saved")
  }

  function removeProfile(name) {
    if (confirmRemove !== name) { confirmRemove = name; confirmTimer.restart(); return }
    confirmRemove = ""
    if (expanded === name) expanded = ""
    run(["remove", name], "profiles")
  }

  // Deferred as a whole: a field's Enter still travels on to the key catcher
  // after onAccepted, and must find it blocked or it activates the row again.
  function focusList() {
    Qt.callLater(function() {
      typing = false
      keyCatcher.forceActiveFocus()
    })
  }

  function moveCursor(dy) {
    cursorActive = true
    cursor = Math.max(0, Math.min(profiles.length, cursor + dy))
  }

  function activateCursor() {
    if (promptYesNo) return
    if (cursor >= profiles.length) { openEditor(""); return }
    var p = profiles[cursor]
    if (expanded === p.name) {
      if (connected && conn.name === p.name) disconnect()
      else connectProfile(p.name)
    } else {
      expand(p.name)
    }
  }

  // --- Lifecycle ---

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      refresh()
      loadProfiles()
      focusList()
    } else {
      // Forget anything typed once the panel closes.
      formPassword = ""
      promptField.text = ""
      expanded = ""
      editing = ""
      confirmRemove = ""
      if (!busy) say("", false)
    }
  }
  onServiceUpChanged: if (serviceUp) loadProfiles()

  // Detached, since installing a plugin reloads it several times in a row and
  // each reload would kill a child process.
  Component.onCompleted: Quickshell.execDetached([backend, "offer-setup"])

  Timer {
    interval: (root.opened || root.transitional) ? 2000 : root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: promptFocus
    interval: 200
    onTriggered: if (promptField.visible) promptField.forceActiveFocus()
  }

  Timer {
    id: confirmTimer
    interval: 3000
    onTriggered: root.confirmRemove = ""
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function status(): string { return root.heroMeta }
    function disconnect(): void { root.disconnect() }
    // Connects straight away when the profile needs nothing typed (saved
    // password, or no username); otherwise opens the panel on its form.
    function connect(name: string): void {
      var p = root.profile(name)
      // expand() closes a form that's already open, so only call it when needed.
      if (p && (p.auth === "none" || (p.auth === "save" && p.savePassword))) {
        if (root.expanded !== name) root.expand(name)
        root.connectProfile(name)
      } else {
        root.open()
        if (p && root.expanded !== name) root.expand(name)
      }
    }
  }

  // --- Processes ---

  Process {
    id: statusProc
    command: [root.backend, "status"]
    stdout: StdioCollector {
      onStreamFinished: {
        var v = {}
        var lines = text.split("\n")
        for (var i = 0; i < lines.length; i++) {
          var tab = lines[i].indexOf("\t")
          if (tab > 0) v[lines[i].slice(0, tab)] = lines[i].slice(tab + 1)
        }
        if (v.busy === "1" || v.installed === undefined) return
        root.installed = v.installed === "1"
        root.service = v.service || ""
        var state = v.state || "disconnected"
        if (state === "connecting" && Date.now() - root.failedAt < 5000) state = "disconnected"
        if (!connectProc.running) root.vpnState = state
        root.conn = { name: v.name || "", user: v.user || "", ip: v.ip || "",
                      sent: v.sent || "0", recv: v.recv || "0", duration: v.duration || "" }
        root.loaded = true
        if (root.verifyConnect && !connectProc.running
            && ["connecting", "reconnecting", "authenticating"].indexOf(state) === -1) {
          root.verifyConnect = false
          if (state !== "connected" && !root.messageIsError) root.say("FortiClient didn't connect.", true)
        }
      }
    }
  }

  Process {
    id: profilesProc
    command: [root.backend, "profiles"]
    stdout: StdioCollector {
      onStreamFinished: {
        var list = []
        var lines = text.split("\n")
        for (var i = 0; i < lines.length; i++) {
          var f = lines[i].split("\t")
          if (f.length < 9 || f[0] === "") continue
          list.push({ name: f[0], kind: f[1], host: f[2], port: parseInt(f[3], 10) || 443,
                      auth: f[4], username: f[5], savePassword: f[6] === "Enabled",
                      autoConnect: f[7] === "Enabled", alwaysUp: f[8] === "Enabled" })
        }
        root.profiles = list
        if (root.expanded !== "" && !root.profile(root.expanded)) root.expanded = ""
        root.cursor = Math.min(root.cursor, list.length)
      }
    }
  }

  Process {
    id: actionProc
    stderr: StdioCollector { id: actionErr }
    onExited: function(exitCode) {
      var then = root.afterAction
      root.afterAction = ""
      if (exitCode !== 0) {
        root.say(actionErr.text.trim() || "That didn't work.", true)
      } else if (then === "saved") {
        root.editing = ""
        root.focusList()
      }
      if (then === "saved" || then === "profiles") root.loadProfiles()
      root.refresh()
    }
  }

  Process {
    id: connectProc
    property string secret: ""
    stdinEnabled: true
    onStarted: {
      if (secret !== "") write(secret + "\n")
      secret = ""
    }
    // Also forgotten if the process never started.
    onRunningChanged: if (!running) secret = ""
    stdout: SplitParser {
      onRead: function(line) {
        var f = line.split("\t")
        if (f[0] === "status") {
          var s = f[1].toLowerCase()
          if (s.indexOf("connected") === 0) root.vpnState = "connected"
          else if (s.indexOf("disconnected") === 0) root.vpnState = "disconnected"
          else if (s.indexOf("connecting") === 0) root.vpnState = "connecting"
        } else if (f[0] === "prompt") {
          root.showPrompt(f[1] === "1", f[2] || "", f[3] || "")
        } else if (f[0] === "error") {
          root.say(f[1], true)
        } else if (f[0] === "info") {
          root.say(f[1], false)
        }
      }
    }
    onExited: function(exitCode) {
      root.prompt = null
      root.connectingName = ""
      if (root.cancelled) {
        root.cancelled = false
        root.failedAt = Date.now()
        root.say("Cancelled.", false)
        root.run(["disconnect"], "refresh")
      } else {
        if (exitCode !== 0 && !root.messageIsError) root.say("FortiClient couldn't connect.", true)
        if (root.messageIsError) {
          root.failedAt = Date.now()
          root.vpnState = "disconnected"
        } else {
          // The CLI exits 0 even when it fails, sometimes without saying why.
          root.verifyConnect = true
        }
        if (!root.messageIsError) root.expanded = ""
        root.loadProfiles()
      }
      root.refresh()
    }
  }

  // --- Bar icon ---

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    tooltipText: root.barTooltip
    foreground: root.connected ? root.barForeground : Qt.darker(root.barForeground, 1.55)
    opacity: root.transitional ? pulse.value : 1.0
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh()
      else root.toggle()
    }
  }

  QtObject {
    id: pulse
    property real value: 1.0
    SequentialAnimation on value {
      running: root.transitional
      loops: Animation.Infinite
      NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutQuad }
      NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
    }
  }

  // --- Panel ---

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.typing
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: { root.cursorActive = true; root.activateCursor() }
      onCloseRequested: {
        if (root.prompt) root.cancelConnect()
        else if (root.editing !== "") root.closeEditor()
        else if (root.expanded !== "") root.expand(root.expanded)
        else root.close()
      }
      onDeleteRequested: {
        var p = root.profiles[root.cursor]
        if (!p || p.kind !== "personal" || root.busy) return
        var live = (root.connected || root.transitional) && (root.conn.name === p.name || root.connectingName === p.name)
        if (!live) root.removeProfile(p.name)
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "y" && root.promptYesNo) root.answerPrompt("y")
        else if (t === "n" && root.promptYesNo) root.answerPrompt("n")
        else if (t === "n") root.openEditor("")
        else if (t === "e" && root.profiles[root.cursor] && root.profiles[root.cursor].kind === "personal") root.openEditor(root.profiles[root.cursor].name)
        else if (t === "d" && (root.connected || root.transitional)) root.disconnect()
        else if (t === "r") { root.refresh(); root.loadProfiles() }
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "FortiClient VPN"
            meta: root.heroMeta
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.connected ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.glyph
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              Button {
                visible: root.connected || root.transitional
                text: connectProc.running && !root.connected ? "Cancel" : "Disconnect"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.disconnect()
              }
            }
          }

          // Not installed / service off: one clear way forward.
          Notice {
            visible: root.loaded && !root.installed
            title: "FortiClient VPN isn't installed"
            detail: "Setup can install forticlient-vpn from the AUR."
            action: "Run setup"
            onTriggered: root.runSetup()
          }

          Notice {
            visible: root.loaded && root.installed && !root.serviceUp
            title: "The FortiClient service is off"
            detail: "It does the VPN work. Starting it asks for your password."
            action: "Start"
            onTriggered: root.startService()
          }

          // Live connection details.
          Column {
            visible: root.connected
            width: parent.width
            spacing: Style.spacing.labelGap
            InfoPair { label: "Address"; value: root.conn.ip || "—" }
            InfoPair { label: "User"; value: root.conn.user || "—" }
            InfoPair { label: "Connected for"; value: root.conn.duration || "—" }
            InfoPair { label: "Traffic"; value: "↑ " + root.formatBytes(root.conn.sent) + "   ↓ " + root.formatBytes(root.conn.recv) }
          }

          // A question from FortiClient mid-connect: token, certificate, etc.
          Column {
            id: promptBox
            visible: root.prompt !== null
            width: parent.width
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: text !== ""
              text: root.prompt ? root.prompt.context : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.prompt ? root.prompt.text.replace(/\s*\[default=.*\]\s*:?$/, "").replace(/:$/, "") : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              wrapMode: Text.Wrap
            }

            RowLayout {
              visible: !root.promptYesNo
              width: parent.width
              spacing: Style.space(6)
              Field {
                id: promptField
                Layout.fillWidth: true
                password: root.prompt ? root.prompt.secret : false
                placeholderText: "Answer"
                onAccepted: { var t = text; text = ""; root.answerPrompt(t) }
                Keys.onEscapePressed: { text = ""; root.cancelConnect() }
              }
              Button {
                text: "Send"
                bordered: true
                foreground: root.foreground
                onClicked: { var t = promptField.text; promptField.text = ""; root.answerPrompt(t) }
              }
            }

            Row {
              visible: root.promptYesNo
              spacing: Style.space(6)
              Button { text: "Yes (y)"; bordered: true; foreground: root.foreground; onClicked: root.answerPrompt("y") }
              Button { text: "No (n)"; bordered: true; foreground: root.foreground; onClicked: root.answerPrompt("n") }
            }
          }

          // The editor shows its own messages, next to the form.
          Message { visible: root.message !== "" && root.editing === ""; width: parent.width }

          PanelSeparator {
            visible: root.serviceUp
            foreground: root.foreground
          }

          Column {
            visible: root.serviceUp
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "PROFILES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.profiles
              ProfileRow {
                required property var modelData
                required property int index
                width: parent.width
                p: modelData
                rowIndex: index
              }
            }

            CursorSurface {
              id: newRow
              visible: root.editing !== "\n"
              width: parent.width
              implicitHeight: newText.implicitHeight + Style.spacing.rowPaddingX
              foreground: root.foreground
              hasCursor: root.cursorActive && root.cursor === root.profiles.length
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: { root.cursorActive = true; root.cursor = root.profiles.length }
                onClicked: root.openEditor("")
              }
              Text {
                id: newText
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                x: Style.space(10)
                text: "+  New profile"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            Editor { visible: root.editing === "\n"; width: parent.width }
          }
        }
      }
    }
  }

  // --- Components ---

  component Field: TextField {
    foreground: root.foreground
    font.family: root.fontFamily
    verticalPadding: Style.spacing.controlPaddingY
    onActiveFocusChanged: root.typing = activeFocus
  }

  component Option: Item {
    id: option
    property string label: ""
    property bool checked: false
    signal toggled()
    implicitWidth: optionRow.implicitWidth
    implicitHeight: optionRow.implicitHeight
    Row {
      id: optionRow
      spacing: Style.space(6)
      ToggleSwitch {
        anchors.verticalCenter: parent.verticalCenter
        trackHeight: Style.space(14)
        cursorRing: false
        checked: option.checked
        foreground: root.foreground
        onToggled: option.toggled()
      }
      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: option.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: option.toggled() }
      }
    }
  }

  component Notice: RowLayout {
    id: notice
    property string title: ""
    property string detail: ""
    property string action: ""
    signal triggered()
    width: parent.width
    spacing: Style.space(8)
    Column {
      Layout.fillWidth: true
      spacing: Style.space(2)
      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: notice.title
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        wrapMode: Text.Wrap
      }
      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: notice.detail
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }
    }
    Button {
      text: notice.action
      bordered: true
      enabled: !root.busy
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: notice.triggered()
    }
  }

  component ProfileRow: Column {
    id: row
    property var p: ({})
    property int rowIndex: 0
    readonly property bool isOpen: root.expanded === p.name
    readonly property bool isLive: (root.connected || root.transitional) && (root.conn.name === p.name || root.connectingName === p.name)
    readonly property bool editable: p.kind === "personal"
    spacing: Style.space(6)

    CursorSurface {
      visible: root.editing !== row.p.name
      width: parent.width
      implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX
      foreground: root.foreground
      hasCursor: root.cursorActive && root.cursor === row.rowIndex
      current: row.isOpen

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: { root.cursorActive = true; root.cursor = row.rowIndex }
        onClicked: root.expand(row.p.name)
      }

      RowLayout {
        id: rowContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(4)
        spacing: Style.space(6)

        Column {
          Layout.fillWidth: true
          spacing: Style.space(1)
          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: row.p.name
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: row.isLive
            elide: Text.ElideRight
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.confirmRemove === row.p.name ? "Press again to remove this profile"
              : row.isLive ? (root.connected ? "Connected" : "Connecting…")
              : row.p.host + (row.p.port !== 443 ? ":" + row.p.port : "")
                + (row.p.auth === "save" && row.p.username ? " · " + row.p.username : "")
                + (row.p.kind === "corporate" ? " · managed" : "")
            color: root.confirmRemove === row.p.name ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        PanelActionButton {
          visible: row.editable
          iconText: "󰏫"
          tooltipText: "Edit (e)"
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: !root.busy
          onClicked: root.openEditor(row.p.name)
        }
        PanelActionButton {
          visible: row.editable
          iconText: "󰆴"
          tooltipText: "Remove (x)"
          foreground: root.foreground
          hoverColor: root.urgent
          fontFamily: root.fontFamily
          enabled: !root.busy && !row.isLive
          onClicked: root.removeProfile(row.p.name)
        }
      }
    }

    // Connect form, below the open row.
    Column {
      visible: row.isOpen && root.editing === ""
      width: parent.width
      leftPadding: Style.space(10)
      rightPadding: Style.space(10)
      spacing: Style.space(6)
      readonly property real innerWidth: width - leftPadding - rightPadding

      Field {
        id: userField
        visible: !row.isLive && row.p.auth === "prompt"
        width: parent.innerWidth
        placeholderText: "Username"
        text: root.formUser
        onTextChanged: root.formUser = text
        onAccepted: passField.forceActiveFocus()
        Keys.onEscapePressed: root.expand(row.p.name)
        onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
      }

      Field {
        id: passField
        visible: !row.isLive && row.p.auth !== "none"
        width: parent.innerWidth
        password: true
        placeholderText: row.p.savePassword ? "Saved password (type to replace)" : "Password"
        text: root.formPassword
        onTextChanged: root.formPassword = text
        onAccepted: root.connectProfile(row.p.name)
        Keys.onEscapePressed: root.expand(row.p.name)
        onVisibleChanged: if (visible && row.p.auth === "save") Qt.callLater(forceActiveFocus)
      }

      Flow {
        visible: !row.isLive
        width: parent.innerWidth
        spacing: Style.space(12)
        Option { label: "Save password"; checked: root.formSave; onToggled: root.formSave = !root.formSave }
        Option { label: "Always up"; checked: root.formAlways; onToggled: root.formAlways = !root.formAlways }
        Option { label: "Auto-connect"; checked: root.formAuto; onToggled: root.formAuto = !root.formAuto }
      }

      Button {
        text: row.isLive ? (root.connected ? "Disconnect" : "Cancel") : "Connect"
        bordered: true
        enabled: row.isLive || !root.busy
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: row.isLive ? root.disconnect() : root.connectProfile(row.p.name)
      }
    }

    Editor { visible: root.editing === row.p.name; width: parent.width }
  }

  component Editor: Column {
    id: editor
    spacing: Style.space(6)
    readonly property bool isNew: root.editing === "\n"
    onVisibleChanged: if (visible) Qt.callLater(function() { (editor.isNew ? nameField : hostField).forceActiveFocus() })

    PanelSectionHeader {
      text: editor.isNew ? "NEW PROFILE" : "EDIT " + root.editing.toUpperCase()
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Field {
      id: nameField
      visible: editor.isNew
      width: parent.width
      placeholderText: "Connection name"
      text: root.editName
      onTextChanged: root.editName = text
      Keys.onEscapePressed: root.closeEditor()
      onAccepted: hostField.forceActiveFocus()
    }

    RowLayout {
      width: parent.width
      spacing: Style.space(6)
      Field {
        id: hostField
        Layout.fillWidth: true
        placeholderText: "Remote gateway"
        text: root.editHost
        onTextChanged: root.editHost = text
        Keys.onEscapePressed: root.closeEditor()
        onAccepted: root.saveEditor()
      }
      Field {
        Layout.preferredWidth: Style.space(64)
        placeholderText: "Port"
        text: root.editPort
        validator: IntValidator { bottom: 1; top: 65535 }
        onTextChanged: root.editPort = text
        Keys.onEscapePressed: root.closeEditor()
        onAccepted: root.saveEditor()
      }
    }

    ButtonGroup {
      focusable: true
      options: [
        { value: "save", label: "Save username" },
        { value: "prompt", label: "Ask each time" },
        { value: "none", label: "None" }
      ]
      value: root.editAuth
      foreground: root.foreground
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      onChanged: function(v) { root.editAuth = v }
    }

    Field {
      visible: root.editAuth === "save"
      width: parent.width
      placeholderText: "Username"
      text: root.editUser
      onTextChanged: root.editUser = text
      Keys.onEscapePressed: root.closeEditor()
      onAccepted: root.saveEditor()
    }

    Message { visible: root.message !== ""; width: parent.width }

    Row {
      spacing: Style.space(6)
      Button {
        text: "Save"
        bordered: true
        enabled: !root.busy
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.saveEditor()
      }
      Button {
        text: "Cancel"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.closeEditor()
      }
    }
  }

  component Message: Text {
    textFormat: Text.PlainText
    text: root.message
    color: root.messageIsError ? root.urgent : root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
  }

  component InfoPair: RowLayout {
    property string label: ""
    property string value: ""
    width: parent.width
    spacing: Style.space(8)
    Text {
      textFormat: Text.PlainText
      text: parent.label
      color: root.foreground
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      horizontalAlignment: Text.AlignRight
      text: parent.value
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }
}
