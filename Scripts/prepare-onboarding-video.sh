#!/bin/bash
set -euo pipefail

# Usage: bash Scripts/prepare-onboarding-video.sh /path/to/hermes-jr-onboarding-pixel.mp4
# Requires ffmpeg. Coordinates and timing are specific to the 1920x1080 pixel clip.
source_video="${1:?Pass the original pixel onboarding MP4}"
resource_dir="$(cd "$(dirname "$0")/../Hermes/Resources" && pwd)"

# Hold only the cloud below the boy's arm at 4.5s, before it starts stretching.
# Hold the planet below the girl at its first-frame shape for the whole clip.
# A 16px feather hides both crop boundaries while the rest keeps moving.
# Cover the lower-right watermark with nearby same-frame grid, feathered by 6px.
ffmpeg -hide_banner -loglevel error -y -i "$source_video" \
  -filter_complex "[0:v]split=4[base][patch][planet][grid];[patch]trim=start=4.5,setpts=PTS-STARTPTS,trim=end_frame=1,crop=320:200:300:760,format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='255*min(1,min(min(X,W-1-X),min(Y,H-1-Y))/16)'[clean];[planet]trim=end_frame=1,setpts=PTS-STARTPTS,crop=190:170:1360:720,format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='255*min(1,min(min(X,W-1-X),min(Y,H-1-Y))/16)'[stillplanet];[base][clean]overlay=300:760:enable='gte(t,4.5)':eof_action=repeat:repeatlast=1:format=auto[cloudfixed];[cloudfixed][stillplanet]overlay=1360:720:eof_action=repeat:repeatlast=1:format=auto[shapesfixed];[grid]crop=58:36:1825:928,format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='255*min(1,min(min(X,W-1-X),min(Y,H-1-Y))/6)'[cleanGrid];[shapesfixed][cleanGrid]overlay=1852:1032:format=auto,format=yuv420p[out]" \
  -map '[out]' -map '0:a?' -c:v libx264 -crf 14 -preset slow \
  -c:a copy -fps_mode passthrough -movflags +faststart \
  "$resource_dir/hermes-jr-onboarding.mp4"

# Match the loading placeholder to the new video's first frame.
ffmpeg -hide_banner -loglevel error -y \
  -i "$resource_dir/hermes-jr-onboarding.mp4" -frames:v 1 -q:v 1 -pix_fmt yuvj444p \
  "$resource_dir/hermes-jr-onboarding-poster.jpg"
