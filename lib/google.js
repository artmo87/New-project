const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const CALENDAR_API = 'https://www.googleapis.com/calendar/v3';

export const SCOPES = ['https://www.googleapis.com/auth/calendar.readonly'];

function requireEnv(name) {
  const v = process.env[name];
  if (!v) throw new Error(`Missing environment variable ${name}`);
  return v;
}

async function tokenRequest(params) {
  const res = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: requireEnv('GOOGLE_CLIENT_ID'),
      client_secret: requireEnv('GOOGLE_CLIENT_SECRET'),
      ...params,
    }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(`Google token error: ${body.error_description || body.error}`);
  return body;
}

export function authUrl(redirectUri, state) {
  const params = new URLSearchParams({
    client_id: requireEnv('GOOGLE_CLIENT_ID'),
    redirect_uri: redirectUri,
    response_type: 'code',
    scope: SCOPES.join(' '),
    access_type: 'offline',
    prompt: 'consent',
    state,
  });
  return `https://accounts.google.com/o/oauth2/v2/auth?${params}`;
}

export function exchangeCode(code, redirectUri) {
  return tokenRequest({ code, redirect_uri: redirectUri, grant_type: 'authorization_code' });
}

async function accessToken() {
  const body = await tokenRequest({
    refresh_token: requireEnv('GOOGLE_REFRESH_TOKEN'),
    grant_type: 'refresh_token',
  });
  return body.access_token;
}

async function api(token, path, params = {}) {
  const query = new URLSearchParams(params).toString();
  const res = await fetch(`${CALENDAR_API}${path}${query ? `?${query}` : ''}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  const body = await res.json();
  if (!res.ok) throw new Error(`Calendar API error: ${body.error?.message || res.status}`);
  return body;
}

export async function fetchCalendar(range) {
  const token = await accessToken();
  const calendarIds = (process.env.CALENDAR_IDS || 'primary')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);

  const timeZone =
    process.env.TIME_ZONE || (await api(token, '/calendars/primary')).timeZone || 'UTC';

  const { timeMin, timeMax } = range(timeZone);
  const events = [];
  for (const id of calendarIds) {
    let pageToken;
    do {
      const page = await api(token, `/calendars/${encodeURIComponent(id)}/events`, {
        timeMin: timeMin.toISOString(),
        timeMax: timeMax.toISOString(),
        singleEvents: 'true',
        orderBy: 'startTime',
        maxResults: '250',
        ...(pageToken ? { pageToken } : {}),
      });
      events.push(...(page.items || []));
      pageToken = page.nextPageToken;
    } while (pageToken);
  }
  return { timeZone, events };
}
