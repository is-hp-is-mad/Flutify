# Motion video timeline fixture

`motion-offset.mp4` is a generated 32 × 32 H.264 test pattern: 25 frames at
25 fps, B-frames enabled, and a keyframe every five frames. All five fragments
have a ten-second `tfdt` origin, reproducing Apple Music's HLS packaging without
depending on its servers or including artist footage.

Generate the zero-origin file with FFmpeg:

```sh
ffmpeg -f lavfi -i 'testsrc2=size=32x32:rate=25' -t 1 \
  -c:v libx264 -bf 2 -g 5 -video_track_timescale 1000 \
  -movflags '+empty_moov+frag_keyframe+default_base_moof' motion-offset.mp4
```

Then add 10,000 ticks to each `tfdt` base media decode time (version 1: the
big-endian uint64 eight bytes after the start of the `tfdt` type). The track
timescale is 1,000 ticks per second. The first presentation timestamp should
be 10.080 seconds; the fixed extractor should emit it at 0.080 seconds and
preserve every subsequent sample interval, including after `seek(0, 0)`.
