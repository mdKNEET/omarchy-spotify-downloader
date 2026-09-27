import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Spotify Downloader: paste a link, queue it, watch it download via spotDL.
// Up to `maxConcurrent` lanes run spotdl in parallel (see the Repeater near
// the bottom); each lane owns one Process and claims the next queued job
// once free. root.jobs is the single source of truth for the popup's list;
// every mutation reassigns the whole array (the established pattern in this
// codebase, e.g. the Dropbox plugin's `files` list) so the Repeater re-renders.
BarWidget {
  id: root
  moduleName: "io.github.mdkneet.spotify-downloader"

  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string downloadDirRaw: root.setting("downloadDir", "~/Music/Spotify")
  readonly property string resolvedDir: Model.expandHome(downloadDirRaw, homeDir)
  readonly property int maxConcurrent: {
    var n = parseInt(root.setting("maxConcurrent", 3), 10)
    if (!isFinite(n)) n = 3
    return Math.max(1, Math.min(6, n))
  }
  readonly property string audioFormat: root.setting("audioFormat", "mp3")
  readonly property string jobScript: String(Qt.resolvedUrl("spotdl-job.sh")).replace(/^file:\/\//, "")

  readonly property var concurrencyOptions: ["1", "2", "3", "4", "5", "6"]
  readonly property var formatOptions: ["mp3", "flac", "opus", "m4a", "wav", "ogg"]

  property var jobs: []
  property int _nextId: 1
  property bool popupOpen: false
  property bool settingsOpen: false

  property bool spotdlChecked: false
  property bool spotdlMissing: false

  readonly property int downloadingCount: {
    var n = 0
    for (var i = 0; i < jobs.length; i++) if (jobs[i].status === "downloading") n++
    return n
  }
  readonly property int queuedCount: {
    var n = 0
    for (var i = 0; i < jobs.length; i++) if (jobs[i].status === "queued") n++
    return n
  }
  // open()/close()/opened let Bar.findPanelWidget route shell.summon/hide/toggle
  // (and therefore a user keybind) to this widget's popup, the same contract
  // the built-in weather/audio/network widgets use.
  readonly property bool opened: popupOpen
  function open() { popupOpen = true }
  function close() { popupOpen = false }

  function checkSpotdl() {
    spotdlChecked = false
    checkProc.running = false
    checkProc.running = true
  }

  function updateJob(id, patch) {
    var idx = -1
    for (var i = 0; i < root.jobs.length; i++) {
      if (root.jobs[i].id === id) { idx = i; break }
    }
    if (idx === -1) return
    var arr = root.jobs.slice()
    var merged = {}
    for (var k in arr[idx]) merged[k] = arr[idx][k]
    for (var k2 in patch) merged[k2] = patch[k2]
    arr[idx] = merged
    root.jobs = arr
  }

  function pruneJobs() {
    var MAX = 10
    if (root.jobs.length <= MAX) return
    var arr = root.jobs.slice()
    var i = 0
    while (arr.length > MAX && i < arr.length) {
      if (arr[i].status === "done" || arr[i].status === "error") arr.splice(i, 1)
      else i++
    }
    root.jobs = arr
  }

  function nextQueuedJob() {
    for (var i = 0; i < root.jobs.length; i++) {
      if (root.jobs[i].status === "queued") return root.jobs[i]
    }
    return null
  }

  function pump() {
    for (var i = 0; i < root.maxConcurrent && i < laneRepeater.count; i++) {
      var lane = laneRepeater.itemAt(i)
      if (!lane || lane.jobId !== -1) continue
      var next = root.nextQueuedJob()
      if (!next) break
      lane.beginJob(next)
    }
  }

  function addUrl(rawUrl) {
    var url = String(rawUrl || "").trim()
    if (url === "") return
    var job = {
      id: root._nextId++,
      url: url,
      title: Model.shortLabel(url),
      status: "queued",
      message: "In wachtrij",
      progress: 0
    }
    root.jobs = root.jobs.concat([job])
    root.pruneJobs()
    root.pump()
  }

  function removeJob(id) {
    root.jobs = root.jobs.filter(function(j) { return j.id !== id })
  }

  function cancelJob(id) {
    root.removeJob(id)
    for (var i = 0; i < laneRepeater.count; i++) {
      var lane = laneRepeater.itemAt(i)
      if (lane && lane.jobId === id) { lane.stop(); break }
    }
  }

  function finishJob(id, success, lastLine) {
    var patch = {
      status: success ? "done" : "error",
      message: success
        ? (/^Opgeslagen op server/.test(lastLine || "") ? lastLine : "Klaar")
        : (lastLine || "Download mislukt")
    }
    if (success) patch.progress = 100
    updateJob(id, patch)
    pruneJobs()
  }

  function saveSetting(key, value) {
    var next = {}
    for (var k in root.settings) next[k] = root.settings[k]
    next[key] = value
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  function openDownloadFolder() {
    Qt.openUrlExternally(Model.fileUri(root.resolvedDir))
  }

  function installSpotdl() {
    if (root.bar) root.bar.run("omarchy-launch-floating-terminal-with-presentation " +
      Model.shq("command -v pipx >/dev/null 2>&1 || sudo pacman -S --noconfirm python-pipx; pipx install spotdl"))
  }

  Component.onCompleted: checkSpotdl()

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: checkProc
    command: ["bash", "-lc", "command -v spotdl"]
    onExited: function(exitCode) {
      root.spotdlChecked = true
      root.spotdlMissing = exitCode !== 0
    }
  }

  // Fixed pool of worker lanes; pump() only ever hands work to the first
  // `maxConcurrent` of them. Keeping all six alive regardless of the current
  // setting means raising/lowering maxConcurrent never tears down a lane
  // that is mid-download.
  Repeater {
    id: laneRepeater
    model: 6

    Item {
      id: lane
      required property int index
      property int jobId: -1
      property bool cancelled: false

      function beginJob(job) {
        lane.jobId = job.id
        lane.cancelled = false
        root.updateJob(job.id, { status: "downloading", message: "Starten…" })
        proc.lastLine = ""
        proc.command = Model.buildCommand({ script: root.jobScript, url: job.url, dir: root.resolvedDir, format: root.audioFormat })
        proc.running = true
      }

      function stop() {
        if (proc.running) {
          lane.cancelled = true
          proc.running = false
        }
      }

      function handleLine(raw) {
        var line = Model.cleanLine(raw)
        if (line === "") return
        proc.lastLine = line
        var stage = Model.parseStageLine(line)
        if (stage) {
          root.updateJob(lane.jobId, { title: stage.title, message: stage.stage, progress: stage.progress })
          return
        }
        if (/^Kopiëren naar server/.test(line)) {
          root.updateJob(lane.jobId, { message: line, progress: 98 })
          return
        }
        var title = Model.extractDownloadedTitle(line)
        if (title !== "") root.updateJob(lane.jobId, { title: title, message: "Klaar", progress: 100 })
        else root.updateJob(lane.jobId, { message: line })
      }

      Process {
        id: proc
        property string lastLine: ""
        stdout: SplitParser { onRead: function(line) { lane.handleLine(line) } }
        stderr: SplitParser { onRead: function(line) { lane.handleLine(line) } }
        onExited: function(exitCode) {
          var wasCancelled = lane.cancelled
          lane.cancelled = false
          if (!wasCancelled) root.finishJob(lane.jobId, exitCode === 0, proc.lastLine)
          lane.jobId = -1
          root.pump()
        }
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰝚"
    active: root.downloadingCount > 0
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: root.downloadingCount > 0
      ? ("Spotify Downloader: " + root.downloadingCount + " bezig, " + root.queuedCount + " in wachtrij")
      : "Spotify Downloader"

    onPressed: function(b) {
      root.settingsOpen = false
      root.popupOpen = !root.popupOpen
    }
  }

  // KeyboardPanel (not PopupCard): PopupCard's xdg-popup window relies on
  // HyprlandFocusGrab for click/dismiss routing only and never actually
  // takes Wayland keyboard focus, so a TextField inside one shows a caret
  // but never receives real key events, so Ctrl+V silently went nowhere.
  // KeyboardPanel is Omarchy's own answer to that (see its header comment;
  // the network panel's wifi-password field relies on the same component
  // for exactly this reason): a PanelWindow that primes
  // WlrKeyboardFocus.Exclusive on open and drives `focusTarget` itself.
  KeyboardPanel {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    focusTarget: urlField
    contentWidth: popup.fittedContentWidth(Style.space(360))
    contentHeight: popup.fittedContentHeight(column.implicitHeight, Style.space(520))

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.spacing.xl

      Item {
        width: parent.width
        height: gearButton.implicitHeight

        Text {
          textFormat: Text.PlainText
          text: "Spotify Downloader"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
        }

        Button {
          id: gearButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: root.settingsOpen ? "" : "󰒓"
          text: root.settingsOpen ? "Terug" : ""
          tooltipText: root.settingsOpen ? "Terug naar downloads" : "Instellingen"
          foreground: root.bar.foreground
          onClicked: root.settingsOpen = !root.settingsOpen
        }
      }

      PanelSeparator { foreground: root.bar.foreground }

      // --- Dependency banner -------------------------------------------------
      Column {
        visible: root.spotdlChecked && root.spotdlMissing
        width: parent.width
        spacing: Style.spacing.md

        Text {
          textFormat: Text.PlainText
          text: "spotdl is niet gevonden op dit systeem."
          color: root.bar.urgent
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.Wrap
          width: parent.width
        }

        Row {
          spacing: Style.spacing.controlGap
          Button {
            text: "Installeren"
            foreground: root.bar.foreground
            bordered: true
            onClicked: root.installSpotdl()
          }
          Button {
            text: "Opnieuw controleren"
            foreground: root.bar.foreground
            bordered: true
            onClicked: root.checkSpotdl()
          }
        }
      }

      // --- Main view -----------------------------------------------------------
      Column {
        visible: !root.settingsOpen && !(root.spotdlChecked && root.spotdlMissing)
        width: parent.width
        spacing: Style.spacing.lg

        Row {
          width: parent.width
          spacing: Style.spacing.controlGap

          TextField {
            id: urlField
            width: parent.width - downloadButton.implicitWidth - Style.spacing.controlGap
            placeholderText: "Plak een Spotify-link…"
            onAccepted: {
              root.addUrl(urlField.text)
              urlField.text = ""
            }
          }

          Button {
            id: downloadButton
            text: "Downloaden"
            foreground: root.bar.foreground
            bordered: true
            onClicked: {
              root.addUrl(urlField.text)
              urlField.text = ""
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground; visible: root.jobs.length > 0 }

        PanelSectionHeader {
          visible: root.jobs.length > 0
          text: "DOWNLOADS"
          foreground: root.bar.foreground
        }

        Text {
          textFormat: Text.PlainText
          visible: root.jobs.length === 0
          text: "Nog geen downloads."
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Column {
          width: parent.width
          spacing: Style.spacing.sm

          Repeater {
            model: root.jobs

            Row {
              id: jobRow
              required property var modelData
              width: parent.width
              spacing: Style.spacing.controlGap

              Text {
                textFormat: Text.PlainText
                width: Style.space(16)
                text: jobRow.modelData.status === "done" ? "✓"
                  : jobRow.modelData.status === "error" ? "✕"
                  : jobRow.modelData.status === "downloading" ? "↓"
                  : "•"
                color: jobRow.modelData.status === "done" ? root.bar.foreground
                  : jobRow.modelData.status === "error" ? root.bar.urgent
                  : jobRow.modelData.status === "downloading" ? Color.accent
                  : Qt.darker(root.bar.foreground, 1.6)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                width: parent.width - Style.space(16) - removeButton.implicitWidth - Style.spacing.controlGap * 2
                spacing: Style.spacing.xxs
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  textFormat: Text.PlainText
                  text: jobRow.modelData.title
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  textFormat: Text.PlainText
                  text: jobRow.modelData.message
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: parent.width
                }

                Rectangle {
                  visible: jobRow.modelData.status !== "queued"
                  width: parent.width
                  height: Style.space(4)
                  radius: height / 2
                  color: Qt.darker(root.bar.foreground, 2.2)

                  Rectangle {
                    height: parent.height
                    radius: parent.radius
                    color: jobRow.modelData.status === "error" ? root.bar.urgent : Color.accent
                    width: parent.width * (Math.max(0, Math.min(100, jobRow.modelData.progress || 0)) / 100)

                    Behavior on width {
                      NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
                    }
                  }
                }
              }

              Button {
                id: removeButton
                iconText: "✕"
                tooltipText: jobRow.modelData.status === "downloading" || jobRow.modelData.status === "queued"
                  ? "Annuleren" : "Verwijderen"
                foreground: Qt.darker(root.bar.foreground, 1.3)
                onClicked: root.cancelJob(jobRow.modelData.id)
              }
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        Row {
          width: parent.width
          spacing: Style.spacing.controlGap

          Text {
            textFormat: Text.PlainText
            width: parent.width - openFolderButton.implicitWidth - Style.spacing.controlGap
            text: root.downloadingCount + " bezig · " + root.queuedCount + " in wachtrij"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }

          Button {
            id: openFolderButton
            text: "Open map"
            foreground: root.bar.foreground
            bordered: true
            onClicked: root.openDownloadFolder()
          }
        }
      }

      // --- Settings view ---------------------------------------------------
      Column {
        visible: root.settingsOpen
        width: parent.width
        spacing: Style.spacing.lg

        PanelSectionHeader { text: "INSTELLINGEN"; foreground: root.bar.foreground }

        Column {
          width: parent.width
          spacing: Style.spacing.xs

          Text {
            textFormat: Text.PlainText
            text: "Downloadmap"
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            width: parent.width
            spacing: Style.spacing.controlGap

            TextField {
              id: dirField
              width: parent.width - browseButton.implicitWidth - Style.spacing.controlGap
              text: root.downloadDirRaw
              onAccepted: root.saveSetting("downloadDir", dirField.text)
              onEditingFinished: root.saveSetting("downloadDir", dirField.text)
            }

            Button {
              id: browseButton
              text: "Bladeren…"
              foreground: root.bar.foreground
              bordered: true
              onClicked: {
                folderPickProc.command = ["bash", "-lc",
                  "zenity --file-selection --directory --title=" + Model.shq("Kies downloadmap") +
                  " --filename=" + Model.shq(root.resolvedDir + "/")]
                folderPickProc.running = true
              }
            }
          }
        }

        Dropdown {
          width: parent.width
          label: "Max. gelijktijdige downloads"
          value: String(root.maxConcurrent)
          options: root.concurrencyOptions
          onChanged: function(v) { root.saveSetting("maxConcurrent", parseInt(v, 10)) }
        }

        Dropdown {
          width: parent.width
          label: "Audioformaat"
          value: root.audioFormat
          options: root.formatOptions
          onChanged: function(v) { root.saveSetting("audioFormat", v) }
        }

        Row {
          spacing: Style.spacing.controlGap
          Button {
            text: "Open map"
            foreground: root.bar.foreground
            bordered: true
            onClicked: root.openDownloadFolder()
          }
          Button {
            text: "Terug"
            foreground: root.bar.foreground
            bordered: true
            onClicked: root.settingsOpen = false
          }
        }
      }
    }
  }

  Process {
    id: folderPickProc
    stdout: StdioCollector {
      id: folderPickStdout
      waitForEnd: true
      onStreamFinished: {
        var chosen = String(text || "").trim()
        if (chosen !== "") {
          dirField.text = chosen
          root.saveSetting("downloadDir", chosen)
        }
      }
    }
  }
}
