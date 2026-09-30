import { keyMatches, providedKey } from '../lib/auth.js';
import { briefingText, buildWeek, weekRange } from '../lib/briefing.js';
import { fetchCalendar } from '../lib/google.js';

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (!keyMatches(providedKey(req))) {
    res.status(401).json({ error: 'Wrong or missing key' });
    return;
  }

  try {
    const now = new Date();
    const { timeZone, events } = await fetchCalendar((tz) => weekRange(now, tz));
    const range = weekRange(now, timeZone);
    const days = buildWeek(events, range, timeZone);
    const text = briefingText(days, range.today);

    const format = new URL(req.url, 'http://x').searchParams.get('format');
    if (format === 'text') {
      res.setHeader('Content-Type', 'text/plain; charset=utf-8');
      res.status(200).send(text);
      return;
    }
    res.status(200).json({ timeZone, generatedAt: now.toISOString(), text, days });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err.message });
  }
}
