/* Therapist Copilot — application: state, routing, screens and flows. Vanilla JS, no build step. */
const App = (() => {
  const DEFAULTS = {
    language: (navigator.language && LANGUAGES.includes(navigator.language)) ? navigator.language : 'en-US',
    recordingMode: 'both',           // both | transcript | audio
    preferLocalRecognition: true,     // Chrome: keep recognition on the device when the browser offers it
    enginePreference: 'automatic',    // automatic | classic
    therapistName: '',
    hasSeenOnboarding: false,
    pinHash: null,
    pinLength: 0
  };
  const S = {
    sessions: [], journal: [], settings: { ...DEFAULTS },
    route: { name: 'home' }, ui: { tab: 'summary', search: '', menu: false, sheet: null, form: {}, confirm: null, toast: null, editingSegment: null, aiStatus: null, localStatus: null, storage: null },
    rec: null, recUI: null, pending: null, processing: null,
    player: { sessionId: null, url: null, rate: 1, current: 0, failed: false },
    locked: false, pinEntry: '', pinSetup: null, draftSaver: null, ready: false
  };
  const $ = (sel) => document.querySelector(sel);
  const app = () => document.getElementById('app');

  // ---------- persistence helpers ----------
  async function saveSettings() { try { await DB.saveSettings(S.settings); } catch (e) { toast('Settings could not be saved in this browser.'); } }
  function getSession(id) { return S.sessions.find((s) => s.id === id) || null; }
  async function persistSession(s) { try { await DB.saveSession(s); } catch (e) { toast('Could not save to this browser\'s storage.'); } }
  async function updateSession(id, fn) {
    const s = getSession(id); if (!s) return null;
    fn(s); s.updatedAt = new Date().toISOString();
    await persistSession(s);
    return s;
  }
  function sortSessions() { S.sessions.sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt)); }

  // ---------- routing ----------
  function routeToHash(r) {
    if (r.name === 'session') return '#s-' + r.id;
    return '#' + (r.name || 'home');
  }
  function hashToRoute(h) {
    h = (h || '').replace(/^#/, '');
    if (!h) return { name: 'home' };
    if (h.startsWith('s-')) return { name: 'session', id: h.slice(2) };
    if (['home', 'sessions', 'prepare', 'settings', 'how', 'notes'].includes(h)) return { name: h };
    return { name: 'home' };
  }
  function navigate(route, replace) {
    S.ui.menu = false; S.ui.confirm = null; S.ui.sheet = null;
    if (route.name !== 'session') { releasePlayer(); S.ui.tab = 'summary'; S.ui.editingSegment = null; }
    S.route = route;
    const h = routeToHash(route);
    if (location.hash !== h) { if (replace) history.replaceState(null, '', h); else location.hash = h; }
    render();
    window.scrollTo(0, 0);
  }

  // ---------- toast ----------
  let toastTimer = null;
  function toast(msg) {
    S.ui.toast = msg;
    let el = document.getElementById('toast');
    if (!el) { el = document.createElement('div'); el.id = 'toast'; el.className = 'toast'; el.setAttribute('role', 'status'); document.body.appendChild(el); }
    el.textContent = msg; el.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { el.hidden = true; S.ui.toast = null; }, 3600);
  }

  // ---------- small view helpers ----------
  function icon(name, cls) { return '<span class="ico ' + (cls || '') + '" style="display:inline-flex;width:1.1em;height:1.1em;vertical-align:-0.15em">' + Icons[name] + '</span>'; }
  function chip(text, cls) { return '<span class="chip ' + (cls || '') + '">' + esc(text) + '</span>'; }
  function moodPicker(name, value, title) {
    let html = '<div class="mood"><div class="between"><span class="eyebrow">' + esc(title) + '</span><span class="mood-readout"><span class="emoji">' + MoodScale.emoji(value) + '</span><span class="small">' + esc(MoodScale.label(value)) + (value ? ' · ' + value + '/10' : '') + '</span></span></div><div class="mood-scale" role="radiogroup" aria-label="' + esc(title) + '">';
    for (let i = 1; i <= 10; i++) html += '<button type="button" role="radio" aria-pressed="' + (value === i) + '" aria-checked="' + (value === i) + '" data-action="mood" data-name="' + name + '" data-value="' + i + '">' + i + '</button>';
    html += '</div><div class="between tiny muted"><span>Very low</span><span>Great</span></div></div>';
    return html;
  }
  function sparkline(values, opts) {
    opts = opts || {};
    const w = 320, h = opts.height || 100, pad = 10, min = opts.min != null ? opts.min : Math.min(...values), max = opts.max != null ? opts.max : Math.max(...values);
    const n = values.length;
    if (n < 2) return '';
    const x = (i) => pad + (i / (n - 1)) * (w - 2 * pad);
    const y = (v) => pad + (1 - (v - min) / ((max - min) || 1)) * (h - 2 * pad);
    const pts = values.map((v, i) => x(i) + ',' + y(v));
    let svg = '<svg class="chart" viewBox="0 0 ' + w + ' ' + h + '" role="img" aria-label="' + esc(opts.label || 'chart') + '">';
    svg += '<line class="grid" x1="' + pad + '" x2="' + (w - pad) + '" y1="' + y(max) + '" y2="' + y(max) + '"/>';
    svg += '<line class="grid" x1="' + pad + '" x2="' + (w - pad) + '" y1="' + y(min) + '" y2="' + y(min) + '"/>';
    if (opts.zero != null && opts.zero >= min && opts.zero <= max) svg += '<line class="zero" x1="' + pad + '" x2="' + (w - pad) + '" y1="' + y(opts.zero) + '" y2="' + y(opts.zero) + '"/>';
    if (opts.area) svg += '<path class="area" d="M' + x(0) + ',' + y(opts.zero != null ? opts.zero : min) + ' L' + pts.join(' L') + ' L' + x(n - 1) + ',' + y(opts.zero != null ? opts.zero : min) + ' Z"/>';
    svg += '<polyline class="line" points="' + pts.join(' ') + '"/>';
    values.forEach((v, i) => { svg += '<circle class="dot" cx="' + x(i) + '" cy="' + y(v) + '" r="4"><title>' + esc(opts.format ? opts.format(v, i) : String(v)) + '</title></circle>'; });
    if (opts.startLabel) svg += '<text x="' + pad + '" y="' + (h - 1) + '">' + esc(opts.startLabel) + '</text>';
    if (opts.endLabel) svg += '<text x="' + (w - pad) + '" y="' + (h - 1) + '" text-anchor="end">' + esc(opts.endLabel) + '</text>';
    svg += '</svg>';
    return svg;
  }
  function moodTrendChart(sessions) {
    const rows = sessions.filter((s) => s.moodBefore || s.moodAfter).slice(0, 12).reverse();
    if (rows.length < 2) return '';
    const w = 320, h = 130, pad = 12;
    const x = (i) => pad + (i / (rows.length - 1)) * (w - 2 * pad);
    const y = (v) => pad + (1 - (v - 1) / 9) * (h - 2 * pad - 12);
    let svg = '<svg class="chart" viewBox="0 0 ' + w + ' ' + h + '" role="img" aria-label="Mood before and after each session">';
    [1, 5, 10].forEach((g) => { svg += '<line class="grid" x1="' + pad + '" x2="' + (w - pad) + '" y1="' + y(g) + '" y2="' + y(g) + '"/><text x="0" y="' + (y(g) + 4) + '">' + g + '</text>'; });
    const before = rows.map((s, i) => (s.moodBefore ? x(i) + ',' + y(s.moodBefore) : null)).filter(Boolean);
    const after = rows.map((s, i) => (s.moodAfter ? x(i) + ',' + y(s.moodAfter) : null)).filter(Boolean);
    if (before.length > 1) svg += '<polyline class="line before" points="' + before.join(' ') + '"/>';
    if (after.length > 1) svg += '<polyline class="line" points="' + after.join(' ') + '"/>';
    rows.forEach((s, i) => {
      if (s.moodBefore) svg += '<circle class="dot before" cx="' + x(i) + '" cy="' + y(s.moodBefore) + '" r="4"><title>' + esc(Fmt.shortDate(s.createdAt) + ' · before ' + s.moodBefore + '/10') + '</title></circle>';
      if (s.moodAfter) svg += '<circle class="dot" cx="' + x(i) + '" cy="' + y(s.moodAfter) + '" r="4"><title>' + esc(Fmt.shortDate(s.createdAt) + ' · after ' + s.moodAfter + '/10') + '</title></circle>';
    });
    svg += '<text x="' + pad + '" y="' + (h - 1) + '">' + esc(Fmt.shortDate(rows[0].createdAt)) + '</text><text x="' + (w - pad) + '" y="' + (h - 1) + '" text-anchor="end">' + esc(Fmt.shortDate(rows[rows.length - 1].createdAt)) + '</text></svg>';
    svg += '<div class="legend"><span><i class="before"></i>Before</span><span><i></i>After</span></div>';
    return svg;
  }
  function sessionTitle(s) { return Exporter.title(s); }
  function topThemes(s, n) { return s.insights && s.insights.themes ? s.insights.themes.slice(0, n) : []; }
  function openItems() {
    const out = [];
    for (const s of S.sessions) for (const it of (s.actionItems || [])) if (!it.isDone) out.push({ sessionId: s.id, sessionTitle: sessionTitle(s), sessionDate: s.createdAt, item: it });
    return out;
  }
  function pendingQuestions() {
    const out = []; const seen = new Set();
    for (const s of S.sessions) for (const q of (s.nextSessionQuestions || [])) { const k = q.trim().toLowerCase(); if (k && !seen.has(k)) { seen.add(k); out.push({ sessionId: s.id, sessionTitle: sessionTitle(s), question: q }); } }
    return out;
  }
  function recurringThemes() {
    const counts = new Map();
    for (const s of S.sessions) { const names = new Set(topThemes(s, 99).map((t) => t.name)); for (const n of names) counts.set(n, (counts.get(n) || 0) + 1); }
    return Array.from(counts, ([name, sessionCount]) => ({ name, sessionCount })).filter((t) => t.sessionCount >= 2).sort((a, b) => b.sessionCount - a.sessionCount);
  }
  function supportCard() {
    return '<div class="card" style="border-color:var(--accent)"><div class="card-title">' + icon('heart') + '<h3>You deserve support</h3></div><p class="small">Some of what was said sounds heavy. If things feel unsafe, please reach out — you do not have to carry it alone.</p><div class="stack">' +
      Lexicon.supportResources.map((r) => '<div><b>' + esc(r.title) + '</b><div class="small muted">' + esc(r.detail) + '</div></div>').join('') + '</div></div>';
  }
  function emptyState(text, sub) { return '<div class="empty">' + Icons.wave + '<p>' + esc(text) + '</p>' + (sub ? '<p class="small">' + esc(sub) + '</p>' : '') + '</div>'; }

  // ---------- screens ----------
  function topbar(title, opts) {
    opts = opts || {};
    return '<header class="topbar">' + (opts.back ? '<button class="back" data-action="back" aria-label="Back">' + Icons.back + '<span>' + esc(opts.back) + '</span></button>' : '') + '<h1>' + esc(title) + '</h1>' + (opts.right || '') + '</header>';
  }
  function tabbar() {
    if (['onboarding'].includes(S.route.name)) return '';
    const tabs = [['home', 'Home', 'home'], ['sessions', 'Sessions', 'list'], ['prepare', 'Prepare', 'checklist'], ['settings', 'Settings', 'gear']];
    const current = S.route.name === 'session' ? 'sessions' : (['how', 'notes'].includes(S.route.name) ? 'settings' : S.route.name);
    return '<nav class="tabbar" aria-label="Main">' + tabs.map(([r, label, ic]) => '<button data-action="nav" data-route="' + r + '" ' + (current === r ? 'aria-current="page"' : '') + '>' + Icons[ic] + '<span>' + label + '</span></button>').join('') + '</nav>';
  }

  function onboardingHTML() {
    return '<main class="screen"><div class="onboard">' +
      '<div class="glyph">' + Icons.mic + '</div><h1>Therapist Copilot</h1>' +
      '<p class="read">Record your therapy session, read it back as a transcript, and get a plain-language summary with practical suggestions for the week.</p>' +
      '<div class="card"><div class="card-title">' + icon('shield') + '<h3>Private by design</h3></div><p class="small">Everything stays in this browser on this device: the recording, the transcript, the notes. There are no accounts and no servers behind this app. Transcription uses your device\'s built-in speech recognition' + (/iPhone|iPad|Macintosh/.test(navigator.userAgent) ? ' (on Apple devices that is the same dictation service as your keyboard)' : '') + '.</p></div>' +
      '<div class="card"><div class="card-title">' + icon('info') + '<h3>Two things to know</h3></div><p class="small"><b>Ask before you record.</b> In many places recording a conversation needs everyone\'s consent. Tell your therapist and ask first.</p><p class="small"><b>Keep the screen on while recording.</b> Browsers pause audio when the screen locks or the app goes to the background. The app keeps the screen awake for you; just leave it open.</p><p class="small"><b>Not medical advice.</b> This is a reflection aid. It does not replace your therapist.</p></div>' +
      '<button class="btn primary block" data-action="finishOnboarding">I understand, let\'s start</button>' +
      '</div></main>';
  }

  function homeHTML() {
    const hour = new Date().getHours();
    const greet = hour < 12 ? 'Good morning' : (hour < 18 ? 'Good afternoon' : 'Good evening');
    const last = S.sessions[0];
    const items = openItems().slice(0, 3);
    const qs = pendingQuestions().slice(0, 2);
    const moods = S.sessions.filter((s) => s.moodAfter).slice(0, 10).reverse();
    let html = '<main class="screen">' + topbar(greet) + '<p class="muted" style="margin-top:-10px">' + esc(Fmt.weekday(new Date())) + '</p>';
    html += '<div class="hero"><button class="rec-btn" data-action="openPreSession" aria-label="Start a session">' + Icons.mic + '</button><div><b>Start a session</b><div class="small muted">Records, transcribes and summarizes on this device</div></div></div>';
    if (!S.sessions.length) {
      html += '<div class="card plain"><h3>After your first session you will see</h3><ul class="bullets small"><li>A transcript you can search, edit and replay.</li><li>A summary with themes, emotions, key moments and thinking patterns.</li><li>Suggestions for the week and questions to bring next time.</li></ul></div>';
    } else {
      html += '<div class="card"><div class="card-title">' + icon('wave') + '<h3>Last session</h3><span class="small muted">' + esc(Fmt.relative(last.createdAt)) + '</span></div>' +
        '<button class="row" data-action="openSession" data-id="' + last.id + '" style="padding:0"><div class="grow"><div class="title">' + esc(sessionTitle(last)) + '</div><div class="sub">' + esc(Fmt.durationWords(last.duration || 0)) + (last.moodBefore || last.moodAfter ? ' · ' + MoodScale.emoji(last.moodBefore) + ' → ' + MoodScale.emoji(last.moodAfter) : '') + (last.actionItems && last.actionItems.some((a) => !a.isDone) ? ' · ' + Fmt.plural(last.actionItems.filter((a) => !a.isDone).length, 'open item') : '') + '</div></div><span class="chev">' + Icons.chevron + '</span></button>' +
        (topThemes(last, 3).length ? '<div class="chips">' + topThemes(last, 3).map((t) => chip(t.name)).join('') + '</div>' : '') + '</div>';
      html += '<div class="stat-row"><div class="stat"><b>' + S.sessions.length + '</b><span>sessions</span></div><div class="stat"><b>' + openItems().length + '</b><span>open commitments</span></div><div class="stat"><b>' + Fmt.durationWords(S.sessions.reduce((a, s) => a + (s.duration || 0), 0)).replace(' min', 'm').replace(' h ', 'h ') + '</b><span>recorded</span></div></div>';
    }
    if (items.length || qs.length) {
      html += '<div class="card"><div class="card-title">' + icon('checklist') + '<h3>Up next</h3><button class="btn ghost small" data-action="nav" data-route="prepare">See all</button></div>';
      html += items.map((o) => '<div class="check"><button class="box" role="checkbox" aria-checked="false" data-action="toggleItem" data-session="' + o.sessionId + '" data-item="' + o.item.id + '" aria-label="Mark done"></button><div class="txt">' + esc(o.item.text) + '<div class="tiny muted">' + esc(o.sessionTitle) + '</div></div></div>').join('');
      html += qs.map((q) => '<div class="check"><span style="color:var(--accent);flex:none;margin-top:2px">' + icon('bubble') + '</span><div class="txt">' + esc(q.question) + '<div class="tiny muted">Question to bring</div></div></div>').join('');
      html += '</div>';
    }
    if (moods.length >= 2) {
      html += '<div class="card"><div class="card-title">' + icon('heart') + '<h3>Mood after sessions</h3></div>' + sparkline(moods.map((s) => s.moodAfter), { min: 1, max: 10, height: 110, label: 'Mood after each session', format: (v, i) => Fmt.shortDate(moods[i].createdAt) + ' · ' + v + '/10', startLabel: Fmt.shortDate(moods[0].createdAt), endLabel: Fmt.shortDate(moods[moods.length - 1].createdAt) }) + '</div>';
    }
    html += '</main>';
    return html;
  }

  function sessionsHTML() {
    const q = S.ui.search.trim().toLowerCase();
    const rows = S.sessions.filter((s) => {
      if (!q) return true;
      const hay = [sessionTitle(s), s.therapistName, (s.segments || []).map((g) => g.text).join(' '), topThemes(s, 99).map((t) => t.name).join(' '), (s.tags || []).join(' ')].join(' ').toLowerCase();
      return hay.includes(q);
    });
    let html = '<main class="screen">' + topbar('Sessions', { right: '<span class="small muted">' + S.sessions.length + '</span>' });
    html += '<input class="input" id="search" type="search" placeholder="Search titles, transcripts, themes" value="' + esc(S.ui.search) + '" data-field="search" autocomplete="off">';
    if (!S.sessions.length) html += emptyState('No sessions yet', 'Your first recording will appear here with its transcript and summary.');
    else if (!rows.length) html += emptyState('No results for “' + S.ui.search + '”');
    else {
      let month = null;
      html += '<div id="session-list" class="stack">';
      let open = false;
      for (const s of rows) {
        const m = Fmt.monthLabel(s.createdAt);
        if (m !== month) { if (open) html += '</div>'; month = m; html += '<div class="section-label">' + esc(m) + '</div><div class="list">'; open = true; }
        html += '<button class="row" data-action="openSession" data-id="' + s.id + '"><div class="grow"><div class="title">' + esc(sessionTitle(s)) + '</div><div class="sub">' + esc(Fmt.shortDate(s.createdAt)) + ' · ' + esc(Fmt.durationWords(s.duration || 0)) + (s.moodBefore || s.moodAfter ? ' · ' + MoodScale.emoji(s.moodBefore) + '→' + MoodScale.emoji(s.moodAfter) : '') + '</div>' +
          '<div class="chips" style="margin-top:6px">' + topThemes(s, 2).map((t) => chip(t.name)).join('') + (!(s.segments || []).length ? chip('Audio only', 'gray') : '') + (s.recovered ? chip('Recovered', 'warn') : '') + '</div></div><span class="chev">' + Icons.chevron + '</span></button>';
      }
      if (open) html += '</div>';
      html += '</div>';
    }
    html += '</main>';
    return html;
  }

  function sessionDetailHTML(id) {
    const s = getSession(id);
    if (!s) return '<main class="screen">' + topbar('Session', { back: 'Sessions' }) + emptyState('This session no longer exists.') + '</main>';
    const ins = s.insights;
    let html = '<main class="screen">' + topbar('', { back: 'Sessions', right: '<div class="menu-anchor"><button class="icon-btn" data-action="menu" aria-label="More" aria-expanded="' + S.ui.menu + '">' + Icons.more + '</button>' + (S.ui.menu ? menuHTML(s) : '') + '</div>' });
    html += '<div class="detail-head"><h1>' + esc(sessionTitle(s)) + '</h1><div class="meta"><span>' + esc(Fmt.dateTime(s.createdAt)) + '</span><span>' + esc(Fmt.durationWords(s.duration || 0)) + '</span>' + (s.therapistName ? '<span>with ' + esc(s.therapistName) + '</span>' : '') + '</div>' +
      '<div class="hstack small"><span>Before ' + MoodScale.emoji(s.moodBefore) + (s.moodBefore ? ' ' + s.moodBefore : '') + '</span><span class="muted">→</span><span>After ' + MoodScale.emoji(s.moodAfter) + (s.moodAfter ? ' ' + s.moodAfter : '') + '</span>' + (ins ? chip(ins.engine === 'onDeviceModel' ? 'On-device AI' : 'Classic analysis', 'gray') : '') + (s.recovered ? chip('Recovered after an interruption', 'warn') : '') + '</div></div>';
    if (s.hasAudio) html += playerHTML(s);
    html += '<div class="segmented" role="tablist">' + [['summary', 'Summary'], ['transcript', 'Transcript'], ['suggestions', 'Suggestions'], ['notes', 'Notes']].map(([k, l]) => '<button role="tab" aria-pressed="' + (S.ui.tab === k) + '" data-action="tab" data-tab="' + k + '">' + l + '</button>').join('') + '</div>';
    if (ins && ins.needsSupportFlag) html += supportCard();
    html += S.ui.tab === 'summary' ? summaryHTML(s) : (S.ui.tab === 'transcript' ? transcriptHTML(s) : (S.ui.tab === 'suggestions' ? suggestionsHTML(s) : notesHTML(s)));
    html += '</main>';
    return html;
  }
  function menuHTML(s) {
    return '<div class="menu" role="menu">' +
      '<button role="menuitem" data-action="rename">Rename</button>' +
      '<button role="menuitem" data-action="regenerate">Regenerate insights</button>' +
      '<button role="menuitem" data-action="exportReport">Save report (.md)</button>' +
      '<button role="menuitem" data-action="exportTranscript">Save transcript (.txt)</button>' +
      (navigator.share ? '<button role="menuitem" data-action="shareReport">Share report…</button>' : '<button role="menuitem" data-action="copyReport">Copy report</button>') +
      (s.hasAudio ? '<button role="menuitem" data-action="saveAudio">Save audio file</button><button role="menuitem" class="danger" data-action="deleteAudio">Delete audio only</button>' : '') +
      '<button role="menuitem" class="danger" data-action="deleteSession">Delete session</button></div>';
  }
  function playerHTML(s) {
    const p = S.player;
    const loaded = p.sessionId === s.id && p.url;
    return '<div class="card player"><audio id="audio" controls preload="metadata" ' + (loaded ? 'src="' + p.url + '"' : '') + '></audio>' +
      (p.failed && p.sessionId === s.id ? '<p class="small muted">The audio file could not be loaded.</p>' : (!loaded ? '<p class="small muted">Loading audio…</p>' : '')) +
      '<div class="between"><div class="rate" aria-label="Playback speed">' + [1, 1.25, 1.5, 2].map((r) => '<button data-action="rate" data-rate="' + r + '" aria-pressed="' + (p.rate === r) + '">' + r + '×</button>').join('') + '</div><span class="tiny muted">' + esc(s.audioMime ? Exporter.extensionFor(s.audioMime).toUpperCase() : '') + (s.audioSize ? ' · ' + Fmt.fileSize(s.audioSize) : '') + '</span></div></div>';
  }
  function summaryHTML(s) {
    const ins = s.insights;
    if (!ins) return '<div class="card"><p>Insights haven\'t been generated for this session yet.</p><button class="btn primary" data-action="regenerate">' + (S.processing ? 'Working…' : 'Generate insights') + '</button></div>';
    let html = '';
    html += '<div class="card"><div class="card-title">' + icon('spark') + '<h3>Overview</h3></div><p class="read">' + esc(ins.overview) + '</p>' + (ins.languageNote ? '<p class="tiny muted">' + esc(ins.languageNote) + '</p>' : '') + '<p class="tiny muted">' + esc((ins.engine === 'onDeviceModel' ? 'On-device AI' : 'Classic analysis') + ' · ' + Fmt.relative(ins.generatedAt)) + (S.processing ? ' · updating…' : '') + '</p></div>';
    if (ins.highlights && ins.highlights.length) html += '<div class="card"><div class="card-title">' + icon('list') + '<h3>Highlights</h3></div><ul class="bullets">' + ins.highlights.map((h) => '<li>' + esc(h) + '</li>').join('') + '</ul></div>';
    if (ins.themes && ins.themes.length) html += '<div class="card"><div class="card-title">' + icon('bubble') + '<h3>Themes</h3></div><div class="chips">' + ins.themes.map((t) => '<span class="chip" title="' + esc(t.quote || '') + '">' + esc(t.name) + ' · ' + t.mentions + '</span>').join('') + '</div>' + (ins.themes[0] && ins.themes[0].quote ? '<p class="quote small">“' + esc(ins.themes[0].quote) + '”</p>' : '') + '</div>';
    if (ins.emotions && ins.emotions.length) html += '<div class="card"><div class="card-title">' + icon('heart') + '<h3>Emotions</h3></div>' + ins.emotions.map((e) => '<div class="bar-row"><span>' + esc(e.name) + '</span><div class="bar"><i style="width:' + Math.round(e.intensity * 100) + '%"></i></div><span class="tiny muted">' + e.mentions + '</span></div>').join('') + '</div>';
    if (ins.moodTrajectory && ins.moodTrajectory.length >= 2) html += '<div class="card"><div class="card-title">' + icon('wave') + '<h3>Tone through the session</h3></div>' + sparkline(ins.moodTrajectory, { min: -1, max: 1, zero: 0, area: true, height: 110, label: 'Emotional tone over the course of the session', format: (v, i) => 'Part ' + (i + 1) + ': ' + (v > 0.1 ? 'lighter' : (v < -0.1 ? 'heavier' : 'neutral')), startLabel: 'Start', endLabel: 'End' }) + '<p class="tiny muted">Overall tone ' + (ins.overallSentiment > 0.1 ? 'leaned lighter' : (ins.overallSentiment < -0.1 ? 'leaned heavier' : 'was mixed')) + '. Based on word choice, so take it as a rough signal.</p></div>';
    if (ins.keyMoments && ins.keyMoments.length) html += '<div class="card"><div class="card-title">' + icon('spark') + '<h3>Key moments</h3></div>' + ins.keyMoments.map((k) => '<div class="moment"><button class="t seg-time" data-action="seek" data-time="' + (k.time || 0) + '" ' + (s.hasAudio ? '' : 'disabled') + ' style="background:none;border:0;padding:0;color:var(--accent);font-family:var(--font-mono);font-size:0.8rem;text-align:left">' + Fmt.clock(k.time || 0) + '</button><div><div class="tiny muted">' + esc(k.reason) + '</div><div>' + esc(k.text) + '</div></div></div>').join('') + '</div>';
    if (ins.thoughtPatterns && ins.thoughtPatterns.length) html += '<div class="card"><div class="card-title">' + icon('loop') + '<h3>Thinking patterns</h3></div><p class="tiny muted">Common thought habits spotted in your words. Offered gently, not as a judgement.</p>' + ins.thoughtPatterns.map((p) => '<div class="stack" style="padding:6px 0;border-top:1px solid var(--line)"><b>' + esc(p.name) + '</b><p class="quote small">“' + esc(p.quote) + '”</p><p class="small">' + esc(p.description) + '</p><p class="small"><b>Another way to see it:</b> ' + esc(p.reframe) + '</p></div>').join('') + '</div>';
    // Commitments
    const items = s.actionItems || [];
    const present = new Set(items.map((a) => a.text.trim().toLowerCase()));
    const detected = (ins.detectedActionItems || []).filter((d) => !present.has(d.trim().toLowerCase()));
    html += '<div class="card"><div class="card-title">' + icon('checklist') + '<h3>Commitments</h3></div>' +
      (items.length ? items.map((a) => '<div class="check"><button class="box" role="checkbox" aria-checked="' + a.isDone + '" data-action="toggleItem" data-session="' + s.id + '" data-item="' + a.id + '" aria-label="Toggle done">' + (a.isDone ? Icons.check : '') + '</button><div class="txt ' + (a.isDone ? 'done' : '') + '">' + esc(a.text) + '</div><button class="icon-btn muted" data-action="deleteItem" data-item="' + a.id + '" aria-label="Remove" style="min-width:36px;min-height:36px;padding:4px">' + Icons.x + '</button></div>').join('') : '<p class="small muted">Nothing yet. Add what you agreed to do before the next session.</p>') +
      '<form class="hstack" data-action="addItem" style="flex-wrap:nowrap"><input class="input" id="new-item" placeholder="Add a commitment…" autocomplete="off" style="flex:1;min-width:0"><button class="btn small" type="submit">Add</button></form>' +
      (detected.length ? '<div class="stack"><span class="eyebrow">Heard in the session</span>' + detected.map((d, i) => '<div class="between"><span class="small">' + esc(d) + '</span><button class="btn small" data-action="adoptDetected" data-index="' + i + '">Add</button></div>').join('') + '</div>' : '') + '</div>';
    return html;
  }
  function transcriptHTML(s) {
    const segs = s.segments || [];
    const q = S.ui.search.trim().toLowerCase();
    const rows = q ? segs.filter((g) => g.text.toLowerCase().includes(q)) : segs;
    let html = '<input class="input" id="search" type="search" placeholder="Search this transcript" value="' + esc(S.ui.search) + '" data-field="search" autocomplete="off">';
    if (!segs.length) html += '<div class="card"><p>No transcript was captured for this session.</p><p class="small muted">Live transcription needs the browser\'s speech recognition (Safari or Chrome). If it was available and still produced nothing, check the language in Settings.</p></div>';
    else {
      html += '<div class="list" id="transcript">' + rows.map((g) => {
        const editing = S.ui.editingSegment === g.id;
        return '<div class="seg" data-seg="' + g.id + '" data-start="' + g.start + '" data-end="' + g.end + '"><div><button class="t" data-action="seek" data-time="' + g.start + '" ' + (s.hasAudio ? '' : 'disabled') + '>' + Fmt.clock(g.start) + '</button><button class="who ' + g.speaker + '" data-action="speaker" data-seg="' + g.id + '" title="Tap to change speaker">' + (g.speaker === 'me' ? 'Me' : (g.speaker === 'therapist' ? 'Therapist' : '—')) + '</button></div>' +
          (editing ? '<div class="stack"><textarea class="input" id="seg-edit" rows="4">' + esc(g.text) + '</textarea><div class="hstack"><button class="btn small primary" data-action="saveSegment" data-seg="' + g.id + '">Save</button><button class="btn small" data-action="cancelEdit">Cancel</button></div></div>'
            : '<div class="txt" data-action="editSegment" data-seg="' + g.id + '">' + esc(g.text) + '</div>') + '</div>';
      }).join('') + '</div>';
      html += '<p class="tiny muted">' + Fmt.plural(segs.reduce((a, g) => a + g.text.split(/\s+/).filter(Boolean).length, 0), 'word') + ' · ' + esc(Fmt.languageName(s.language || 'en-US')) + ' · tap a line to edit, tap the label to mark who spoke.</p>';
    }
    return html;
  }
  function suggestionsHTML(s) {
    const ins = s.insights;
    let html = '';
    if (!ins) html += '<div class="card"><p>Generate insights on the Summary tab to see suggestions.</p></div>';
    else {
      const present = new Set((s.actionItems || []).map((a) => a.text.trim().toLowerCase()));
      const qset = new Set((s.nextSessionQuestions || []).map((q) => q.trim().toLowerCase()));
      for (const cat of Object.keys(CategoryMeta)) {
        const items = (ins.suggestions || []).filter((x) => x.category === cat);
        if (!items.length) continue;
        html += '<div class="card"><div class="card-title">' + icon(CategoryMeta[cat].icon) + '<h3>' + esc(CategoryMeta[cat].label) + '</h3></div>' + items.map((x) => {
          const added = present.has(x.title.trim().toLowerCase());
          const saved = qset.has(x.title.trim().toLowerCase()) || qset.has(x.detail.trim().toLowerCase());
          return '<div class="suggestion"><b>' + esc(x.title) + '</b><p class="small">' + esc(x.detail) + '</p><p class="why">' + esc(x.rationale) + '</p><div class="hstack"><button class="btn small" data-action="adoptSuggestion" data-id="' + x.id + '" ' + (added ? 'disabled' : '') + '>' + (added ? 'Added' : 'Add to commitments') + '</button>' + (cat === 'nextSession' || cat === 'reflection' || cat === 'pattern' ? '<button class="btn small" data-action="saveQuestion" data-id="' + x.id + '" ' + (saved ? 'disabled' : '') + '>' + (saved ? 'Saved' : 'Save as question') + '</button>' : '') + '</div></div>';
        }).join('') + '</div>';
      }
    }
    const qs = s.nextSessionQuestions || [];
    html += '<div class="card"><div class="card-title">' + icon('calendar') + '<h3>Questions for next session</h3></div>' + (qs.length ? qs.map((q, i) => '<div class="check"><span style="color:var(--accent);flex:none;margin-top:2px">' + icon('bubble') + '</span><div class="txt">' + esc(q) + '</div><button class="icon-btn muted" data-action="removeQuestion" data-index="' + i + '" aria-label="Remove" style="min-width:36px;min-height:36px;padding:4px">' + Icons.x + '</button></div>').join('') : '<p class="small muted">Save questions here so they are ready when you walk in.</p>') +
      '<form class="hstack" data-action="addQuestion" style="flex-wrap:nowrap"><input class="input" id="new-question" placeholder="Add a question…" autocomplete="off" style="flex:1;min-width:0"><button class="btn small" type="submit">Add</button></form></div>';
    return html;
  }
  function notesHTML(s) {
    return '<div class="card"><div class="card-title">' + icon('edit') + '<h3>Notes</h3></div><textarea class="input" id="notes" data-field="notes" placeholder="How did the session land? Anything you want to remember?">' + esc(s.notes || '') + '</textarea><p class="tiny muted">Saved automatically.</p></div>' +
      '<div class="card"><div class="card-title">' + icon('list') + '<h3>Tags</h3></div><div class="chips">' + (s.tags || []).map((t, i) => '<span class="chip">' + esc(t) + '<button class="x" data-action="removeTag" data-index="' + i + '" aria-label="Remove tag">×</button></span>').join('') + '</div><form class="hstack" data-action="addTag" style="flex-wrap:nowrap"><input class="input" id="new-tag" placeholder="Add a tag" autocomplete="off" style="flex:1;min-width:0"><button class="btn small" type="submit">Add</button></form></div>' +
      '<div class="card"><div class="card-title">' + icon('info') + '<h3>Details</h3></div><div class="field"><label for="therapist">Therapist</label><input class="input" id="therapist" data-field="therapistName" value="' + esc(s.therapistName || '') + '" placeholder="Name (optional)"></div><dl class="kv"><dt>Recorded</dt><dd>' + esc(Fmt.dateTime(s.createdAt)) + '</dd><dt>Duration</dt><dd>' + esc(Fmt.durationWords(s.duration || 0)) + '</dd><dt>Words</dt><dd>' + (s.segments || []).reduce((a, g) => a + g.text.split(/\s+/).filter(Boolean).length, 0) + '</dd><dt>Language</dt><dd>' + esc(Fmt.languageName(s.language || 'en-US')) + '</dd><dt>Audio</dt><dd>' + (s.hasAudio ? esc(Fmt.fileSize(s.audioSize || 0)) : 'none') + '</dd><dt>Insights</dt><dd>' + (s.insights ? esc(s.insights.engine === 'onDeviceModel' ? 'On-device AI' : 'Classic') : '—') + '</dd></dl></div>';
  }

  function prepareHTML() {
    const items = openItems(), qs = pendingQuestions(), themes = recurringThemes();
    let html = '<main class="screen">' + topbar('Prepare', { right: '<button class="icon-btn" data-action="sharePrep" aria-label="Share prep sheet">' + Icons.share + '</button>' });
    html += '<p class="muted" style="margin-top:-10px">Everything worth carrying into your next session.</p>';
    html += '<div class="card"><div class="card-title">' + icon('checklist') + '<h3>Open commitments</h3></div>' + (items.length ? items.map((o) => '<div class="check"><button class="box" role="checkbox" aria-checked="false" data-action="toggleItem" data-session="' + o.sessionId + '" data-item="' + o.item.id + '" aria-label="Mark done"></button><div class="txt">' + esc(o.item.text) + '<div class="tiny muted"><button class="btn ghost small" style="padding:0;min-height:0" data-action="openSession" data-id="' + o.sessionId + '">' + esc(o.sessionTitle) + ' · ' + esc(Fmt.shortDate(o.sessionDate)) + '</button></div></div></div>').join('') : '<p class="small muted">Nothing open. Commitments you make in sessions show up here.</p>') + '</div>';
    html += '<div class="card"><div class="card-title">' + icon('bubble') + '<h3>Questions to bring</h3></div>' + (qs.length ? qs.map((q) => '<div class="check"><span style="color:var(--accent);flex:none;margin-top:2px">' + icon('bubble') + '</span><div class="txt">' + esc(q.question) + '<div class="tiny muted">' + esc(q.sessionTitle) + '</div></div><button class="icon-btn muted" data-action="removePrepQuestion" data-session="' + q.sessionId + '" data-q="' + esc(q.question) + '" aria-label="Remove" style="min-width:36px;min-height:36px;padding:4px">' + Icons.x + '</button></div>').join('') : '<p class="small muted">None saved yet.</p>') +
      (S.sessions.length ? '<form class="hstack" data-action="addPrepQuestion" style="flex-wrap:nowrap"><input class="input" id="prep-question" placeholder="Add a question for your therapist…" autocomplete="off" style="flex:1;min-width:0"><button class="btn small" type="submit">Add</button></form>' : '<p class="tiny muted">Record a session first; questions attach to your latest session.</p>') + '</div>';
    html += '<div class="card"><div class="card-title">' + icon('loop') + '<h3>Recurring themes</h3></div>' + (themes.length ? themes.map((t) => '<div class="between small"><span>' + esc(t.name) + '</span><span class="muted">' + Fmt.plural(t.sessionCount, 'session') + '</span></div>').join('') : '<p class="small muted">Themes that come up in two or more sessions will be listed here.</p>') + '</div>';
    const trend = moodTrendChart(S.sessions);
    if (trend) html += '<div class="card"><div class="card-title">' + icon('heart') + '<h3>Mood before and after</h3></div>' + trend + '</div>';
    html += '<div class="card"><div class="card-title">' + icon('book') + '<h3>Journal</h3><button class="btn small" data-action="openJournal">Write</button></div>' + (S.journal.length ? S.journal.slice(0, 20).map((j) => '<div class="check"><span class="emoji" style="flex:none">' + MoodScale.emoji(j.mood) + '</span><div class="txt"><div class="tiny muted">' + esc(Fmt.relative(j.createdAt)) + (j.mood ? ' · ' + j.mood + '/10' : '') + '</div><div class="small" style="white-space:pre-wrap">' + esc(j.text) + '</div></div><button class="icon-btn muted" data-action="deleteJournal" data-id="' + j.id + '" aria-label="Delete entry" style="min-width:36px;min-height:36px;padding:4px">' + Icons.x + '</button></div>').join('') : '<p class="small muted">A few lines between sessions help you notice what changes.</p>') + '</div>';
    html += '</main>';
    return html;
  }

  function settingsHTML() {
    const st = S.settings;
    const langs = LANGUAGES.includes(st.language) ? LANGUAGES : [st.language, ...LANGUAGES];
    const speech = LiveTranscriber.isSupported();
    let html = '<main class="screen">' + topbar('Settings');
    html += '<div class="section-label">Transcription</div><div class="list">' +
      '<div class="switch-row"><div class="grow"><div>Language</div><div class="hint">What you and your therapist speak</div></div><select class="input" id="language" data-field="language" style="width:auto;max-width:55%">' + langs.map((l) => '<option value="' + l + '" ' + (l === st.language ? 'selected' : '') + '>' + esc(Fmt.languageName(l)) + ' (' + l + ')</option>').join('') + '</select></div>' +
      '<div class="switch-row"><div class="grow"><div>Recording mode</div><div class="hint">' + esc({ both: 'Audio file + live transcript', transcript: 'Live transcript only (no audio file)', audio: 'Audio file only' }[st.recordingMode]) + '</div></div><select class="input" id="mode" data-field="recordingMode" style="width:auto"><option value="both" ' + (st.recordingMode === 'both' ? 'selected' : '') + '>Both</option><option value="transcript" ' + (st.recordingMode === 'transcript' ? 'selected' : '') + '>Transcript only</option><option value="audio" ' + (st.recordingMode === 'audio' ? 'selected' : '') + '>Audio only</option></select></div>' +
      '<div class="switch-row"><div class="grow"><div>Prefer on-device recognition</div><div class="hint">' + esc(S.ui.localStatus || (speech ? 'Used when the browser offers it (Chrome). Safari decides for itself.' : 'This browser has no speech recognition.')) + '</div></div><button class="switch" role="switch" aria-checked="' + st.preferLocalRecognition + '" data-action="toggleSetting" data-key="preferLocalRecognition" aria-label="Prefer on-device recognition"></button></div>' +
      '</div><p class="tiny muted" style="padding:0 4px">' + (speech ? 'Speech recognition is provided by your browser and device (on iPhone: Apple\'s dictation service; in Chrome: Google\'s or on-device). Nothing goes to this app\'s authors or any other party.' : 'Use Safari on iPhone/Mac or Chrome to get live transcription. You can still record audio here.') + '</p>';
    html += '<div class="section-label">Insights</div><div class="list">' +
      '<div class="switch-row"><div class="grow"><div>Engine</div><div class="hint">' + (st.enginePreference === 'automatic' ? 'On-device AI when the browser has one, otherwise classic analysis' : 'Always classic analysis') + '</div></div><select class="input" id="engine" data-field="enginePreference" style="width:auto"><option value="automatic" ' + (st.enginePreference === 'automatic' ? 'selected' : '') + '>Automatic</option><option value="classic" ' + (st.enginePreference === 'classic' ? 'selected' : '') + '>Classic only</option></select></div>' +
      '<div class="switch-row"><div class="grow"><div>On-device AI</div><div class="hint">' + esc(S.ui.aiStatus ? S.ui.aiStatus.label : 'Checking…') + '</div></div>' + (S.ui.aiStatus && S.ui.aiStatus.state === 'downloadable' ? '<button class="btn small" data-action="downloadAI">Download</button>' : '') + '</div></div>' +
      '<p class="tiny muted" style="padding:0 4px">Classic analysis is a rule-based engine built into this app. On-device AI uses the language model some browsers ship (Chrome on desktop); the model runs inside the browser and nothing is uploaded.</p>';
    html += '<div class="section-label">Privacy</div><div class="list">' +
      '<div class="switch-row"><div class="grow"><div>Lock with a PIN</div><div class="hint">' + (st.pinHash ? 'A PIN is required when you open or return to the app' : 'Hide your sessions behind a 4-digit PIN') + '</div></div><button class="switch" role="switch" aria-checked="' + !!st.pinHash + '" data-action="togglePin" aria-label="Lock with a PIN"></button></div></div>' +
      '<p class="tiny muted" style="padding:0 4px">The PIN is a privacy screen inside the app. Your data is stored by the browser on this device; anyone with full access to the device could still reach it.</p>';
    html += '<div class="section-label">Defaults</div><div class="list"><div class="switch-row"><div class="grow"><div>Therapist\'s name</div></div><input class="input" id="default-therapist" data-field="therapistName" value="' + esc(st.therapistName) + '" placeholder="Optional" style="width:50%"></div></div>';
    const est = S.ui.storage;
    html += '<div class="section-label">Your data</div><div class="list">' +
      '<div class="switch-row"><div class="grow"><div>Stored here</div><div class="hint">' + Fmt.plural(S.sessions.length, 'session') + ', ' + Fmt.plural(S.journal.length, 'journal entry').replace('entrys', 'entries') + (est && est.usage ? ' · ' + Fmt.fileSize(est.usage) + ' used' : '') + (DB.volatile ? ' · storage unavailable in this browser mode (data will not survive closing the tab)' : '') + '</div></div></div>' +
      '<button class="row" data-action="backup"><div class="grow"><div class="title">Back up everything (.json)</div><div class="sub">Sessions, journal, settings. Audio is saved separately per session.</div></div><span class="chev">' + Icons.share + '</span></button>' +
      '<button class="row" data-action="exportAll"><div class="grow"><div class="title">Export all as Markdown</div><div class="sub">Readable reports of every session</div></div><span class="chev">' + Icons.share + '</span></button>' +
      '<label class="row" style="cursor:pointer"><div class="grow"><div class="title">Restore from a backup</div><div class="sub">Adds sessions from a .json file</div></div><input type="file" id="restore" accept="application/json,.json" style="display:none" data-field="restore"><span class="chev">' + Icons.plus + '</span></label>' +
      '<button class="row" data-action="confirmDeleteAll"><div class="grow"><div class="title" style="color:var(--danger)">Delete all data</div></div></button></div>' +
      '<p class="tiny muted" style="padding:0 4px">Browsers can clear site data, and Safari removes data from sites you have not opened for a while unless the app is added to your Home Screen. Back up now and then.</p>';
    html += '<div class="section-label">About</div><div class="list">' +
      '<button class="row" data-action="nav" data-route="how"><div class="grow"><div class="title">How it works</div></div><span class="chev">' + Icons.chevron + '</span></button>' +
      '<button class="row" data-action="nav" data-route="notes"><div class="grow"><div class="title">Important notes & support</div></div><span class="chev">' + Icons.chevron + '</span></button>' +
      '<div class="switch-row"><div class="grow"><div>Version</div></div><span class="muted small">1.0 · ' + (navigator.standalone ? 'Home Screen app' : 'browser') + '</span></div></div>';
    if (!navigator.standalone && /iPhone|iPad/.test(navigator.userAgent)) html += '<div class="banner info">' + icon('info') + '<span>Tip: in Safari tap Share → <b>Add to Home Screen</b>. The app then opens full screen and your data is kept more reliably.</span></div>';
    html += '</main>';
    return html;
  }
  function howHTML() {
    return '<main class="screen">' + topbar('How it works', { back: 'Settings' }) +
      '<div class="card"><h3>Recording</h3><p class="small">The microphone is captured by your browser and saved in 10-second pieces while you record, so an interrupted session can be recovered. Keep the screen on: browsers pause capture when the screen locks or the app goes to the background.</p></div>' +
      '<div class="card"><h3>Transcription</h3><p class="small">Live transcription uses the speech recognition built into your browser and device. Recognition runs in short chained bursts, each becoming a timestamped line you can tap to replay. On iPhone this is Apple\'s dictation service, in Chrome it is Google\'s recognizer or Chrome\'s on-device model when available. The app itself has no server and sends nothing anywhere.</p></div>' +
      '<div class="card"><h3>Summary and suggestions</h3><p class="small"><b>Classic analysis</b> is a rule-based engine inside this app: it finds themes, emotions, commitments, key moments and common thinking patterns in your words, tracks the emotional tone through the session, and picks suggestions from a built-in library of well-established techniques (worry windows, sleep rules, grounding, boundary scripts and so on). <b>On-device AI</b>, when your browser has a built-in language model, rewrites the overview and suggestions in more natural language; the model runs on your device.</p></div>' +
      '<div class="card"><h3>Storage</h3><p class="small">Everything is kept in your browser\'s storage for this site on this device. Nothing syncs. Deleting a session deletes its audio. Use Back up in Settings to keep a copy.</p></div>' +
      '<div class="card"><h3>Works offline</h3><p class="small">Once opened, the app is cached and works without a connection. Live transcription may need a connection on devices whose speech recognition runs through the system\'s service.</p></div></main>';
  }
  function notesScreenHTML() {
    return '<main class="screen">' + topbar('Important notes', { back: 'Settings' }) +
      '<div class="card"><h3>Not medical advice</h3><p class="small">Therapist Copilot helps you remember and reflect. It is not a therapist, not a diagnostic tool, and not a substitute for professional care. Summaries and suggestions are generated from word patterns and can be wrong.</p></div>' +
      '<div class="card"><h3>Recording consent</h3><p class="small">Laws about recording conversations differ by country and state; many require every participant\'s consent. Tell your therapist you would like to record and ask whether they are comfortable with it. Many are, especially when the recording stays with you.</p></div>' +
      '<div class="card"><div class="card-title">' + icon('heart') + '<h3>If you need support now</h3></div>' + Lexicon.supportResources.map((r) => '<div><b>' + esc(r.title) + '</b><div class="small muted">' + esc(r.detail) + '</div></div>').join('') + '</div></main>';
  }

  // ---------- sheets ----------
  function sheetHTML() {
    const sh = S.ui.sheet;
    if (!sh) return '';
    let body = '';
    const f = S.ui.form;
    if (sh === 'preSession') {
      const onDeviceNote = LiveTranscriber.isSupported() ? '' : 'This browser has no speech recognition; the session will be recorded as audio only.';
      body = '<h2>New session</h2>' +
        '<div class="field"><label for="f-title">Title (optional)</label><input class="input" id="f-title" data-form="title" value="' + esc(f.title || '') + '" placeholder="e.g. Week 12, after the trip"></div>' +
        '<div class="field"><label for="f-therapist">Therapist</label><input class="input" id="f-therapist" data-form="therapistName" value="' + esc(f.therapistName != null ? f.therapistName : S.settings.therapistName) + '" placeholder="Name (optional)"></div>' +
        moodPicker('moodBefore', f.moodBefore || null, 'How do you feel right now?') +
        '<div class="card plain small"><div class="between"><span>Language</span><b>' + esc(Fmt.languageName(S.settings.language)) + '</b></div><div class="between"><span>Mode</span><b>' + esc({ both: 'Audio + transcript', transcript: 'Transcript only', audio: 'Audio only' }[S.settings.recordingMode]) + '</b></div>' + (onDeviceNote ? '<p class="muted">' + esc(onDeviceNote) + '</p>' : '') + '<p class="muted">Change these in Settings.</p></div>' +
        '<p class="tiny muted">Make sure your therapist knows you are recording. Keep the screen on during the session.</p>' +
        '<button class="btn primary block" data-action="startSession">' + Icons.mic + ' Start recording</button><button class="btn block" data-action="closeSheet">Cancel</button>';
    } else if (sh === 'postSession') {
      const p = S.pending;
      const step = S.processing ? 'processing' : (p && p.saved ? 'done' : 'mood');
      if (step === 'mood') {
        body = '<h2>Session recorded</h2><p class="muted small">' + esc(Fmt.durationWords(p.duration || 0)) + ' · ' + Fmt.plural((p.segments || []).reduce((a, g) => a + g.text.split(/\s+/).filter(Boolean).length, 0), 'word') + (p.audio ? ' · audio saved' : '') + '</p>' +
          moodPicker('moodAfter', f.moodAfter || null, 'How do you feel now?') +
          '<div class="field"><label for="f-note">Anything you want to remember? (optional)</label><textarea class="input" id="f-note" data-form="quickNote" rows="3">' + esc(f.quickNote || '') + '</textarea></div>' +
          '<button class="btn primary block" data-action="processSession">Save and analyze</button>';
      } else if (step === 'processing') {
        body = '<h2>Working on it</h2><div class="hstack"><span class="rec-dot" style="background:var(--accent)"></span><span>' + esc(S.processing.status) + '</span></div><p class="tiny muted">This runs on your device and usually takes a few seconds.</p>';
      } else {
        const s = getSession(p.id);
        const ins = s && s.insights;
        body = '<h2>' + esc(sessionTitle(s)) + '</h2>' + (ins ? '<p class="read">' + esc(ins.overview) + '</p><div class="chips">' + topThemes(s, 3).map((t) => chip(t.name)).join('') + '</div><p class="small muted">' + Fmt.plural((ins.suggestions || []).length, 'suggestion') + ' · ' + Fmt.plural((s.actionItems || []).length, 'commitment') + ' · ' + Fmt.plural((s.nextSessionQuestions || []).length, 'question') + ' for next time</p>' + (ins.needsSupportFlag ? supportCard() : '') : '<p class="muted">Saved.</p>') +
          '<button class="btn primary block" data-action="openPending">Open session</button><button class="btn block" data-action="closePending">Done</button>';
      }
    } else if (sh === 'journal') {
      body = '<h2>Reflection</h2>' + moodPicker('journalMood', f.journalMood || null, 'How are you right now?') + '<div class="field"><label for="f-journal">What\'s on your mind?</label><textarea class="input" id="f-journal" data-form="journalText" rows="6">' + esc(f.journalText || '') + '</textarea></div><button class="btn primary block" data-action="saveJournal">Save</button><button class="btn block" data-action="closeSheet">Cancel</button>';
    } else if (sh === 'rename') {
      body = '<h2>Rename session</h2><input class="input" id="f-rename" data-form="rename" value="' + esc(f.rename || '') + '" placeholder="Session title"><button class="btn primary block" data-action="saveRename">Save</button><button class="btn block" data-action="closeSheet">Cancel</button>';
    } else if (sh === 'pinSetup') {
      const ps = S.pinSetup;
      body = '<h2>' + (ps.stage === 'confirm' ? 'Repeat the PIN' : 'Choose a 4-digit PIN') + '</h2><div class="pin" style="justify-content:center">' + [0, 1, 2, 3].map((i) => '<i class="' + (i < ps.entry.length ? 'on' : '') + '"></i>').join('') + '</div>' + (ps.error ? '<p class="small" style="color:var(--danger);text-align:center">' + esc(ps.error) + '</p>' : '') + keypadHTML('pinSetupKey') + '<button class="btn block" data-action="closeSheet">Cancel</button>';
    } else if (sh === 'confirm') {
      const c = S.ui.confirm;
      body = '<h2>' + esc(c.title) + '</h2><p class="small muted">' + esc(c.message) + '</p><button class="btn block ' + (c.danger ? 'danger' : 'primary') + '" data-action="confirmYes">' + esc(c.label) + '</button><button class="btn block" data-action="closeSheet">Cancel</button>';
    }
    return '<div class="sheet-backdrop" data-action="backdrop"><div class="sheet" role="dialog" aria-modal="true"><div class="sheet-handle"></div>' + body + '</div></div>';
  }
  function keypadHTML(action) {
    return '<div class="keypad" style="justify-content:center;margin:0 auto">' + [1, 2, 3, 4, 5, 6, 7, 8, 9].map((d) => '<button data-action="' + action + '" data-digit="' + d + '">' + d + '</button>').join('') + '<span></span><button data-action="' + action + '" data-digit="0">0</button><button data-action="' + action + '" data-digit="back" aria-label="Delete">⌫</button></div>';
  }
  function lockHTML() {
    return '<div class="lock" role="dialog" aria-modal="true" aria-label="Locked"><div style="color:var(--accent)">' + Icons.lock.replace('<svg', '<svg width="44" height="44"') + '</div><h2>Enter your PIN</h2><div class="pin">' + [0, 1, 2, 3].map((i) => '<i class="' + (i < S.pinEntry.length ? 'on' : '') + '"></i>').join('') + '</div>' + (S.pinError ? '<p class="small" style="color:var(--danger)">' + esc(S.pinError) + '</p>' : '') + keypadHTML('pinKey') + '</div>';
  }

  // ---------- recording overlay ----------
  function recordingHTML() {
    const r = S.recUI;
    if (!r) return '';
    const paused = r.state === 'paused', finishing = r.state === 'finishing';
    return '<div class="rec-screen" role="dialog" aria-modal="true" aria-label="Recording">' +
      '<div class="rec-head"><div class="hstack"><span class="rec-dot ' + (paused ? 'paused' : '') + '" id="rec-dot"></span><span class="small muted" id="rec-state">' + (finishing ? 'Finishing…' : (paused ? 'Paused' : 'Recording')) + '</span></div><div class="rec-time" id="rec-time">' + Fmt.clock(r.elapsed) + '</div><div class="small muted">' + esc(r.title || 'Session') + '</div></div>' +
      '<div class="meter" id="rec-meter" aria-hidden="true">' + Array.from({ length: 24 }, () => '<i></i>').join('') + '</div>' +
      '<div id="rec-banners" class="stack">' + bannersHTML() + '</div>' +
      '<div class="live" id="rec-live">' + liveHTML() + '</div>' +
      (S.ui.confirm && S.ui.confirm.inline ? '<div class="confirm"><b>' + esc(S.ui.confirm.title) + '</b><p class="small muted">' + esc(S.ui.confirm.message) + '</p><div class="hstack"><button class="btn ' + (S.ui.confirm.danger ? 'danger' : 'primary') + '" data-action="confirmYes">' + esc(S.ui.confirm.label) + '</button><button class="btn" data-action="closeConfirm">Keep going</button></div></div>' : '') +
      '<div class="rec-controls"><button class="btn" data-action="discard" ' + (finishing ? 'disabled' : '') + '>Discard</button><button class="stop" data-action="finish" aria-label="Finish session" ' + (finishing ? 'disabled' : '') + '>' + Icons.stop + '</button><button class="btn" data-action="' + (paused ? 'resume' : 'pause') + '" ' + (finishing ? 'disabled' : '') + '>' + (paused ? 'Resume' : 'Pause') + '</button></div>' +
      '<p class="tiny muted" style="text-align:center">Keep the screen on. Recording pauses when the screen locks or you switch apps.</p></div>';
  }
  function bannersHTML() {
    const r = S.recUI; let h = '';
    if (r.mode !== 'audio' && !r.transcriptionActive) h += '<div class="banner info">' + icon('info') + '<span>Audio only — live transcription is not running for this session.</span></div>';
    if (r.mode === 'audio') h += '<div class="banner info">' + icon('info') + '<span>Audio only mode. You can switch on transcription in Settings for next time.</span></div>';
    for (const w of r.warnings.slice(-2)) h += '<div class="banner warn">' + icon('info') + '<span>' + esc(w) + '</span></div>';
    return h;
  }
  function liveHTML() {
    const r = S.recUI;
    const committed = r.segments.map((g) => g.text).join(' ');
    if (!committed && !r.partial) return '<span class="placeholder">' + (r.transcriptionActive ? 'Listening… words will appear here as you speak.' : 'Recording audio.') + '</span>';
    return esc(committed) + (r.partial ? ' <span class="partial">' + esc(r.partial) + '</span>' : '') + '<span id="rec-bottom"></span>';
  }
  function patchRecording() {
    const r = S.recUI; if (!r) return;
    const t = document.getElementById('rec-time'); if (t) t.textContent = Fmt.clock(r.elapsed);
    const m = document.getElementById('rec-meter');
    if (m) { const on = Math.round(r.level * 24); Array.from(m.children).forEach((bar, i) => { const active = i < on && r.state === 'recording'; bar.className = active ? 'on' : ''; bar.style.height = (active ? 6 + Math.min(22, (r.level * 22) * (0.6 + 0.4 * Math.sin(i * 1.3))) : 6) + 'px'; }); }
  }
  function patchLive() {
    const el = document.getElementById('rec-live'); if (!el) return;
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 60;
    el.innerHTML = liveHTML();
    if (atBottom) el.scrollTop = el.scrollHeight;
  }
  function patchBanners() { const el = document.getElementById('rec-banners'); if (el) el.innerHTML = bannersHTML(); }

  // ---------- render ----------
  function render() {
    if (!S.ready) return;
    let html = '';
    if (S.locked) html = lockHTML();
    else {
      const r = S.route;
      if (!S.settings.hasSeenOnboarding) html = onboardingHTML();
      else if (r.name === 'sessions') html = sessionsHTML();
      else if (r.name === 'session') html = sessionDetailHTML(r.id);
      else if (r.name === 'prepare') html = prepareHTML();
      else if (r.name === 'settings') html = settingsHTML();
      else if (r.name === 'how') html = howHTML();
      else if (r.name === 'notes') html = notesScreenHTML();
      else html = homeHTML();
      if (S.settings.hasSeenOnboarding) html += tabbar();
      html += recordingHTML() + sheetHTML();
    }
    app().innerHTML = html;
    afterRender();
  }
  function afterRender() {
    if (S.route.name === 'session' && !S.locked) ensureAudioLoaded(S.route.id);
    const live = document.getElementById('rec-live'); if (live) live.scrollTop = live.scrollHeight;
    patchRecording();
    const segEdit = document.getElementById('seg-edit'); if (segEdit) { segEdit.focus(); }
    const audio = document.getElementById('audio');
    if (audio) {
      audio.playbackRate = S.player.rate;
      audio.addEventListener('timeupdate', () => highlightSegment(audio.currentTime));
      audio.addEventListener('error', () => { S.player.failed = true; });
    }
  }
  function highlightSegment(t) {
    document.querySelectorAll('.seg').forEach((el) => {
      const a = parseFloat(el.dataset.start), b = Math.max(parseFloat(el.dataset.end), a + 0.5);
      el.classList.toggle('current', t >= a && t < b);
    });
  }

  // ---------- audio player ----------
  async function ensureAudioLoaded(id) {
    const s = getSession(id);
    if (!s || !s.hasAudio) return;
    if (S.player.sessionId === id && (S.player.url || S.player.failed)) return;
    releasePlayer();
    S.player.sessionId = id;
    try {
      const rec = await DB.getAudio(id);
      if (!rec || !rec.blob) { S.player.failed = true; }
      else { S.player.url = URL.createObjectURL(rec.blob); }
    } catch (e) { S.player.failed = true; }
    if (S.route.name === 'session' && S.route.id === id) render();
  }
  function releasePlayer() {
    if (S.player.url) { try { URL.revokeObjectURL(S.player.url); } catch (e) { /* ignore */ } }
    S.player = { sessionId: null, url: null, rate: S.player.rate || 1, current: 0, failed: false };
  }

  // ---------- recording flow ----------
  async function startSession() {
    const f = S.ui.form;
    const draft = { id: uid(), createdAt: new Date().toISOString(), title: (f.title || '').trim(), therapistName: (f.therapistName != null ? f.therapistName : S.settings.therapistName).trim(), moodBefore: f.moodBefore || null, moodAfter: null, language: S.settings.language, segments: [], notes: '', actionItems: [], nextSessionQuestions: [], tags: [], hasAudio: false };
    const mode = S.settings.recordingMode;
    S.recUI = { state: 'starting', elapsed: 0, level: 0, partial: '', segments: [], warnings: [], transcriptionActive: false, mode, title: draft.title || 'Session' };
    const saveDraft = debounce(() => { DB.saveDraft({ ...draft, segments: S.recUI ? S.recUI.segments : [], mode }).catch(() => {}); }, 1500);
    const rec = new SessionRecorder({
      sessionId: draft.id, mode, lang: S.settings.language, preferLocal: S.settings.preferLocalRecognition,
      onLevel: (l) => { if (S.recUI) { S.recUI.level = S.recUI.level * 0.5 + l * 0.5; } },
      onTick: (e) => { if (S.recUI) { S.recUI.elapsed = e; patchRecording(); } },
      onPartial: (t) => { if (S.recUI) { S.recUI.partial = t; patchLive(); } },
      onSegment: (seg) => { if (S.recUI) { S.recUI.segments.push(seg); S.recUI.segments.sort((a, b) => a.start - b.start); S.recUI.partial = ''; patchLive(); saveDraft(); } },
      onWarning: (m) => { if (S.recUI) { if (!S.recUI.warnings.includes(m)) S.recUI.warnings.push(m); S.recUI.transcriptionActive = rec.transcriptionActive; patchBanners(); } },
      onState: (st) => { if (S.recUI && st !== 'stopped') { S.recUI.state = st; S.recUI.transcriptionActive = rec.transcriptionActive; render(); } }
    });
    S.rec = rec; S.pending = draft; S.ui.sheet = null;
    render();
    try {
      await rec.start();
      S.recUI.transcriptionActive = rec.transcriptionActive;
      S.recUI.state = rec.state;
      await DB.saveDraft({ ...draft, segments: [], mode }).catch(() => {});
      render();
    } catch (e) {
      S.rec = null; S.recUI = null; S.pending = null;
      render();
      toast(e.message || 'Recording could not start.');
    }
  }
  async function finishSession() {
    const rec = S.rec; if (!rec) return;
    S.ui.confirm = null;
    S.recUI.state = 'finishing'; render();
    const result = await rec.stop();
    const draft = S.pending;
    S.rec = null; S.recUI = null;
    if (!result) { S.pending = null; render(); return; }
    draft.duration = Math.round(result.duration * 10) / 10;
    draft.segments = result.segments.map((g) => ({ ...g, start: Math.round(g.start * 10) / 10, end: Math.round(g.end * 10) / 10 }));
    draft.audio = result.audio;
    S.pending = draft;
    S.ui.form = {};
    S.ui.sheet = 'postSession';
    render();
  }
  async function processSession() {
    const p = S.pending; if (!p) return;
    const f = S.ui.form;
    p.moodAfter = f.moodAfter || null;
    if ((f.quickNote || '').trim()) p.notes = f.quickNote.trim();
    S.processing = { status: 'Saving the session…' }; render();
    const session = { id: p.id, createdAt: p.createdAt, title: p.title, therapistName: p.therapistName, duration: p.duration, language: p.language, segments: p.segments, moodBefore: p.moodBefore, moodAfter: p.moodAfter, notes: p.notes || '', actionItems: [], nextSessionQuestions: [], tags: [], hasAudio: false, insights: null };
    if (p.audio && p.audio.blob && p.audio.blob.size > 0) {
      try { await DB.saveAudio(session.id, p.audio.blob, p.audio.mime); session.hasAudio = true; session.audioMime = p.audio.mime; session.audioSize = p.audio.blob.size; } catch (e) { toast('The audio could not be stored in this browser; the transcript was kept.'); }
    }
    S.sessions.unshift(session); sortSessions();
    await persistSession(session);
    await DB.clearDraft().catch(() => {}); await DB.deleteChunks(session.id).catch(() => {});
    DB.persist();
    await generateInsights(session.id, true);
    p.saved = true; S.processing = null;
    render();
  }
  async function generateInsights(id, applyDefaults) {
    const s = getSession(id); if (!s) return;
    S.processing = { status: 'Analyzing the transcript…' }; render();
    await new Promise((r) => setTimeout(r, 30));
    let insights;
    try { insights = Insights.analyze(s, S.sessions.filter((x) => x.id !== id)); } catch (e) { insights = Insights.empty(s.language); }
    if (S.settings.enginePreference === 'automatic' && (s.segments || []).length && OnDeviceAI.isSupported()) {
      try {
        const st = await OnDeviceAI.status();
        if (st.state === 'available') { S.processing = { status: 'Asking the on-device model…' }; render(); insights = await OnDeviceAI.enrich(insights, s); }
      } catch (e) { /* classic result stands */ }
    }
    await updateSession(id, (x) => {
      x.insights = insights;
      if (applyDefaults) {
        if (!x.actionItems.length) x.actionItems = (insights.detectedActionItems || []).map((t) => ({ id: uid(), text: t, isDone: false, source: 'detected', createdAt: new Date().toISOString() }));
        if (!x.nextSessionQuestions.length) x.nextSessionQuestions = (insights.questionsForNextSession || []).slice();
      }
    });
    S.processing = null;
  }
  async function recoverDraft() {
    let draft = null;
    try { draft = await DB.loadDraft(); } catch (e) { return; }
    const ids = await DB.chunkSessionIds().catch(() => []);
    if (!draft && !ids.length) return;
    const id = draft ? draft.id : ids[0];
    if (getSession(id)) { await DB.clearDraft().catch(() => {}); await DB.deleteChunks(id).catch(() => {}); return; }
    const chunks = await DB.getChunks(id).catch(() => []);
    const segments = (draft && draft.segments) || [];
    if (!chunks.length && !segments.length) { await DB.clearDraft().catch(() => {}); return; }
    const session = { id, createdAt: (draft && draft.createdAt) || new Date().toISOString(), title: ((draft && draft.title) || '') , therapistName: (draft && draft.therapistName) || '', duration: segments.length ? segments[segments.length - 1].end : chunks.length * 10, language: (draft && draft.language) || S.settings.language, segments, moodBefore: draft ? draft.moodBefore : null, moodAfter: null, notes: 'Recovered automatically after the recording was interrupted.', actionItems: [], nextSessionQuestions: [], tags: [], hasAudio: false, insights: null, recovered: true };
    if (chunks.length) {
      const type = chunks[0].blob.type || 'audio/webm';
      const blob = new Blob(chunks.map((c) => c.blob), { type });
      try { await DB.saveAudio(id, blob, type); session.hasAudio = true; session.audioMime = type; session.audioSize = blob.size; } catch (e) { /* keep going */ }
    }
    S.sessions.unshift(session); sortSessions();
    await persistSession(session);
    await DB.clearDraft().catch(() => {}); await DB.deleteChunks(id).catch(() => {});
    if (segments.length) await generateInsights(id, true);
    toast('A recording that was interrupted has been recovered.');
  }

  // ---------- PIN ----------
  async function hashPin(pin) {
    const data = new TextEncoder().encode('therapist-copilot:' + pin);
    const buf = await crypto.subtle.digest('SHA-256', data);
    return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, '0')).join('');
  }
  async function pinKey(digit) {
    if (digit === 'back') { S.pinEntry = S.pinEntry.slice(0, -1); S.pinError = null; render(); return; }
    if (S.pinEntry.length >= 4) return;
    S.pinEntry += digit; render();
    if (S.pinEntry.length === 4) {
      const h = await hashPin(S.pinEntry);
      if (h === S.settings.pinHash) { S.locked = false; S.pinEntry = ''; S.pinError = null; }
      else { S.pinError = 'That PIN is not right.'; S.pinEntry = ''; }
      render();
    }
  }
  async function pinSetupKey(digit) {
    const ps = S.pinSetup; if (!ps) return;
    if (digit === 'back') { ps.entry = ps.entry.slice(0, -1); render(); return; }
    if (ps.entry.length >= 4) return;
    ps.entry += digit; ps.error = null; render();
    if (ps.entry.length === 4) {
      if (ps.stage === 'enter') { ps.first = ps.entry; ps.entry = ''; ps.stage = 'confirm'; render(); return; }
      if (ps.entry === ps.first) { S.settings.pinHash = await hashPin(ps.entry); S.settings.pinLength = 4; await saveSettings(); S.pinSetup = null; S.ui.sheet = null; toast('PIN set. The app locks when you leave it.'); }
      else { ps.error = 'The PINs did not match. Start again.'; ps.entry = ''; ps.first = ''; ps.stage = 'enter'; }
      render();
    }
  }

  // ---------- actions ----------
  function confirm(opts) { S.ui.confirm = opts; if (opts.inline) render(); else { S.ui.sheet = 'confirm'; render(); } }
  const actions = {
    nav(el) { navigate({ name: el.dataset.route }); },
    back() { if (S.route.name === 'session') navigate({ name: 'sessions' }); else navigate({ name: 'settings' }); },
    finishOnboarding() { S.settings.hasSeenOnboarding = true; saveSettings(); render(); },
    openPreSession() { S.ui.form = { moodBefore: null }; S.ui.sheet = 'preSession'; render(); },
    closeSheet() { S.ui.sheet = null; S.ui.confirm = null; S.pinSetup = null; render(); },
    backdrop(el, ev) { if (ev.target === el && S.ui.sheet !== 'postSession') actions.closeSheet(); },
    mood(el) { const v = Number(el.dataset.value); S.ui.form[el.dataset.name] = S.ui.form[el.dataset.name] === v ? null : v; render(); },
    startSession() { startSession(); },
    pause() { if (S.rec) S.rec.pause(); },
    resume() { if (S.rec) S.rec.resume(); },
    finish() { confirm({ inline: true, title: 'Finish the session?', message: 'Recording stops and you can add how you feel now.', label: 'Finish', action: 'finishSession' }); },
    discard() { confirm({ inline: true, title: 'Discard this recording?', message: 'The audio and transcript so far will be deleted.', label: 'Discard', danger: true, action: 'discardSession' }); },
    closeConfirm() { S.ui.confirm = null; render(); },
    async confirmYes() { const c = S.ui.confirm; S.ui.confirm = null; if (!c) return; if (S.ui.sheet === 'confirm') S.ui.sheet = null; const fn = actions[c.action]; if (fn) await fn(c); else render(); },
    async finishSession() { await finishSession(); },
    async discardSession() { const rec = S.rec; S.rec = null; S.recUI = null; S.pending = null; render(); if (rec) await rec.cancel(); await DB.clearDraft().catch(() => {}); toast('Recording discarded.'); },
    async processSession() { await processSession(); },
    openPending() { const id = S.pending && S.pending.id; S.pending = null; S.ui.sheet = null; if (id) navigate({ name: 'session', id }); },
    closePending() { S.pending = null; S.ui.sheet = null; render(); },
    openSession(el) { navigate({ name: 'session', id: el.dataset.id }); },
    tab(el) { S.ui.tab = el.dataset.tab; S.ui.search = ''; S.ui.editingSegment = null; render(); },
    menu() { S.ui.menu = !S.ui.menu; render(); },
    rename() { const s = getSession(S.route.id); S.ui.menu = false; S.ui.form = { rename: s ? s.title : '' }; S.ui.sheet = 'rename'; render(); },
    async saveRename() { await updateSession(S.route.id, (s) => { s.title = (S.ui.form.rename || '').trim(); }); S.ui.sheet = null; render(); },
    async regenerate() { S.ui.menu = false; if (S.processing) return; await generateInsights(S.route.id, false); render(); toast('Insights updated.'); },
    exportReport() { const s = getSession(S.route.id); S.ui.menu = false; render(); if (s && Exporter.downloadText(Exporter.safeName(sessionTitle(s)) + '.md', Exporter.markdown(s), 'text/markdown')) toast('Report saved.'); },
    exportTranscript() { const s = getSession(S.route.id); S.ui.menu = false; render(); if (s && Exporter.downloadText(Exporter.safeName(sessionTitle(s)) + ' transcript.txt', Exporter.transcriptText(s), 'text/plain')) toast('Transcript saved.'); },
    async shareReport() { const s = getSession(S.route.id); S.ui.menu = false; render(); if (!s) return; const md = Exporter.markdown(s); const file = new File([md], Exporter.safeName(sessionTitle(s)) + '.md', { type: 'text/markdown' }); const ok = await Exporter.share({ title: sessionTitle(s), text: md, file }); if (!ok) { if (await Exporter.copy(md)) toast('Sharing is not available here; the report was copied instead.'); } },
    async copyReport() { const s = getSession(S.route.id); S.ui.menu = false; render(); if (s && await Exporter.copy(Exporter.markdown(s))) toast('Report copied.'); },
    async saveAudio() { const s = getSession(S.route.id); S.ui.menu = false; render(); if (!s) return; const rec = await DB.getAudio(s.id); if (rec && rec.blob) { Exporter.downloadBlob(Exporter.safeName(sessionTitle(s)) + '.' + Exporter.extensionFor(rec.mime), rec.blob); } else toast('No audio file found.'); },
    deleteAudio() { S.ui.menu = false; confirm({ title: 'Delete the audio?', message: 'The transcript, summary and notes stay.', label: 'Delete audio', danger: true, action: 'deleteAudioYes' }); },
    async deleteAudioYes() { const id = S.route.id; releasePlayer(); await DB.deleteAudio(id).catch(() => {}); await updateSession(id, (s) => { s.hasAudio = false; s.audioSize = 0; }); render(); toast('Audio deleted.'); },
    deleteSession() { S.ui.menu = false; confirm({ title: 'Delete this session?', message: 'Audio, transcript, summary and notes are removed from this device.', label: 'Delete session', danger: true, action: 'deleteSessionYes' }); },
    async deleteSessionYes() { const id = S.route.id; releasePlayer(); S.sessions = S.sessions.filter((s) => s.id !== id); await DB.deleteSession(id).catch(() => {}); navigate({ name: 'sessions' }); toast('Session deleted.'); },
    seek(el) { const a = document.getElementById('audio'); if (!a) return; a.currentTime = parseFloat(el.dataset.time) || 0; a.play().catch(() => {}); },
    rate(el) { S.player.rate = parseFloat(el.dataset.rate); const a = document.getElementById('audio'); if (a) a.playbackRate = S.player.rate; document.querySelectorAll('.rate button').forEach((b) => b.setAttribute('aria-pressed', String(parseFloat(b.dataset.rate) === S.player.rate))); },
    async toggleItem(el) { await updateSession(el.dataset.session, (s) => { const it = s.actionItems.find((a) => a.id === el.dataset.item); if (it) it.isDone = !it.isDone; }); render(); },
    async deleteItem(el) { await updateSession(S.route.id, (s) => { s.actionItems = s.actionItems.filter((a) => a.id !== el.dataset.item); }); render(); },
    async addItem(form) { const input = form.querySelector('input'); const text = input.value.trim(); if (!text) return; await updateSession(S.route.id, (s) => { s.actionItems.push({ id: uid(), text, isDone: false, source: 'manual', createdAt: new Date().toISOString() }); }); render(); },
    async adoptDetected(el) { const s = getSession(S.route.id); if (!s) return; const present = new Set(s.actionItems.map((a) => a.text.trim().toLowerCase())); const detected = (s.insights.detectedActionItems || []).filter((d) => !present.has(d.trim().toLowerCase())); const text = detected[Number(el.dataset.index)]; if (!text) return; await updateSession(s.id, (x) => { x.actionItems.push({ id: uid(), text, isDone: false, source: 'detected', createdAt: new Date().toISOString() }); }); render(); },
    async adoptSuggestion(el) { await updateSession(S.route.id, (s) => { const sg = (s.insights.suggestions || []).find((x) => x.id === el.dataset.id); if (sg && !s.actionItems.some((a) => a.text.trim().toLowerCase() === sg.title.trim().toLowerCase())) s.actionItems.push({ id: uid(), text: sg.title, isDone: false, source: 'suggestion', createdAt: new Date().toISOString() }); }); render(); toast('Added to commitments.'); },
    async saveQuestion(el) { await updateSession(S.route.id, (s) => { const sg = (s.insights.suggestions || []).find((x) => x.id === el.dataset.id); if (!sg) return; const q = sg.category === 'reflection' || sg.category === 'pattern' ? sg.title : sg.title; if (!s.nextSessionQuestions.some((x) => x.trim().toLowerCase() === q.trim().toLowerCase())) s.nextSessionQuestions.push(q); }); render(); toast('Saved for next session.'); },
    async addQuestion(form) { const input = form.querySelector('input'); const q = input.value.trim(); if (!q) return; await updateSession(S.route.id, (s) => { s.nextSessionQuestions.push(q); }); render(); },
    async removeQuestion(el) { await updateSession(S.route.id, (s) => { s.nextSessionQuestions.splice(Number(el.dataset.index), 1); }); render(); },
    async removePrepQuestion(el) { await updateSession(el.dataset.session, (s) => { s.nextSessionQuestions = s.nextSessionQuestions.filter((q) => q !== el.dataset.q); }); render(); },
    async addPrepQuestion(form) { const input = form.querySelector('input'); const q = input.value.trim(); if (!q || !S.sessions.length) return; await updateSession(S.sessions[0].id, (s) => { s.nextSessionQuestions.push(q); }); render(); },
    async addTag(form) { const input = form.querySelector('input'); const t = input.value.trim(); if (!t) return; await updateSession(S.route.id, (s) => { if (!s.tags.includes(t)) s.tags.push(t); }); render(); },
    async removeTag(el) { await updateSession(S.route.id, (s) => { s.tags.splice(Number(el.dataset.index), 1); }); render(); },
    editSegment(el) { S.ui.editingSegment = el.dataset.seg; render(); },
    cancelEdit() { S.ui.editingSegment = null; render(); },
    async saveSegment(el) { const ta = document.getElementById('seg-edit'); const text = ta ? ta.value.trim() : ''; await updateSession(S.route.id, (s) => { const g = s.segments.find((x) => x.id === el.dataset.seg); if (g) { if (text) g.text = text; else s.segments = s.segments.filter((x) => x.id !== g.id); } }); S.ui.editingSegment = null; render(); },
    async speaker(el) { await updateSession(S.route.id, (s) => { const g = s.segments.find((x) => x.id === el.dataset.seg); if (g) g.speaker = g.speaker === 'unknown' ? 'me' : (g.speaker === 'me' ? 'therapist' : 'unknown'); }); render(); },
    openJournal() { S.ui.form = { journalMood: null, journalText: '' }; S.ui.sheet = 'journal'; render(); },
    async saveJournal() { const f = S.ui.form; const text = (f.journalText || '').trim(); if (!text && !f.journalMood) { toast('Write a line or pick a mood first.'); return; } const e = { id: uid(), createdAt: new Date().toISOString(), mood: f.journalMood || null, text }; S.journal.unshift(e); await DB.saveJournalEntry(e).catch(() => toast('Could not save the entry.')); S.ui.sheet = null; render(); },
    async deleteJournal(el) { S.journal = S.journal.filter((j) => j.id !== el.dataset.id); await DB.deleteJournalEntry(el.dataset.id).catch(() => {}); render(); },
    async sharePrep() { const md = Exporter.prepSheet({ openItems: openItems(), questions: pendingQuestions(), themes: recurringThemes(), lastOverview: S.sessions[0] && S.sessions[0].insights ? S.sessions[0].insights.overview : '' }); const ok = await Exporter.share({ title: 'Prep for my next session', text: md, file: new File([md], 'Prep sheet.md', { type: 'text/markdown' }) }); if (!ok) { if (Exporter.downloadText('Prep sheet.md', md, 'text/markdown')) toast('Prep sheet saved.'); } },
    async toggleSetting(el) { const k = el.dataset.key; S.settings[k] = !S.settings[k]; await saveSettings(); render(); },
    async togglePin() { if (S.settings.pinHash) { S.settings.pinHash = null; S.settings.pinLength = 0; await saveSettings(); render(); toast('PIN removed.'); return; } if (!(crypto && crypto.subtle)) { toast('This browser cannot set a PIN securely.'); return; } S.pinSetup = { stage: 'enter', entry: '', first: '', error: null }; S.ui.sheet = 'pinSetup'; render(); },
    pinKey(el) { pinKey(el.dataset.digit); },
    pinSetupKey(el) { pinSetupKey(el.dataset.digit); },
    async downloadAI() { toast('Downloading the on-device model…'); try { S.ui.aiStatus = await OnDeviceAI.requestDownload(); } catch (e) { toast('The download did not start.'); } render(); },
    backup() { if (Exporter.downloadText('therapist-copilot-backup-' + new Date().toISOString().slice(0, 10) + '.json', Exporter.backup(S.sessions, S.journal, S.settings), 'application/json')) toast('Backup saved.'); },
    exportAll() { if (Exporter.downloadText('therapist-copilot-export.md', Exporter.fullExport(S.sessions, S.journal), 'text/markdown')) toast('Export saved.'); },
    confirmDeleteAll() { confirm({ title: 'Delete everything?', message: 'All sessions, audio, journal entries and settings on this device will be removed. This cannot be undone.', label: 'Delete all data', danger: true, action: 'deleteAllYes' }); },
    async deleteAllYes() { releasePlayer(); S.sessions = []; S.journal = []; const keep = { ...DEFAULTS, hasSeenOnboarding: true }; S.settings = keep; await DB.clearAll().catch(() => {}); await saveSettings(); navigate({ name: 'home' }); toast('All data deleted.'); }
  };

  async function restoreFromFile(file) {
    try {
      const text = await file.text();
      const data = Exporter.parseBackup(text);
      let added = 0;
      for (const s of data.sessions) { if (!getSession(s.id)) { s.hasAudio = false; s.audioSize = 0; S.sessions.push(s); await persistSession(s); added++; } }
      sortSessions();
      for (const j of data.journal) { if (!S.journal.some((x) => x.id === j.id)) { S.journal.push(j); await DB.saveJournalEntry(j).catch(() => {}); } }
      S.journal.sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));
      render();
      toast('Restored ' + Fmt.plural(added, 'session') + '. Audio files are not included in backups.');
    } catch (e) { toast(e.message || 'That file could not be restored.'); }
  }

  // ---------- events ----------
  const saveNotes = debounce((id, value) => { updateSession(id, (s) => { s.notes = value; }); }, 500);
  const saveTherapist = debounce((id, value) => { updateSession(id, (s) => { s.therapistName = value.trim(); }); }, 500);
  function onClick(ev) {
    const el = ev.target.closest('[data-action]');
    if (!el) { if (S.ui.menu && !ev.target.closest('.menu-anchor')) { S.ui.menu = false; render(); } return; }
    if (el.tagName === 'FORM') return;
    const name = el.dataset.action;
    if (name === 'backdrop') { actions.backdrop(el, ev); return; }
    if (el.disabled) return;
    const fn = actions[name];
    if (!fn) return;
    ev.preventDefault();
    Promise.resolve(fn(el, ev)).catch((e) => { console.error(e); toast('Something went wrong: ' + (e.message || e)); });
  }
  function onSubmit(ev) {
    const form = ev.target.closest('form[data-action]');
    if (!form) return;
    ev.preventDefault();
    const fn = actions[form.dataset.action];
    if (fn) Promise.resolve(fn(form, ev)).catch((e) => toast('Something went wrong: ' + (e.message || e)));
  }
  function onInput(ev) {
    const el = ev.target;
    if (el.dataset.form) { S.ui.form[el.dataset.form] = el.value; return; }
    const field = el.dataset.field;
    if (!field) return;
    if (field === 'search') { S.ui.search = el.value; const pos = el.selectionStart; render(); const again = document.getElementById('search'); if (again) { again.focus(); try { again.setSelectionRange(pos, pos); } catch (e) { /* ignore */ } } return; }
    if (field === 'notes') { saveNotes(S.route.id, el.value); return; }
    if (field === 'therapistName' && S.route.name === 'session') { saveTherapist(S.route.id, el.value); return; }
    if (field === 'therapistName') { S.settings.therapistName = el.value; saveSettings(); return; }
  }
  function onChange(ev) {
    const el = ev.target;
    const field = el.dataset.field;
    if (!field) return;
    if (field === 'language' || field === 'recordingMode' || field === 'enginePreference') { S.settings[field] = el.value; saveSettings(); render(); refreshStatuses(); return; }
    if (field === 'restore' && el.files && el.files[0]) { restoreFromFile(el.files[0]); el.value = ''; }
  }
  async function refreshStatuses() {
    try { S.ui.aiStatus = await OnDeviceAI.status(); } catch (e) { S.ui.aiStatus = { state: 'unsupported', label: 'Not available in this browser' }; }
    try {
      const a = await LiveTranscriber.localAvailability(S.settings.language);
      S.ui.localStatus = a === 'unsupported' ? null : ({ available: 'On-device recognition is available for this language.', downloadable: 'On-device recognition can be downloaded by the browser on first use.', downloading: 'The browser is downloading on-device recognition.', unavailable: 'On-device recognition is not available for this language; the browser\'s standard recognizer is used.' }[a] || null);
    } catch (e) { S.ui.localStatus = null; }
    try { S.ui.storage = await DB.estimate(); } catch (e) { S.ui.storage = null; }
    if (S.route.name === 'settings') render();
  }

  // ---------- init ----------
  async function init() {
    try { S.settings = { ...DEFAULTS, ...(await DB.loadSettings()) }; } catch (e) { /* defaults */ }
    try { S.sessions = await DB.loadSessions(); } catch (e) { S.sessions = []; }
    try { S.journal = await DB.loadJournal(); } catch (e) { S.journal = []; }
    S.locked = !!S.settings.pinHash;
    S.route = hashToRoute(location.hash);
    S.ready = true;
    render();
    document.addEventListener('click', onClick);
    document.addEventListener('submit', onSubmit);
    document.addEventListener('input', onInput);
    document.addEventListener('change', onChange);
    window.addEventListener('hashchange', () => { const r = hashToRoute(location.hash); if (JSON.stringify(r) !== JSON.stringify(S.route)) { S.ui.menu = false; S.ui.sheet = null; if (r.name !== 'session') releasePlayer(); S.route = r; render(); } });
    document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'hidden' && S.settings.pinHash && !S.rec) { S.locked = true; S.pinEntry = ''; render(); } });
    window.addEventListener('beforeunload', (e) => { if (S.rec) { e.preventDefault(); e.returnValue = ''; } });
    if (DB.volatile) toast('Storage is unavailable in this browser mode; sessions will not be kept after you close the tab.');
    await recoverDraft().catch(() => {});
    render();
    refreshStatuses();
    if ('serviceWorker' in navigator && /^https?:/.test(location.protocol)) {
      navigator.serviceWorker.register('./sw.js').then((reg) => {
        reg.addEventListener('updatefound', () => { const w = reg.installing; if (w) w.addEventListener('statechange', () => { if (w.state === 'installed' && navigator.serviceWorker.controller) toast('A new version is ready. Close and reopen the app to use it.'); }); });
      }).catch(() => {});
    }
  }
  document.addEventListener('DOMContentLoaded', () => { init().catch((e) => { console.error(e); S.ready = true; render(); toast('The app could not start cleanly: ' + (e.message || e)); }); });
  return { state: S, render, navigate, actions, toast, generateInsights };
})();
