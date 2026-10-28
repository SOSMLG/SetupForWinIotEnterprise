---
name: ffmpeg-recipes
description: ffmpeg and ffprobe commands for trimming, joining, compressing, audio and captions. Load before writing an ffmpeg command.
---
Rules: never overwrite a source (write a new name, pass `-n`). Probe first. Quote paths with double quotes.
`-c copy` is fast but cuts on keyframes. Re-encode when the cut must be exact.

- probe: `ffprobe -v error -show_entries format=duration:stream=codec_name,width,height,r_frame_rate -of default=nw=1 "in.mp4"`
- trim, exact: `ffmpeg -n -ss 00:01:00 -to 00:02:30 -i "in.mp4" -c:v libx264 -crf 20 -c:a aac "out.mp4"`
- trim, fast: `ffmpeg -n -ss 00:01:00 -to 00:02:30 -i "in.mp4" -c copy "out.mp4"`
- join same-codec files: put `file 'a.mp4'` lines in list.txt, then `ffmpeg -n -f concat -safe 0 -i list.txt -c copy "out.mp4"`
- compress: `ffmpeg -n -i "in.mp4" -c:v libx264 -crf 23 -preset medium -c:a aac -b:a 128k -movflags +faststart "out.mp4"`
- scale to 720p: add `-vf scale=-2:720`
- audio out: `ffmpeg -n -i "in.mp4" -vn -c:a libmp3lame -q:a 2 "out.mp3"`
- loudness: add `-af loudnorm=I=-16:TP=-1.5:LRA=11`
- burn captions: `-vf "subtitles=subs.srt"` (keep the .srt in the working dir, avoid `C:\` in the filter)
- thumbnail: `ffmpeg -n -ss 5 -i "in.mp4" -frames:v 1 "thumb.jpg"`
- speed x2: `-filter:v "setpts=0.5*PTS" -filter:a "atempo=2.0"`
