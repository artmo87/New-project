# Therapist Copilot

A private web app that **records your therapy session, transcribes it live,
writes a plain-language summary and gives you practical suggestions** for the
week and for your next session. It runs entirely in your browser: there are no
accounts, no servers behind it, no API keys and nothing to pay for.

Works in **Safari on iPhone** (add it to your Home Screen and it behaves like an
app), Safari on Mac, and Chrome or Edge on a computer.

---

## Start using it (5 minutes, free)

The app is a static website, so it only needs a place to be served over https.
The simplest is GitHub Pages, straight from this repository:

1. Open the repository on GitHub → **Settings** → **Pages** (left sidebar).
2. Under *Build and deployment* choose **Deploy from a branch**, pick the branch
   that holds this code (`main`, or `claude/therapist-copilot` until it is merged)
   and the folder **/ (root)**. Click **Save**.
3. Wait about a minute, then open
   `https://<your-github-username>.github.io/<repository-name>/`
   (for this repository: `https://artmo87.github.io/New-project/`).
4. On your iPhone, open that address in Safari, tap **Share → Add to Home Screen**.
   Open it from the Home Screen like any app.
5. Tap the big record button. Allow the microphone and speech recognition when
   asked. That is it.

If the repository is private, GitHub Pages needs a paid GitHub plan; the
alternative is any static host (Netlify, Cloudflare Pages, your own server) —
upload the files, done. On a computer you can also just open
`dist/therapist-copilot.html` directly from disk in Chrome.

> Microphone access in browsers requires https (or localhost). A plain `http://`
> address on a phone will not be able to record.

## What you get

| | |
| --- | --- |
| **Record** | Mood check-in before and after, live transcript while you talk, level meter, pause/resume, screen kept awake, audio saved in 10-second pieces so an interrupted session is recovered on the next launch |
| **Transcript** | Timestamped lines; tap a time to replay that moment; mark who spoke (Me / Therapist); edit any line; search |
| **Summary** | Overview, highlights, themes with counts, emotions, tone through the session (chart), key moments, thinking patterns with gentle reframes, commitments heard in the session |
| **Suggestions** | Practical, therapy-informed suggestions grouped as Reflect / Practice / Self-care / Bring to next session / Patterns across sessions, each with the reason it was picked; one tap to turn into a commitment or a question |
| **Prepare** | Open commitments across all sessions, questions to bring, recurring themes, mood before/after trend, journal, shareable prep sheet |
| **Privacy** | Everything stays in the browser's storage on your device. PIN lock. Export any session as Markdown, back up everything as JSON, restore, delete all |
| **Safety** | If crisis language is detected a calm resources card appears (988 in the US, Samaritans in the UK/IE, local emergency numbers elsewhere) |

## How the "in-house" parts work

- **Transcription** uses the speech recognition built into your browser and
  device (the Web Speech API). On iPhone that is the same Apple dictation service
  your keyboard uses; in Chrome it is Google's recognizer, or Chrome's on-device
  recognizer when the browser offers it (the app prefers on-device when it can).
  Nothing is sent to the authors of this app or to any other party.
- **Summary and suggestions** come from a rule-based engine inside the app
  (`js/insights.js` + `js/lexicon.js`): sentence and word analysis, a therapy
  lexicon of 18 themes, 20 emotions and 10 common thinking patterns, commitment
  detection, extractive highlights, tone trajectory, and a library of
  suggestions and questions. No model download, no network, instant.
- **On-device AI (optional)**: browsers that ship a built-in language model
  (Chrome on desktop) can rewrite the overview, highlights, suggestions and
  questions in more natural language. The model runs inside the browser.
  Settings shows whether your browser has it. Everything works without it.
- **Storage** is IndexedDB in your browser. Audio is kept as a compressed file
  (m4a on Safari, webm/opus on Chrome).
- **Offline**: a service worker caches the app, so it opens without a connection.

## Good to know

- **Keep the screen on while recording.** Browsers pause the microphone when the
  screen locks or the app goes to the background. The app requests a screen wake
  lock; just leave it in the foreground (turn the brightness down if you like).
- **Ask before recording.** Many places require everyone's consent to record a
  conversation. Tell your therapist and ask first.
- **Back up now and then.** Browsers can clear site data; Safari removes data from
  sites you have not opened in a while unless the app is on your Home Screen.
  Settings → *Back up everything* saves a JSON file.
- **If live transcription will not start on iPhone** while audio is being
  recorded, set Settings → *Recording mode* to **Transcript only**. Some iOS
  versions do not let a page use the microphone for recording and dictation at
  the same time.
- **Languages**: pick your language in Settings. The transcript follows it; the
  summary engine is tuned for English and will be rougher in other languages.
- **Not medical advice.** This is a reflection aid, not a substitute for your
  therapist.

## Browser support

| | Record audio | Live transcript | On-device AI |
| --- | --- | --- | --- |
| Safari, iPhone/iPad (iOS 16+) | yes | yes (Apple dictation) | no |
| Safari, Mac | yes | yes | no |
| Chrome / Edge, desktop | yes | yes (Google or on-device) | yes, when the browser has the model |
| Chrome, Android | yes | yes | no |
| Firefox | yes | no (no speech API) | no |

## Repository layout

```
index.html               app shell
assets/app.css           styles (light + dark, phone first)
assets/icons/            PWA icons
js/util.js               formatting, icons, helpers
js/lexicon.js            therapy lexicon (themes, emotions, patterns, suggestions, support resources)
js/insights.js           classic insight engine
js/ondevice-ai.js        optional Chrome built-in model enrichment
js/transcriber.js        Web Speech API wrapper with run chaining and timestamps
js/recorder.js           MediaRecorder + level meter + wake lock + crash-safe chunks
js/db.js                 IndexedDB storage
js/exporter.js           Markdown, backup/restore, download, share
js/app.js                screens, routing, flows
manifest.webmanifest     PWA manifest
sw.js                    offline cache
scripts/build-single-file.py   bundles everything into dist/therapist-copilot.html
dist/therapist-copilot.html    single-file build (open directly in a desktop browser)
ios-native/              an unfinished native Swift prototype, kept for reference
```

No build step and no dependencies. Edit the files and reload. To refresh the
single-file build: `python3 scripts/build-single-file.py`.
