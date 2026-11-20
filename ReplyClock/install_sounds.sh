#!/bin/bash
# Give Reply Clock your own sounds: copies them to ~/Library/Application Support/ReplyClock/sounds.
#   install_sounds.sh <folder holding the .mp3 files>
# The folder may hold any of the files named below (the README says when each plays). A sound
# with no file keeps its built-in macOS sound. Run again after changing a file: the app uses
# the new one the next time it plays, no rebuild.
set -euo pipefail

FROM="${1:?Usage: install_sounds.sh <folder holding the .mp3 files>}"
TO="$HOME/Library/Application Support/ReplyClock/sounds"

mkdir -p "$TO"
# The names are the ones main.swift lists under "Sounds".
names=(answer_sound_1 clock-tick low_on_time long_thinking question-mark exclamation_mark
       fail-sound-effect 50_percent_credits punch-sound-effect-meme bruh)
copied=0
for name in "${names[@]}"; do
  if [[ -f "$FROM/$name.mp3" ]]; then
    cp "$FROM/$name.mp3" "$TO/"
    copied=$((copied + 1))
  else
    echo "no $name.mp3 there: that sound keeps its built-in one"
  fi
done
echo "Copied $copied of ${#names[@]} sounds to $TO"
