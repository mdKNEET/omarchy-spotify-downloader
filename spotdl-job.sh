#!/usr/bin/env bash
# Runs one spotdl download for the widget.
#
# Usage: spotdl-job.sh <destination> <url> <format>
#
# <destination> is either a local directory or an smb:// URI. SMB targets are
# never written through the gvfs FUSE path (/run/user/$UID/gvfs/...): when
# gvfsd-fuse is not running that path is plain tmpfs, so writes "succeed" but
# only land in RAM. Instead spotdl downloads into a private staging directory
# and the finished files are copied to the share with gio, which talks to
# gvfsd-smb directly.
set -u

dest=$1
url=$2
format=$3
template='{artists} - {title}.{output-ext}'

download() {
  spotdl download "$url" \
    --format "$format" \
    --output "$template" \
    --overwrite skip \
    --simple-tui
}

case $dest in
  smb://*) ;;
  *)
    mkdir -p "$dest" && cd "$dest" || { echo "Kan map niet openen: $dest"; exit 1; }
    download
    exit $?
    ;;
esac

dest=${dest%/}
share=$(printf '%s' "$dest" | sed -E 's#^(smb://[^/]+/[^/]+).*#\1#')

if ! gio info "$share" >/dev/null 2>&1; then
  echo "Share koppelen: $share"
  if ! gio mount "$share" </dev/null >/dev/null 2>&1; then
    echo "Kan $share niet koppelen (open de share eens in je bestandsbeheerder en bewaar het wachtwoord)"
    exit 1
  fi
fi

if ! gio info "$dest" >/dev/null 2>&1 && ! gio mkdir -p "$dest" 2>/dev/null; then
  echo "Kan servermap niet aanmaken: $dest"
  exit 1
fi

cache=${XDG_CACHE_HOME:-$HOME/.cache}/spotify-downloader
mkdir -p "$cache" || exit 1
stage=$(mktemp -d "$cache/job.XXXXXX") || exit 1
trap 'rm -rf "$stage"' EXIT

cd "$stage" || exit 1
download
status=$?

existing=$(gio list "$dest" 2>/dev/null)
copied=0
skipped=0
failed=0

while IFS= read -r -d '' file; do
  name=${file##*/}
  if printf '%s\n' "$existing" | grep -Fxq -- "$name"; then
    skipped=$((skipped + 1))
    continue
  fi
  echo "Kopiëren naar server: $name"
  if gio copy -- "$file" "$dest/" 2>/dev/null; then
    copied=$((copied + 1))
  else
    echo "Kopiëren mislukt: $name"
    failed=$((failed + 1))
  fi
done < <(find "$stage" -type f ! -name '.*' -print0)

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
