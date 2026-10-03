# usage: sheet.sh fmt cols scale times...
f=$1; c=$2; sc=$3; shift 3; n=$#
node stills.mjs $f "$@" || exit 1
read W H <<<$(case $f in 16x9) echo 1920 1080;; 9x16) echo 1080 1920;; 1x1) echo 1080 1080;; esac)
ins=""; lab=""; lay=""; i=0
for t in "$@"; do ins="$ins -i st-$f-$t.jpg"; lab="$lab[$i]"; lay="$lay$(( (i%c)*W ))_$(( (i/c)*H ))|"; i=$((i+1)); done
ffmpeg -v error -y $ins -filter_complex "${lab}xstack=inputs=$n:layout=${lay%|}:fill=black,scale=iw/$sc:-1" sheet-$f.jpg
