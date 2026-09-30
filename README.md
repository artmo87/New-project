# Week Briefing

A spoken morning briefing of your Google Calendar week, built for iPhone.

- **Web app** (Safari → Add to Home Screen): see today and the rest of the week, tap to hear it.
- **7:30 AM voice briefing**: an iOS Shortcuts automation fetches the briefing and reads it aloud, no tap needed.
- **Server** (free Vercel hosting): reads your calendar with read-only access. No database; nothing is stored.

Example of what it says:

> Good morning. Today is Wednesday, September 30. You have 2 events today. At 9:00 AM: Standup. At 2:00 PM: Dentist, at Main St Clinic. Coming up this week. Friday: 6:00 PM, Gym. Have a great day.

## Why a Shortcut does the 7:30 voice

iOS does not let a web page speak on its own; speech needs a tap. A Shortcuts automation can run at a set time without asking and use **Speak Text**, so it handles the alarm-style briefing. The web app is for looking at your week and replaying it.

## Setup (about 20 minutes, once)

You need: a GitHub account (this repo), a free [Vercel](https://vercel.com) account, and your Google account.

### 1. Deploy to Vercel

1. In Vercel: **Add New → Project**, import this GitHub repo. Framework preset: **Other**. Deploy.
2. Note your production URL, e.g. `https://week-briefing.vercel.app`.
3. **Settings → Environment Variables**, add `BRIEFING_KEY` = a long random password you make up. This protects your briefing.

### 2. Create Google sign-in credentials

In [Google Cloud Console](https://console.cloud.google.com):

1. Create a project (any name).
2. **APIs & Services → Library** → enable **Google Calendar API**.
3. **APIs & Services → OAuth consent screen** (Google Auth Platform):
   - User type **External**, fill in app name and your email.
   - **Data access / Scopes**: add `https://www.googleapis.com/auth/calendar.readonly`.
   - **Audience**: add your Gmail address as a test user, then click **Publish app** (status **In production**).
     *Important:* in "Testing" status Google expires your sign-in every 7 days. Publishing for personal use does not require verification; you'll just see a "Google hasn't verified this app" warning when you sign in, which is expected for your own app. Click **Advanced → Go to (app name)**.
4. **Credentials → Create credentials → OAuth client ID**:
   - Type **Web application**.
   - Authorized redirect URI: `https://YOUR-APP.vercel.app/api/auth/callback`
5. Copy the **Client ID** and **Client secret** into Vercel as `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`.
6. In Vercel, **Deployments → ⋯ → Redeploy** so the new variables load.

### 3. Connect your calendar

1. Open `https://YOUR-APP.vercel.app/api/auth/start?key=YOUR_BRIEFING_KEY` and sign in with Google.
2. The page shows a refresh token. Add it to Vercel as `GOOGLE_REFRESH_TOKEN`, then redeploy again.
3. Test: open `https://YOUR-APP.vercel.app/api/briefing?format=text&key=YOUR_BRIEFING_KEY`. You should see your briefing text.

### 4. Install on iPhone

1. Open `https://YOUR-APP.vercel.app` in Safari.
2. **Share → Add to Home Screen**.
3. Open it from the home screen and enter your `BRIEFING_KEY`.

### 5. Set up the 7:30 AM voice briefing

In the **Shortcuts** app:

1. **Automation → + → Time of Day** → 7:30 AM, **Daily**.
2. Choose **Run Immediately** (turn off "Notify When Run" if you like).
3. Add actions:
   1. **Get Contents of URL**: paste the Shortcut URL from the app's **Settings** section
      (`https://YOUR-APP.vercel.app/api/briefing?format=text&key=...`).
   2. **Speak Text**: input = *Contents of URL*. Pick a voice and rate if you want.
4. Tap the automation's play button once to test.

Notes: the phone must not be in Silent mode for you to hear it, and the volume used is the media volume. Behavior while the phone is locked can vary by iOS version; test it once at a near time before relying on it.

## Optional settings

| Variable | Default | Purpose |
|---|---|---|
| `CALENDAR_IDS` | `primary` | Comma-separated calendar IDs to include (find them in Google Calendar → Settings → your calendar → *Calendar ID*). |
| `TIME_ZONE` | your primary calendar's zone | IANA zone, e.g. `Europe/London`. |

## How "this week" works

Today through Sunday. On Sundays it covers the coming week too. Cancelled events and events you declined are skipped. All-day events appear on each day they cover.

## Development

```bash
npm test            # unit tests (Node 18+), no dependencies
npx vercel dev      # run locally; needs the env vars in .env
```

API:

- `GET /api/briefing` → JSON `{ timeZone, generatedAt, text, days[] }`
- `GET /api/briefing?format=text` → plain text to speak
- Auth: `Authorization: Bearer <BRIEFING_KEY>` or `?key=<BRIEFING_KEY>`

## Privacy

- Calendar access is read-only.
- Your refresh token lives only in Vercel environment variables.
- Anyone with your `BRIEFING_KEY` can read your briefing. If it leaks, change it in Vercel and update the Shortcut.

## Roadmap ideas

- Gmail: read unread important emails in the briefing.
- To-dos: a simple task list that's included in the briefing.
- Claude-written summary with priorities.
