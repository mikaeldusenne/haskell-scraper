#!/usr/bin/env bash
# Download saved player URLs with their lesson referer; yt-dlp handles Vimeo/HLS/DASH.
set -euo pipefail
[[ $# -le 1 ]] || { printf 'Usage: bash scripts/amerilingua-videos.sh [OUTPUT_DIR]\n' >&2; exit 2; }
root=$(realpath -- "${1:-amerilingua_downloads}")
[[ -d "$root" ]] || { printf 'Output directory does not exist.\n' >&2; exit 1; }
command -v yt-dlp >/dev/null || { printf 'Install yt-dlp and ffmpeg first (see docs/AMERILINGUA.md).\n' >&2; exit 1; }
mkdir -- "$root/.scraper-lock"
list=''
trap '[[ -z "$list" ]] || rm -f -- "$list"; rmdir -- "$root/.scraper-lock"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
list=$(mktemp "$root/.scraper-lock/manifest.XXXXXX")
find "$root" -type f -name video-urls.txt -size +0c -print0 > "$list"
failed=0
while IFS= read -r -d '' manifest; do
  directory=${manifest%/*}
  if [[ -L "$directory/source.txt" || -L "$directory/video" || -L "$directory/video/archive.txt" ]]; then
    printf 'Refusing symbolic link in %s\n' "$directory" >&2
    failed=1
    continue
  fi
  if ! IFS= read -r referer < "$directory/source.txt"; then
    printf 'Missing lesson source in %s\n' "$directory" >&2
    failed=1
    continue
  fi
  if [[ "$referer" != https://* && "$referer" != http://* ]]; then
    printf 'Invalid lesson source in %s\n' "$directory" >&2
    failed=1
    continue
  fi
  mkdir -p -- "$directory/video"
  yt-dlp --ignore-config --no-playlist --no-overwrites --restrict-filenames \
    --add-headers "Referer:$referer" --batch-file "$manifest" \
    --paths "$directory/video" --output '%(id)s.%(ext)s' \
    --download-archive "$directory/video/archive.txt" || failed=1
done < "$list"
exit "$failed"
