import { createHash, timingSafeEqual } from 'node:crypto';

// Accepts the key as ?key=... or "Authorization: Bearer ...".
export function providedKey(req) {
  const header = req.headers.authorization || '';
  if (header.startsWith('Bearer ')) return header.slice(7);
  return new URL(req.url, 'http://x').searchParams.get('key') || '';
}

export function keyMatches(candidate) {
  const expected = process.env.BRIEFING_KEY;
  if (!expected || !candidate) return false;
  const a = createHash('sha256').update(candidate).digest();
  const b = createHash('sha256').update(expected).digest();
  return timingSafeEqual(a, b);
}

// OAuth "state" value tied to the key, so only the key holder can finish sign-in.
export function oauthState() {
  return createHash('sha256').update(`oauth:${process.env.BRIEFING_KEY}`).digest('hex');
}

export function origin(req) {
  const proto = req.headers['x-forwarded-proto'] || 'https';
  return `${proto}://${req.headers['x-forwarded-host'] || req.headers.host}`;
}
