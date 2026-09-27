# Spotify Downloader for Omarchy

A native [Omarchy](https://omarchy.org/) bar plugin that downloads Spotify
tracks, albums, and playlists to local audio files using
[spotDL](https://github.com/spotdl/spotify-downloader). Paste a link, queue
it, and keep browsing: several downloads run in parallel and everything
lives in one bar icon, in the same style as Omarchy's built-in widgets
(Dropbox, Tailscale, Weather, ...).

## Features

- 🎵 One bar icon; click it to open a small panel with a link field and a
  download queue.
- ⬇️ Paste a Spotify track/album/playlist/artist link (or any query spotDL
  understands) and hit Enter or "Downloaden".
- ⚡ Several downloads run at once (configurable, default 3).
- 📁 Pick the destination folder from a native folder picker, or save
  straight to a network share (`smb://server/share/folder`).
- 🎚️ Choose the output audio format (mp3, flac, opus, m4a, wav, ogg).
- ✅ Per-download status (queued / downloading / done / failed) with the
  last line spotDL reported, and a cancel/remove button per row.

## Requirements

- [Omarchy](https://omarchy.org/) (Quickshell-based bar/shell).
- [spotDL](https://github.com/spotdl/spotify-downloader) on `PATH` (the
  widget detects a missing install and offers a one-click installer via
  `pipx`).
- `ffmpeg` (spotDL uses it to encode audio; Omarchy ships it by default).
- `zenity` (native folder picker for the settings panel).

Install the dependencies manually if you don't use the in-widget installer:

```bash
omarchy pkg add python-pipx zenity
pipx install spotdl
```

## Install

```bash
omarchy plugin add https://github.com/mdKNEET/omarchy-spotify-downloader.git --enable --yes
```

This clones the plugin into `~/.config/omarchy/plugins/io.github.mdkneet.spotify-downloader/`,
enables it, and drops its icon into the right section of the bar. Move it
with:

```bash
omarchy bar move io.github.mdkneet.spotify-downloader --section left
```

### Manual install

```bash
git clone https://github.com/mdKNEET/omarchy-spotify-downloader.git \
  ~/.config/omarchy/plugins/io.github.mdkneet.spotify-downloader
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.mdkneet.spotify-downloader
```

## Usage

1. Click the music-note icon in the bar.
2. Paste a Spotify link (or a search query spotDL understands) and press
   Enter or click "Downloaden".
3. Repeat: every link you add joins the queue and starts as soon as a
   download slot is free.
4. Click the gear icon for settings: download folder (with a native
   "Bladeren…" folder picker), max simultaneous downloads, and audio
   format. Changes save immediately and persist in
   `~/.config/omarchy/shell.json`.

## Saving to a network share (SMB)

Set the download folder to an `smb://` URI, for example
`smb://10.0.0.118/plex/Muziek/SpotDL`. A folder picked from the gvfs mount
in your file manager (`/run/user/1000/gvfs/smb-share:server=...,share=...`)
is recognised and converted to the same `smb://` URI automatically.

Tracks are downloaded to a private staging folder under
`~/.cache/spotify-downloader/` first and then copied to the share with
`gio copy`. Files that already exist on the share are skipped. The widget
never writes to the `/run/user/$UID/gvfs/...` path itself: when
`gvfsd-fuse` is not running that path is ordinary tmpfs, so writes appear
to succeed but only land in RAM and never reach the server.

The share must be reachable without a password prompt: open it once in
your file manager and let it remember the password.

## Updating / removing

```bash
omarchy plugin update io.github.mdkneet.spotify-downloader
omarchy plugin remove io.github.mdkneet.spotify-downloader
```

## How it works

The widget is a single `bar-widget` plugin (`BarWidget.qml`). Up to
`maxConcurrent` worker "lanes" each own one `spotdl-job.sh` process (which
runs `spotdl download` and, for SMB targets, copies the result to the share); the
queue hands the next waiting link to the first free lane. Settings
(download folder, concurrency, audio format) are declared in `manifest.json`
via the standard Omarchy plugin settings schema, so they also show up in
Omarchy's own widget-settings UI, and are additionally editable from the
widget's own settings panel.

## License

MIT, see [LICENSE](LICENSE).
