// Pure helpers for the Spotify & YouTube Downloader widget: shell quoting, command
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

// Maps a gvfs FUSE path such as
// /run/user/1000/gvfs/smb-share:server=10.0.0.118,share=plex/Muziek to the
// matching smb:// URI. smb:// URIs pass through unchanged and every other
// path is returned as "" (a plain local folder). The FUSE path is never
// written to directly: without gvfsd-fuse it is just tmpfs, so files saved
// there look fine locally but never reach the server.
function smbUri(path) {
  var p = String(path || "").trim()
  if (/^smb:\/\//i.test(p)) return p.replace(/\/+$/, "")
  var m = p.match(/^\/run\/user\/\d+\/gvfs\/smb-share:([^/]+)(\/.*)?$/)
  if (!m) return ""
  var server = "", share = "", user = ""
  var parts = m[1].split(",")
  for (var i = 0; i < parts.length; i++) {
    var kv = parts[i].split("=")
    if (kv[0] === "server") server = decodeURIComponent(kv[1] || "")
    else if (kv[0] === "share") share = decodeURIComponent(kv[1] || "")
    else if (kv[0] === "user") user = decodeURIComponent(kv[1] || "")
  }
  if (server === "" || share === "") return ""
  var rest = (m[2] || "").replace(/\/+$/, "")
  return "smb://" + (user !== "" ? user + "@" : "") + server + "/" + share + rest
}

// True for youtube.com (www, m, music, ...), youtube-nocookie.com and youtu.be
// links, with or without a scheme. Search queries are not links, so they keep
// going to spotdl.
function isYoutube(url) {
  return /^(https?:\/\/)?([a-z0-9-]+\.)*(youtube\.com|youtube-nocookie\.com|youtu\.be)(\/|$)/i.test(String(url || "").trim())
}

// Builds the argv for one download run. download-job.sh owns the actual work
// (tool choice flags, local folder vs. SMB share); this only resolves the
// destination and the source.
function buildCommand(opts) {
  var dir = String(opts.dir || "")
  var dest = smbUri(dir) || dir
  var url = String(opts.url || "")
  var source = isYoutube(url) ? (opts.youtubeMode === "video" ? "youtube-video" : "youtube-audio") : "spotify"
  return ["bash", String(opts.script || ""), dest, url, String(opts.format || "mp3"), source]
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

// Parses the marker lines download-job.sh makes yt-dlp print. The bar stops at
// 85 during the download so the (for long sets, slow) conversion still shows
// up as progress. Video jobs download two streams, so their bar runs twice.
function parseYoutubeLine(line) {
  var text = String(line || "")
  var m = text.match(/^Titel: (.+)$/)
  if (m) return { title: m[1] }
  m = text.match(/^Downloaden\s+([\d.]+)%/)
  if (m) {
    var percent = Math.max(0, Math.min(100, parseFloat(m[1])))
    return { message: "Downloaden " + Math.round(percent) + "%", progress: Math.round(percent * 0.85) }
  }
  if (text === "Converteren") return { message: "Converteren", progress: 90 }
  return null
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

// Short, stable label for a freshly queued job before the tool reports a title.
function shortLabel(url) {
  var s = String(url || "").trim()
  var m = s.match(/open\.spotify\.com\/(?:intl-[a-z]{2}\/)?(track|album|playlist|artist)\/([A-Za-z0-9]+)/)
  if (m) {
    var kind = m[1].charAt(0).toUpperCase() + m[1].slice(1)
    return kind + " " + m[2].slice(0, 8)
  }
  var y = s.match(/(?:[?&]v=|youtu\.be\/|\/shorts\/|\/live\/)([A-Za-z0-9_-]+)/)
  if (y && isYoutube(s)) return "YouTube " + y[1].slice(0, 8)
  return s.length > 60 ? s.slice(0, 57) + "…" : s
}

// URI for Qt.openUrlExternally: SMB destinations open as smb://, local ones
// as file:// with each path segment percent-encoded.
function fileUri(path) {
  var smb = smbUri(path)
  if (smb !== "") return smb
  var parts = String(path || "").split("/")
  for (var i = 0; i < parts.length; i++) parts[i] = encodeURIComponent(parts[i])
  return "file://" + parts.join("/")
}
