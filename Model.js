// Pure helpers for the Spotify Downloader widget: shell quoting, command
// building, and output-line cleanup. Kept free of QML types so they stay
// trivially testable and reusable from the lane delegate and the root item.

function shq(value) {
  return "'" + String(value === undefined || value === null ? "" : value).replace(/'/g, "'\\''") + "'"
}

// Expands a leading "~" against the given home directory. Does not touch
// "~user" forms (rare in this UI and ambiguous without a passwd lookup).
function expandHome(path, home) {
  var p = String(path || "").trim()
  if (p === "") return home || ""
  if (p.charAt(0) === "~" && (p.length === 1 || p.charAt(1) === "/")) {
    return (home || "") + p.slice(1)
  }
  return p
}

// Builds the argv for one spotdl download run. Runs inside the resolved
// download directory so the --output template can stay relative, keeping
// the directory's own quoting isolated from the filename template's braces.
function buildCommand(opts) {
  var dir = String(opts.dir || "")
  var url = String(opts.url || "")
  var format = String(opts.format || "mp3")
  var outputTemplate = "{artists} - {title}.{output-ext}"

  var cmd = "mkdir -p " + shq(dir) +
    " && cd " + shq(dir) +
    " && spotdl download " + shq(url) +
    " --format " + shq(format) +
    " --output " + shq(outputTemplate) +
    " --overwrite skip" +
    " --simple-tui"

  return ["bash", "-lc", cmd]
}

// spotdl's own internal progress checkpoints per stage (spotdl/download/
// progress_handler.py), replicated here since --simple-tui prints the stage
// name but never the underlying percentage.
var STAGE_PROGRESS = {
  "Searching for song": 25,
  "Getting audio meta": 40,
  "Downloading": 55,
  "Converting": 80,
  "Embedding metadata": 95,
  "Done": 100,
  "Skipped": 100,
  "Error": 100
}

// Parses a --simple-tui line of the form "<title>: <stage>". Splitting on
// the last ": " keeps this correct even if a song title itself contains
// ": ", since none of the known stage names do.
function parseStageLine(line) {
  var text = String(line || "")
  var idx = text.lastIndexOf(": ")
  if (idx < 0) return null
  var stage = text.slice(idx + 2).trim()
  if (!Object.prototype.hasOwnProperty.call(STAGE_PROGRESS, stage)) return null
  var title = text.slice(0, idx).trim()
  if (title === "") return null
  return { title: title, stage: stage, progress: STAGE_PROGRESS[stage] }
}

// Strips carriage-return progress-bar redraws and ANSI escape sequences from
// one line of spotdl/yt-dlp output, keeping only the last meaningful segment.
function cleanLine(raw) {
  var text = String(raw || "")
  // eslint-disable-next-line no-control-regex
  text = text.replace(/\x1b\[[0-9;]*[a-zA-Z]/g, "")
  var parts = text.split("\r")
  text = parts[parts.length - 1]
  return text.replace(/\s+/g, " ").trim()
}

// Pulls a friendlier title out of spotdl's "Downloaded "X":" success line.
function extractDownloadedTitle(line) {
  var m = String(line || "").match(/^Downloaded "(.+)":\s*$/)
  return m ? m[1] : ""
}

// Short, stable label for a freshly queued job before spotdl reports a title.
function shortLabel(url) {
  var s = String(url || "").trim()
  var m = s.match(/open\.spotify\.com\/(?:intl-[a-z]{2}\/)?(track|album|playlist|artist)\/([A-Za-z0-9]+)/)
  if (m) {
    var kind = m[1].charAt(0).toUpperCase() + m[1].slice(1)
    return kind + " " + m[2].slice(0, 8)
  }
  return s.length > 60 ? s.slice(0, 57) + "…" : s
}

// file:// URI for Qt.openUrlExternally, percent-encoding each path segment.
function fileUri(path) {
  var parts = String(path || "").split("/")
  for (var i = 0; i < parts.length; i++) parts[i] = encodeURIComponent(parts[i])
  return "file://" + parts.join("/")
}
