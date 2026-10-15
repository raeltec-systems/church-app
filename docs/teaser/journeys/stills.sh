#!/usr/bin/env bash
# Render stills of a film at the given BEATS for one format and tile them in time order.
#   journeys/stills.sh <film> <format> <cols> <beat,beat,...>   -> out/<film>/beats_<format>.png
set -e
film=$1; fmt=$2; cols=$3; beats=$4
SK=~/.claude/plugins/cache/anthropic-plugin-directory/motion-reel/1.2.0-004405d63429/skills/motion-reel
per=$(python3 -c "import json;print(json.load(open('$film/beats.json'))['period'])")
T=$(python3 -c "print(','.join(str(round(float(b)*$per,3)) for b in '$beats'.split(',')))")
rm -rf out/$film/stills
node $SK/scripts/render.mjs --film $film --format $fmt --at $T --workers 4 >/dev/null
h=$([ "$fmt" = "16x9" ] && echo 360 || echo 640)
ls out/$film/stills/ | grep png | sort -k1.2 -g | sed "s|^|file out/$film/stills/|" > /tmp/claude-0/stills_list.txt
sed -i "s|file |file $PWD/|" /tmp/claude-0/stills_list.txt
n=$(wc -l < /tmp/claude-0/stills_list.txt); rows=$(( (n + cols - 1) / cols ))
ffmpeg -loglevel error -y -f concat -safe 0 -i /tmp/claude-0/stills_list.txt -vf "scale=-2:$h,pad=iw+6:ih+6:3:3:gray,tile=${cols}x${rows}" -frames:v 1 out/$film/beats_$fmt.png
echo out/$film/beats_$fmt.png
