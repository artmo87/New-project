import { keyMatches, oauthState, origin, providedKey } from '../../lib/auth.js';
import { authUrl } from '../../lib/google.js';

export default function handler(req, res) {
  if (!keyMatches(providedKey(req))) {
    res.status(401).send('Add ?key=YOUR_BRIEFING_KEY to the URL.');
    return;
  }
  res.redirect(302, authUrl(`${origin(req)}/api/auth/callback`, oauthState()));
}
