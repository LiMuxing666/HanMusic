# Generated metadata fixtures

These short tones and the 2 × 2 solid-color PNG were generated locally using FFmpeg 7.1. They contain no recordings or third-party artwork. Their purpose is metadata parsing; audible playback is tested separately by the Windows backend probe.

- Audio input: `-f lavfi -i sine=frequency=220:sample_rate=8000:duration=0.25`; MP3 uses `sample_rate=44100` (MPEG-1).
- Cover input: `-f lavfi -i color=c=0x256747:s=2x2 -frames:v 1 cover.png`.
- MP3: `libmp3lame`, ID3v2.3, PNG attached picture.
- FLAC: `flac`, Vorbis comments, PNG attached picture.
- WAV: `pcm_s16le`, RIFF INFO tags, no attached picture.
- Titles: `Fixture MP3`, `Fixture FLAC`, `Fixture WAV`; artist `HanMusic Tests`; album `Generated Samples`.

Tests copy fixtures to a disposable directory under `build/`, verify original bytes remain unchanged after import, and inspect the extracted image bytes and safe cache filename. No installed FFmpeg binary is needed to run the tests.
