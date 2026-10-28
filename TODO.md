# To do

Plan (2026-10-28): get the Mac version solid and well tested first, the same way as Audiobook Maker, then
publish to GitHub with an offline installer.
**Goal:** word-for-word transcripts of videos and recordings, with speakers, for studying, test prep and
looking at language patterns.

## Done on day 1 (2026-10-28)
- [x] Engine: sound out of the video, Parakeet "ultra" speech recognition with word times, speaker separation,
      words matched to speakers, paragraphs per speaker. Keeps um, uh, repeats.
- [x] macOS 14 crash in speaker separation fixed (Apple's Core ML CPU bug; FluidAudio vendored with the fix)
- [x] First run after an install can fail in the speech model: retries on the graphics chip automatically
- [x] Window like Audiobook Maker: videos on top, audio below, settings on the right, log at the bottom,
      toolbar (+, start/pause/resume, stop, output folder, verbose, settings, donate, coffee cup)
- [x] Queue with up/down arrows and "Queued · #2", saved between launches
- [x] Saves PDF and DOCX (plus TXT, SRT, VTT if ticked), timestamps on or off
- [x] Rename speakers ("Person 1" -> "Teacher"): the saved files are written again
- [x] Quick replies split off better (denser speaker windows)

## Done on day 2 (2026-10-28)
- [x] Numbers no longer glued to the word before ("about24" -> "about 24"); "i" -> "I"
- [x] Speaker changes move to the nearest pause or sentence end (no more "…as well I | do so…")
- [x] Optional sound clean-up per file: Off / Gentle / Strong. Measured on a clip with added noise, music,
      echo and a quiet voice: Off made the fewest mistakes (0-1.7 %), Gentle about the same, Strong about
      twice as many. Off stays the default.
- [x] App icon; offline edition DMG with the models and ffmpeg inside (works from a read-only disk image)
- [x] Example transcripts for the README: Richard Bandler, Judge Judy, Benn Jordan, Pasadena town hall

## Now: test and polish
- [ ] Try it on real study videos of different kinds: one speaker (lecture), two (interview), many (Zoom).
      Note words heard wrong and speaker mix-ups
- [x] Long files: a 2 h 7 min session worked (19,560 words, 2 speakers)
- [ ] The first transcript after installing is slow (the speech model is prepared for the Mac and falls back
      to the graphics chip once): look for a way to prepare it ahead, e.g. on first launch
- [ ] MKV / WebM / AVI: length shows only with ffprobe (the offline edition has ffmpeg, not ffprobe)
- [ ] **Closed captions:** when a video carries a subtitle or caption track, save it too ("Captions from the
      video" as an extra file), and maybe compare it with what was heard
- [ ] **Words to know** (names, jargon) per file or for all files, to steer spelling (FluidAudio has custom
      vocabulary support)
- [ ] Words the recogniser was unsure of: show them faintly in the preview, optionally mark them in the PDF/DOCX
- [ ] Click a paragraph's time in the preview to play the video from there
- [ ] Notification when a transcript is finished (like Audiobook Maker)
- [ ] Settings: choose the default formats there too; Check for updates (like Audiobook Maker)
- [ ] VoiceOver pass

## Published 2026-10-28: public repo + v0.1.0 release (offline DMG)
- [x] github.com/TechnAudioToolz/video-audio-to-transcript, README with four examples and screenshots
- [ ] Test the DMG on another Mac
- Next release: bump CFBundleShortVersionString in app/Resources/Info.plist, ./build.sh && ./make_offline_dmg.sh,
  then `gh release create`

## Later
- [ ] Other languages (Parakeet ultra knows 25 European languages)
- [ ] Linux, then Windows
