# callrec

Records your iPhone calls when you take them on your Mac, and writes out a transcript you can read.

Everything happens on this Mac. Nothing is uploaded anywhere. The other person is not told.

## Install

Open Terminal (press Cmd+Space, type "Terminal", hit Enter). The careful way, which lets you read
the installer before it runs:

```
curl -fsSLO https://raw.githubusercontent.com/DDOS44/callrec/main/scripts/install.sh
less install.sh
bash install.sh
```

Or the quick way, which runs it unread:

```
curl -fsSL https://raw.githubusercontent.com/DDOS44/callrec/main/scripts/install.sh | bash
```

It takes about ten minutes, mostly downloading the transcription model (1.6 GB, one time).
Only ffmpeg comes from Homebrew; transcription runs inside callrec itself (WhisperKit on the
Neural Engine), so there is no separate whisper install.

What it asks and what it checks:

- **It asks before anything that needs your password**: installing Homebrew (if you do not have
  it) and linking `callrec` into `/usr/local/bin` with `sudo`. Say no to the link and it adds
  `~/.callrec/bin` to your PATH instead.
- **Downloads are verified before they are installed.** Each release publishes `SHA256SUMS`
  covering the binary, the app zip, the model script and the model manifest. The installer checks
  them and stops on any mismatch. If a release has no `SHA256SUMS` it refuses to install (override
  at your own risk: `CALLREC_ALLOW_UNVERIFIED=1 bash install.sh`). `SHA256SUMS` comes from the same
  release, so it catches corrupt or swapped files, not a compromised release.
- **Model files are pinned.** `scripts/model-manifest.txt` lists every model file with the exact
  Hugging Face commit it comes from and its SHA-256. A file that does not match is never installed,
  and re-running `~/.callrec/download-model.sh` re-verifies what is already there.
- The installer does not strip macOS's quarantine flag. `curl` does not set it. If you download the
  app zip in a browser instead and macOS blocks it, use System Settings -> Privacy & Security ->
  Open Anyway.

The first transcription after install compiles the model for your Mac. That takes several minutes,
once, and callrec just looks busy; every transcription after it starts in seconds.

### Turn on two permissions

macOS will not let anything record audio until you say so. After the install finishes:

1. **System Settings → Privacy & Security → Screen & System Audio Recording →** open the
   **"System Audio Recording Only"** list **→ turn on callrec**
2. **System Settings → Privacy & Security → Microphone → turn on callrec**

Then run this once so the recorder picks up the new permissions:

```
callrec uninstall-agent && callrec install-agent
```

That is the whole setup. It starts itself every time you log in.

### The app

Open **callrec** from Applications, or click the **phone icon in the menu bar**. That is where you
read calls: a day list on the left, that day's calls in the middle, and the selected call on the
right with audio, transcript, outcome buttons and notes. The menu bar icon turns red while a call
is recording.

## Your first call

Take a call on your Mac the way you normally do (iPhone calls ring on the Mac when both are on
the same Apple ID). Talk. Hang up.

About a minute later the call shows up in the callrec app, and two files appear in
**`~/CallRecordings/`**, in a folder for today's date:

- `14-02-00.m4a` — the recording, both sides
- `14-02-00.md` — the transcript

The name is the time the call started. Open the folder in Finder: in Terminal run `open ~/CallRecordings`.

Calls shorter than 8 seconds are thrown away, so misdials and unanswered calls do not pile up.

## Reading a transcript

A transcript looks like this:

```
# Call 2026-09-18 14:02

- duration: 4m 12s
- audio: 14-02-00.m4a
- outcome:
- who picked up:

## Transcript

[00:00] Haan ji, boliye.
[00:04] Rahul baat kar raha hoon Acme se...

## Notes

- what they said that wasn't in the flow:
```

Hindi comes out written in English letters (Roman Hinglish), the way people actually type it —
not in Devanagari, and not translated into English.

The empty fields are for you. After each call, fill in **outcome** and **who picked up**, and put
anything surprising under **Notes**. Takes twenty seconds and makes the file worth re-reading later.

Easiest way is in the app: pick the call, click an outcome button, type the name and your notes,
hit Save. It writes those three fields back into the same `.md` and never touches the transcript.

## Check that it is working

The app shows an orange banner at the top if the recorder is off or a permission is missing, with a
button that opens the right settings pane. In Terminal you can also run:

```
callrec status
```

It says whether it is watching, whether a call is being recorded right now, and how many
transcripts you have today.

## If a recording was interrupted

While a call is live, the audio is written to `<time>.far.caf` and `<time>.mic.caf`. If callrec is
killed or crashes mid-call, those files still play and convert in full (a WAV would read as empty).
`callrec doctor` lists them as "interrupted recording", and `callrec retranscribe <day>/<time>`
rebuilds the finished tracks and the m4a from them, then transcribes. The raw files are deleted only
after the converted audio has been checked against them.

## If a transcript is missing or failed

A call that records but fails to transcribe still gets a `.md`. It has an `- error:` line in the
header and the transcript says `_Transcription failed. Re-run: callrec retranscribe <id>_`.

To find every such recording, run:

```
callrec doctor
```

It lists each recording that has audio but no `.md`, or an error line, with the one-line fix. The
fix is usually `callrec retranscribe 2026-09-18/22-28-52`. Only the stretches with speech are
transcribed (voice-activity detection), and long calls go through in 10-minute pieces cut at pauses.
Voice-activity detection is only a gate: it decides which audio goes to the model, and nothing it
finds ever cuts, joins or rewrites the returned text. Each stretch of speech is transcribed on its
own and its lines are stamped at the start of that stretch. The transcript is the model's output
exactly as written.

### Flagged lines (nothing is ever deleted)

Filters mark, they never delete. A line a filter suspects stays in the `.md` with a marker at the
end of the line:

```
[00:05] **Me:** You cannot receive incoming calls.  <!-- flagged: bleed -->
```

The marker is two spaces, then `<!-- flagged: ` + comma-separated flags + ` -->`, always at the very
end of the line. Parse it with the regex `\s*<!-- flagged: ([a-z,]+) -->$`. The flags:

- `bleed`: the other person leaking into your microphone (same words at the same time on both
  tracks, or quieter on the mic than on the far side).
- `operator`: a carrier or network announcement (unreachable, switched off, spam warning, voicemail).
- `loop`: a suspected hallucination. Detected by repetition only: the same word 4+ times in a row, or
  the same line 3+ times in a row. Short real replies (haan, ji, hello, achha, theek hai) are never
  flagged for being short.

The app hides flagged lines by default. The toolbar toggle "Show filtered lines" shows them dimmed
and struck through. The toggle changes the display only, never the file. The only thing that can be
missing from a transcript is audio that was genuinely silent and so never sent to the model.

## If it isn't recording

1. Run `callrec status`. If it says "Not running", run `callrec install-agent`.
2. Check both permissions above are still on. This is the usual cause.
3. Restart it: `callrec uninstall-agent && callrec install-agent`
4. Look at the log: `open ~/.callrec/callrec.log` (one readable line per event, tagged
   `capture`, `transcribe`, `watcher` or `app`). The same lines are in the unified log:
   `/usr/bin/log show --last 1h --info --predicate 'subsystem == "com.blaxify.callrec"'`.
   Transcript text and phone numbers are never logged.
5. `callrec doctor` also lists any crash reports macOS wrote for callrec
   (`~/Library/Logs/DiagnosticReports`).

Timing for VAD, transcription and the speaker merge is recorded as signposts:
`/usr/bin/log stream --signpost --predicate 'subsystem == "com.blaxify.callrec"'`.

## Manual mode

If automatic recording misses a call, you can record by hand. Start before your calls:

```
callrec session start
```

Make your calls. When you are done:

```
callrec session stop
```

It splits the session into separate calls at the long silences and transcribes each one.

## Privacy

- Everything stays on this Mac. No account, no cloud, no uploads.
- `~/CallRecordings` and `~/.callrec` are owner-only (folders `0700`, files `0600`), and
  `~/CallRecordings` carries a `.metadata_never_index` file so Spotlight skips it. The recorder
  tightens anything older on every start and logs what it changed.
- The other person hears no beep and gets no notification.
- India is a single-party consent country: you may record a call you are part of. Other countries
  differ. If you are recording someone abroad, check the rules where they are.
- To delete a call, delete its two files from `~/CallRecordings/`. Nothing is kept elsewhere.

## Settings

`~/.callrec/config.json` holds the settings — where recordings go, the minimum call length, the
model folder. You do not need to touch it. Leave `language` at `en`: this model writes Roman Hinglish
only when told the language is English (`hi` gives garbage).

## Uninstall

```
callrec uninstall-agent
rm -rf ~/.callrec
```

Then drag **callrec** from Applications to the Bin.

Your recordings in `~/CallRecordings/` are left alone. Delete that folder too if you want them gone.

## For developers

Swift package. One dependency (WhisperKit, pinned exact). Targets: `CallrecCore` (shared), `callrec`
(CLI, does the recording), `CallrecApp` (SwiftUI app). `./scripts/make-app.sh` wraps the binaries
into `build/callrec.app` - no Xcode needed. Architecture and the build plan are in `docs/`.

### Who writes the `.md`

The daemon and the app both edit a call's `.md`. Ownership: the **daemon** owns the header metadata
(duration, audio, number, contact, company, owner, error) and the `## Transcript` section; the **app**
owns `- outcome:`, `- who picked up:` and the notes. All writes go through `MarkdownStore`: a
read-modify-write under `flock` on a hidden `.<name>.md.lock` file in the same folder, written
atomically (temp + rename), replacing only the writer's own fields. If you edit a transcript by hand,
text outside `## Transcript` survives a re-transcription.

### Running the tests (Command Line Tools only, no Xcode)

**Use `./scripts/test.sh`, not `swift test`.** With only the Command Line Tools there is no XCTest,
and `swift test` builds the test bundle then exits 0 without running anything (verified: a
deliberately failing test still reports success). `scripts/test.sh` builds the bundle and runs it
through the swift-testing entry point (`scripts/run-tests.swift`). It prints every failure and exits
non-zero on any failure, or if zero tests ran.

The test target links Testing.framework from the CLT. The paths are set in `Package.swift`:

- `-F /Library/Developer/CommandLineTools/Library/Developer/Frameworks` (Testing.framework)
- rpath `/Library/Developer/CommandLineTools/Library/Developer/usr/lib` (`lib_TestingInterop.dylib`)

With Xcode installed, plain `swift test` works too. `callrec selftest` is only a smoke check of an
installed binary; the real checks are in `Tests/callrecTests`.

Lint: `TOOLCHAIN_DIR=/Library/Developer/CommandLineTools swiftlint`.

MIT licensed.
