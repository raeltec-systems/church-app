#!/usr/bin/env bash
# Final delivery for one film: picture in every format (30 fps, motion blur), SFX, -14 LUFS mix muxed
# into each, posters, then copies named for delivery in out/delivery/.
#   journeys/final.sh <film>
set -e
film=$1
SK=~/.claude/plugins/cache/anthropic-plugin-directory/motion-reel/1.2.0-004405d63429/skills/motion-reel
for f in 16x9 9x16 1x1; do node $SK/scripts/render.mjs --film $film --format $f --video-only --fps 30 --workers 4 | tail -1; done
node $SK/scripts/sfx.mjs $film | tail -1
node $SK/scripts/mix.mjs $film | tail -4
for f in 16x9 9x16 1x1; do node $SK/scripts/render.mjs --film $film --format $f --poster | tail -1; done
for f in 16x9 9x16 1x1; do node $SK/scripts/render.mjs --film $film --format $f --contact --workers 4 | tail -1; done
mkdir -p out/delivery
cp out/$film/final.mp4 out/delivery/$film-16x9.mp4
cp out/$film/final_9x16.mp4 out/delivery/$film-9x16.mp4
cp out/$film/final_1x1.mp4 out/delivery/$film-1x1.mp4
cp out/$film/contact.png out/delivery/$film-contact-16x9.png
cp out/$film/contact_9x16.png out/delivery/$film-contact-9x16.png
cp out/$film/contact_1x1.png out/delivery/$film-contact-1x1.png
cp out/$film/poster.png out/delivery/$film-poster-16x9.png
echo "delivered $film"
