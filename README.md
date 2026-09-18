# callrec

Records your iPhone calls when you take them on your Mac, and writes out a transcript you can read.

Everything happens on this Mac. Nothing is uploaded anywhere. The other person is not told.

## Install

Open Terminal (press Cmd+Space, type "Terminal", hit Enter), paste this line, hit Enter:

```
curl -fsSL https://raw.githubusercontent.com/DDOS44/callrec/main/scripts/install.sh | bash
```

It takes about ten minutes, mostly downloading the transcription model (1.6 GB, one time).
You may be asked for your Mac password once.

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

## Your first call

Take a call on your Mac the way you normally do (iPhone calls ring on the Mac when both are on
the same Apple ID). Talk. Hang up.

About a minute later two files appear in **`~/CallRecordings/`**, in a folder for today's date:

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
[00:04] Devansh baat kar raha hoon Blaxify se...

## Notes

- what they said that wasn't in the flow:
```

Hindi comes out written in English letters (Roman Hinglish), the way people actually type it —
not in Devanagari, and not translated into English.

The empty fields are for you. After each call, fill in **outcome** and **who picked up**, and put
anything surprising under **Notes**. Takes twenty seconds and makes the file worth re-reading later.

## Check that it is working

```
callrec status
```

It says whether it is watching, whether a call is being recorded right now, and how many
transcripts you have today.

## If it isn't recording

1. Run `callrec status`. If it says "Not running", run `callrec install-agent`.
2. Check both permissions above are still on. This is the usual cause.
3. Restart it: `callrec uninstall-agent && callrec install-agent`
4. Look at the log: `open ~/.callrec/callrec.log`

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
- The other person hears no beep and gets no notification.
- India is a single-party consent country: you may record a call you are part of. Other countries
  differ. If you are recording someone abroad, check the rules where they are.
- To delete a call, delete its two files from `~/CallRecordings/`. Nothing is kept elsewhere.

## Settings

`~/.callrec/config.json` holds the settings — where recordings go, the language, the minimum call
length. You do not need to touch it.

## Uninstall

```
callrec uninstall-agent
rm -rf ~/.callrec
```

Your recordings in `~/CallRecordings/` are left alone. Delete that folder too if you want them gone.

## For developers

Swift package, no dependencies. `swift build -c release`, then `.build/release/callrec selftest`
runs the pure-logic checks. Architecture and the build plan are in `docs/`.

MIT licensed.
