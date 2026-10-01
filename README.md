# Therapist Copilot (iPhone)

A private, fully on-device iPhone app that **records your therapy session,
transcribes it, writes a session summary, and gives you practical suggestions**
for the week and for your next session.

- **No servers, no accounts, no API keys, no internet.** The app contains no
  networking code. Audio, transcripts, summaries and notes live only in the
  app's own folder on your iPhone (included in your normal iPhone backup).
- **Transcription** uses Apple's Speech framework in on-device mode.
- **Summary & suggestions** come from two in-house engines:
  - *Classic analysis* (always available): a rule-based language engine that finds
    themes, emotions, key moments, thinking patterns, commitments and mood trend,
    then picks suggestions from a built-in library of therapy-informed skills.
  - *On-device AI* (optional): on iPhones that support Apple Intelligence
    (iPhone 15 Pro and newer, iOS 26+), Apple's on-device foundation model rewrites
    the overview, highlights, suggestions and questions. It falls back to Classic
    automatically. Nothing is sent anywhere.

> Not medical advice. This app helps you remember and reflect; it does not
> replace your therapist. Recording other people needs their consent in many
> places. Tell your therapist you are recording and ask first.

## What's inside

| Area | What you get |
| --- | --- |
| Record | Pre-session mood check-in, live transcript, level meter, pause/resume, keeps recording with the screen locked, phone-call interruption handling |
| Transcript | Timestamped segments, tap to play that moment, speaker tags (Me / Therapist), edit text, search |
| Summary | Overview, highlights, themes, emotions, mood trajectory chart, key moments, thinking patterns with gentle reframes, detected commitments |
| Suggestions | Reflection prompts, practices to try, self-care, things to bring to the next session, recurring-pattern notes across sessions |
| Prepare | Open commitments across sessions, questions to bring, recurring themes, mood trend chart, journal, shareable prep sheet |
| Privacy | Face ID / passcode lock, delete audio or whole sessions, export everything as Markdown, delete all data |
| Safety | If crisis language is detected, a calm resources card is shown (988 in the US, Samaritans in the UK/IE, local emergency numbers elsewhere) |

## Install on your iPhone (about 10 minutes, free)

You need a Mac with Xcode (free from the Mac App Store, version 16 or newer;
Xcode 26 recommended so the On-device AI engine compiles too) and a Lightning/USB-C cable.
No paid developer account is needed.

1. **Get the project.** Download this repository as a ZIP (green *Code* button →
   *Download ZIP*, or the `TherapistCopilot.zip` attached to the session) and unzip it.
2. **Open** `TherapistCopilot.xcodeproj` in Xcode.
3. **Sign it.** Click the blue project icon at the top of the left sidebar →
   target *TherapistCopilot* → *Signing & Capabilities*:
   - tick *Automatically manage signing*,
   - *Team*: choose your Apple ID (Xcode → Settings → Accounts → “+” to add it; a
     free Apple ID works),
   - if Xcode complains the bundle identifier is taken, change
     `com.artmo87.TherapistCopilot` to anything unique, e.g. `com.yourname.TherapistCopilot`.
4. **Connect your iPhone** with the cable, unlock it, tap *Trust* if asked.
   On the iPhone enable Developer Mode if prompted: Settings → Privacy & Security →
   Developer Mode → on (the phone restarts).
5. **Choose your iPhone** in the device menu at the top of Xcode (next to the
   scheme name) and press **Run** (▶ or ⌘R). The first build takes a minute.
6. **Trust the app on the iPhone** the first time: Settings → General →
   VPN & Device Management → your Apple ID → *Trust*. Then open *Therapist Copilot*.
7. On first launch, allow **Microphone** and **Speech Recognition**.
   Transcription runs on the device; if iOS needs to download the offline
   language model it does so once in the background (Settings → General →
   Keyboard → Dictation also triggers it).

With a free Apple ID the install stays valid for 7 days; plug in and press Run
again to refresh it. With a paid developer account ($99/yr) it lasts a year and
you can use TestFlight instead of the cable.

### Troubleshooting

- *"Signing for TherapistCopilot requires a development team"* → step 3.
- *"Untrusted Developer"* on the phone → step 6.
- *Build errors mentioning `FoundationModels`* → you are on Xcode 16. Either update
  to Xcode 26 or delete `TherapistCopilot/Services/FoundationModelsInsightEngine.swift`
  and replace the body of `InsightsService.generate` so it returns the Classic result
  (the file has a comment showing the two lines to keep). Everything else works.
- *Live transcript stays empty* → check Settings → Transcription language. Only
  some languages support on-device recognition; the Settings screen marks the ones
  that need Apple's servers. Turning *On-device only* off sends audio to Apple's
  speech servers (still no third-party service) — your choice.
- *Recording stopped when the phone locked* → make sure you ran the app from this
  project (the `audio` background mode is in `Info.plist`).

## How it works (technical)

```
Microphone ──AVAudioEngine tap──▶ AAC .m4a file (Documents/Recordings)
                     │
                     └──▶ SFSpeechRecognizer (on-device, 30–55 s rotating segments)
                                  │
                                  ▼
                        TranscriptSegment[] (timestamps)
                                  │
            ┌─────────────────────┴───────────────────────┐
            ▼                                             ▼
 HeuristicInsightEngine (NaturalLanguage +      FoundationModelsInsightEngine
 TherapyLexicon: themes, emotions, CBT          (iOS 26, Apple Intelligence,
 patterns, commitments, key moments,            optional, falls back)
 extractive highlights, mood trajectory)
            └─────────────────────┬───────────────────────┘
                                  ▼
                 SessionInsights → JSON store (Documents/therapist-copilot-store.json)
```

- Swift 5 / SwiftUI, iOS 17+, iPhone and iPad. No third-party dependencies.
- Project layout and every public API are documented in `docs/ARCHITECTURE.md`.
- Files are written with iOS *complete file protection*; the store is a single
  atomic JSON file. Deleting a session deletes its audio.

## Repository layout

```
TherapistCopilot.xcodeproj/   Xcode project (file-system synchronized; just add files to the folder)
TherapistCopilot/             App sources, Info.plist, Assets
  Models/                     TherapySession, SessionInsights
  Services/                   Recording, transcription, insights engines, store, export, lock
  Views/                      SwiftUI screens
docs/ARCHITECTURE.md          Contract every file follows
```
