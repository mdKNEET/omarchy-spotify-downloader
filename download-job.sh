#!/usr/bin/env bash
# Runs one download for the widget: spotdl for Spotify links and search
# queries, yt-dlp for YouTube links.
#
# Usage: download-job.sh <destination> <url> <format> [<source>]
#
# <source> is spotify (default), youtube-audio or youtube-video.
#
# <destination> is either a local directory or an smb:// URI. SMB targets are
# never written through the gvfs FUSE path (/run/user/$UID/gvfs/...): when
# gvfsd-fuse is not running that path is plain tmpfs, so writes "succeed" but
# only land in RAM. Instead the download goes into a private staging directory
# and the finished files are copied to the share with gio, which talks to
# gvfsd-smb directly.
#
# Every network step retries with a growing pause (see `retry`), so a NAS
# that is waking up, a dropped mount or a brief wifi hiccup no longer fails
# the job outright.
set -u

dest=$1
url=$2
format=$3
source=${4:-spotify}
template='{artists} - {title}.{output-ext}'

attempts=${SPOTDL_JOB_ATTEMPTS:-4}

# The widget cancels a job with SIGTERM to this script only, so each tool runs
# in its own session and the whole group (ffmpeg included) is stopped with it.
child=0
run() {
  local code
  setsid "$@" </dev/null &
  child=$!
  wait "$child"
  code=$?
  child=0
  return "$code"
}

stop_child() {
  if [ "$child" -gt 0 ]; then
    kill -TERM -- "-$child" 2>/dev/null
    wait "$child" 2>/dev/null
  fi
  exit 143
}
trap stop_child TERM INT HUP

download_spotify() {
  run spotdl download "$url" \
    --format "$format" \
    --output "$template" \
    --overwrite skip \
    --max-retries 3 \
    --simple-tui
}

# The Titel/Downloaden/Converteren lines are parsed by parseYoutubeLine in
# Model.js. A " | " in a title becomes " - " because SMB shares reject "|".
download_youtube() {
  local -a args=(
    --no-playlist
    --windows-filenames
    --embed-metadata
    --replace-in-metadata title ' *\| *' ' - '
    --output '%(artist&{} - |)s%(track,title)s.%(ext)s'
    --newline
    --progress
    --progress-template 'download:Downloaden %(progress._percent_str)s'
    --print 'before_dl:Titel: %(title)s'
    --print 'post_process:%(id&Converteren|)s'
  )

  if [ "$source" = youtube-video ]; then
    args+=(-f 'bv*+ba/b' -S 'res:1080,vcodec:h264,acodec:m4a' --merge-output-format mp4)
  else
    local codec=$format
    [ "$format" = ogg ] && codec=vorbis
    args+=(-x --audio-format "$codec" --audio-quality 0)
    # Cover art in the other containers needs python-mutagen and fails the job.
    [ "$format" = mp3 ] && args+=(--embed-thumbnail)
  fi

  run yt-dlp "${args[@]}" -- "$url"
}

keep_ext=
case $source in
  youtube-audio) keep_ext=$format ;;
  youtube-video) keep_ext=mp4 ;;
esac

if [ -n "$keep_ext" ] && ! command -v yt-dlp >/dev/null 2>&1; then
  echo "yt-dlp niet gevonden (installeer met: omarchy pkg add yt-dlp)"
  exit 127
fi

download() {
  if [ -n "$keep_ext" ]; then
    download_youtube
  else
    download_spotify
  fi
}

# retry <label> <command...>: runs the command up to $attempts times, waiting
# 2, 4, 8... seconds in between, and calls `reconnect` before each new try.
retry() {
  local label=$1 try=1 pause=2
  shift
  while :; do
    "$@" && return 0
    [ "$try" -ge "$attempts" ] && return 1
    echo "$label mislukt, nieuwe poging $((try + 1))/$attempts over ${pause}s"
    sleep "$pause"
    reconnect
    try=$((try + 1))
    pause=$((pause * 2))
  done
}

reconnect() { :; }

make_stage() {
  local cache=${XDG_CACHE_HOME:-$HOME/.cache}/spotify-downloader
  mkdir -p "$cache" || exit 1
  stage=$(mktemp -d "$cache/job.XXXXXX") || exit 1
  trap 'rm -rf "$stage"' EXIT
  cd "$stage" || exit 1
}

# yt-dlp leaves part files, thumbnails and separate streams behind after a
# failed or cancelled run, and ffmpeg writes straight to the final name; only
# finished output may leave the staging directory.
stage_filter=(-type f ! -name '.*' ! -name '*.part' ! -name '*.ytdl' ! -name '*.temp.*' ! -name '*.f[0-9]*.*')
[ -n "$keep_ext" ] && stage_filter+=(-name "*.$keep_ext")

case $dest in
  smb://*) ;;
  *)
    mkdir -p "$dest" && cd "$dest" || { echo "Kan map niet openen: $dest"; exit 1; }
    dest=$PWD
    if [ -z "$keep_ext" ]; then
      download
      exit $?
    fi

    make_stage
    download
    status=$?
    saved=0
    while IFS= read -r -d '' file; do
      if [ -e "$dest/${file##*/}" ] || mv -- "$file" "$dest/"; then
        saved=$((saved + 1))
      fi
    done < <(find "$stage" "${stage_filter[@]}" -print0)
    if [ "$status" -eq 0 ] && [ "$saved" -eq 0 ]; then
      echo "Geen bestanden gedownload"
      exit 1
    fi
    exit "$status"
    ;;
esac

dest=${dest%/}
# smb://[user@]host/share and the folder path below it.
share=$(printf '%s' "$dest" | sed -E 's#^(smb://[^/]+/[^/]+).*#\1#')
sub=${dest#"$share"}
host=$(printf '%s' "$share" | sed -E 's#^smb://([^@/]*@)?([^/:]+).*#\2#')
sharename=${share##*/}

# gio treats smb://host/share and smb://user@host/share as different
# locations, so a share the file manager mounted as desire@... reads as "not
# mounted" when asked for without the user. Reuse whatever mount already
# exists for this host and share, whichever user it was made with.
mounted_share() {
  gio mount -l 2>/dev/null \
    | sed -nE 's#^Mount\([0-9]+\): .* -> (smb://([^@/]*@)?([^/]+)/([^/]+))/?$#\1 \3 \4#p' \
    | while read -r uri h s; do
        if [ "${h,,}" = "${host,,}" ] && [ "${s,,}" = "${sharename,,}" ]; then
          echo "$uri"
          break
        fi
      done
}

server_reachable() {
  timeout 3 bash -c "exec 3<>/dev/tcp/$host/445" 2>/dev/null
}

connect() {
  local found
  if ! server_reachable; then
    echo "NAS $host niet bereikbaar"
    return 1
  fi
  found=$(mounted_share)
  if [ -n "$found" ]; then
    share=$found
  else
    echo "Share koppelen: $share"
    if ! gio mount "$share" </dev/null >/dev/null 2>&1; then
      # The password is usually saved in the keyring under the login name.
      case $share in
        smb://*@*) return 1 ;;
      esac
      local withuser="smb://$USER@${share#smb://}"
      gio mount "$withuser" </dev/null >/dev/null 2>&1 || return 1
      share=$withuser
    fi
  fi
  dest=$share$sub
  gio info "$dest" >/dev/null 2>&1 || gio mkdir -p "$dest" 2>/dev/null
}

if ! retry "Verbinden met NAS" connect; then
  echo "Kan $share niet koppelen (open de share eens in je bestandsbeheerder en bewaar het wachtwoord)"
  exit 1
fi

# From here on a failed copy re-checks the connection before trying again.
reconnect() { connect >/dev/null 2>&1; }

make_stage
download
status=$?

existing=$(gio list "$dest" 2>/dev/null)
copied=0
skipped=0
failed=0

copy_file() { gio copy -- "$1" "$dest/" 2>/dev/null; }

while IFS= read -r -d '' file; do
  name=${file##*/}
  if printf '%s\n' "$existing" | grep -Fxq -- "$name"; then
    skipped=$((skipped + 1))
    continue
  fi
  echo "Kopiëren naar server: $name"
  if retry "Kopiëren" copy_file "$file"; then
    copied=$((copied + 1))
  else
    echo "Kopiëren mislukt: $name"
    failed=$((failed + 1))
  fi
done < <(find "$stage" "${stage_filter[@]}" -print0)

if [ "$failed" -gt 0 ]; then
  echo "Opslaan op server mislukt voor $failed bestand(en)"
  exit 1
fi

if [ "$copied" -eq 0 ] && [ "$skipped" -eq 0 ]; then
  echo "Geen bestanden gedownload"
  exit 1
fi

echo "Opgeslagen op server: $copied nieuw, $skipped al aanwezig"
exit "$status"
