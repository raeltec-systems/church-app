#!/usr/bin/env bash
# One critique round for a film: contact sheets in every format, SFX + mix, visual hits, sync check.
#   journeys/round.sh <film>
set -e
film=$1
SK=~/.claude/plugins/cache/anthropic-plugin-directory/motion-reel/1.2.0-004405d63429/skills/motion-reel
for f in 16x9 9x16 1x1; do node $SK/scripts/render.mjs --film $film --format $f --contact --workers 4 | tail -1; done
ffmpeg -loglevel error -y -i out/$film/contact.png -vf scale=iw/3:-2 out/$film/phone.png
node $SK/scripts/sfx.mjs $film | tail -2
node $SK/scripts/mix.mjs $film --no-mux | tail -3
node $SK/scripts/render.mjs --film $film --hits | tail -1
MOTION_REEL_SKILL=$SK uv run $SK/scripts/sync.py $film 2>&1 | tail -8
