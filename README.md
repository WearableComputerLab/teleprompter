# Teleprompter

A macOS teleprompter that follows your voice. It loads a script, listens to your microphone with Apple's speech recognition, works out where you are, and shows the current and next sentence in an overlay on whichever screen you choose.

## Build & run

```bash
./build.sh            # builds build/Teleprompter.app
./build.sh --install  # also copies it to ~/Applications
open build/Teleprompter.app
```

On first **Start Listening** macOS asks for Microphone and Speech Recognition access.

## Using it

- **Open a script**: ⌘O, drag a file onto the window, or `open -a build/Teleprompter.app script.docx`. Supports .docx/.doc, .rtf, .odt, .html, .pdf, .txt/.md/.fountain.
- **Spoken text**: screenplay-style scripts (character cues like `NARRATOR (V.O.)` followed by indented dialogue) are detected automatically. Only the dialogue is tracked, and stage directions appear as yellow cues before the sentence they come before. Switch to “All text” for plain scripts.
- **Screen**: pick the display for the overlay (use the identify button to flash numbers on each screen). Put it on a screen you are *not* recording. “Try to hide from screen recordings” also asks macOS to exclude the window from capture, but not every recorder honours it.
- **Tracking**: the tracker aligns the last ~10 recognised words with the script, so it copes with misrecognitions, ad-libs, retakes (go back and repeat a sentence) and skipping ahead. Click any sentence in the list to jump there.
- **Global shortcuts** (work while another app is focused): ⌃⌥⌘→ next sentence, ⌃⌥⌘← previous, ⌃⌥⌘L start/stop listening, ⌃⌥⌘H show/hide the overlay.
- Your position in each script is remembered between launches.

## Dev helpers

```bash
.build/release/Teleprompter --parse ~/Documents/script.docx     # show how the script was classified
.build/release/Teleprompter --simulate ~/Documents/script.docx  # run the tracker on a noisy fake transcript
```
