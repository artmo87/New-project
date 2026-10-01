# Native iOS prototype (unfinished)

This folder holds an earlier, **incomplete** native SwiftUI version of Therapist
Copilot. Work on it stopped when the project switched to the browser app that
lives at the root of this repository.

State of this prototype:

- Written: models, all services (audio recorder, on-device speech transcription
  with segment rotation, classic insight engine, Foundation Models enrichment,
  storage, export, app lock), app entry, Home, Recording flow, Summary tab,
  audio player bar, shared components.
- **Missing** (never written): `SessionListView`, `SessionDetailView`,
  `TranscriptTab`, `SuggestionsTab`, `NotesTab`, `PrepareView`, `SettingsView`.
- Never compiled in Xcode. Treat it as a design reference, not as a working app.

`docs/ARCHITECTURE.md` is the contract the files follow, if you ever want to
finish it.
