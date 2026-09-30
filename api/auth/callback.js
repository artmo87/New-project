import { oauthState, origin } from '../../lib/auth.js';
import { exchangeCode } from '../../lib/google.js';

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

const page = (title, body) => `<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title>
<style>body{font:16px/1.5 -apple-system,system-ui,sans-serif;max-width:640px;margin:0 auto;padding:24px 16px}
code,textarea{font:14px ui-monospace,monospace}textarea{width:100%;height:120px;box-sizing:border-box}</style>
</head><body>${body}</body></html>`;

export default async function handler(req, res) {
  const params = new URL(req.url, 'http://x').searchParams;
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');

  if (params.get('state') !== oauthState()) {
    res.status(400).send(page('Error', '<h1>Invalid sign-in state</h1><p>Start again from /api/auth/start.</p>'));
    return;
  }
  if (params.get('error')) {
    res.status(400).send(page('Error', `<h1>Google said: ${esc(params.get('error'))}</h1>`));
    return;
  }

  try {
    const tokens = await exchangeCode(params.get('code'), `${origin(req)}/api/auth/callback`);
    if (!tokens.refresh_token) throw new Error('Google returned no refresh token. Remove the app at myaccount.google.com/permissions and try again.');
    res.status(200).send(page('Connected', `<h1>Google Calendar connected</h1>
<p>Copy this value into your Vercel project as the environment variable <code>GOOGLE_REFRESH_TOKEN</code>, then redeploy.</p>
<textarea readonly onclick="this.select()">${tokens.refresh_token}</textarea>
<p>Keep it private: it gives read access to your calendar.</p>`));
  } catch (err) {
    res.status(500).send(page('Error', `<h1>Sign-in failed</h1><p>${esc(err.message)}</p>`));
  }
}
