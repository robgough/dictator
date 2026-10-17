# iOS: `audio` background mode — App Review plan

The May 2026 build was rejected under guideline 2.5.4. It declared `audio` but
only recorded in the foreground, so the reviewer couldn't find anything that
used it. The mode is back now because it has two features that need it and that
a reviewer can see:

1. **A recording keeps going after you leave the app or lock the phone.** A Live
   Activity shows it on the Lock Screen and in the Dynamic Island, with Stop.
2. **The keyboard dictates in place.** After a dictation started from the
   Dictator keyboard, the app keeps its audio session running (with nothing
   being kept) for a time the user chooses (Settings → Keyboard → Keep the mic
   ready, off/5/15/60 minutes, default 15). The keyboard's Dictate then records
   without switching apps. The orange indicator and a Live Activity with an off
   button stay up for the whole time.

## For every submission that carries the mode

**App Review notes** (paste, then adjust):

> Dictator uses the audio background mode for continuous voice recording that
> the user starts and can see. (1) A dictation keeps recording when the user
> switches apps or locks the phone; a Live Activity shows it and has a Stop
> button. (2) The Dictator keyboard extension can't use the microphone itself,
> so after the user dictates from the keyboard, Dictator keeps its microphone
> session active in the background for a period the user sets (Settings →
> Keyboard → Keep the mic ready). During that time the keyboard's Dictate button
> records in place. The microphone indicator and a Live Activity are shown the
> whole time, and the Live Activity's microphone button or Settings turns it
> off. No audio is stored or sent anywhere; transcription runs on the device.
> A screen recording is attached.

**Screen recording to attach** (about 60 seconds, on a device):

1. Notes open, switch to the Dictator keyboard, tap Dictate. Dictator opens and
   starts listening.
2. Swipe back to Notes while still talking. Point out the Live Activity and
   orange dot, tap Stop in the keyboard, and the text appears in the note.
3. Tap Dictate again: it records in place with no app switch. Stop, and the
   text is inserted.
4. Lock the phone and show the Live Activity with Dictate and Stop. Unlock,
   tap "Turn off" in the keyboard, and the indicator goes out.

## Things to check before submitting

- Background inference: Parakeet runs on the ANE/CPU, which iOS allows in the
  background; the GPU isn't. Foundation Models may refuse or rate-limit a
  backgrounded app. Cleanup already fails soft, and Assist reports the error to
  the keyboard.
- Interruptions (a phone call, Siri) end the session and finish any capture in
  progress with what was said.
