/* Optional enrichment with the browser's built-in on-device language model (Chrome's Prompt API).
   Everything is feature-detected; when the API is missing the Classic engine's result is used as is.
   Nothing leaves the device: the model runs inside the browser. */
const OnDeviceAI = (() => {
  const INSTRUCTIONS = 'You help a person reflect on their own therapy session. Write in second person, warm and plain. Never diagnose, never give medical or medication advice, never judge the therapist. Keep each list item under 25 words. If the text mentions self-harm, respond with care and suggest contacting a crisis line, without alarm. Output only what is asked.';
  const SCHEMA = {
    type: 'object',
    properties: {
      overview: { type: 'string' },
      highlights: { type: 'array', items: { type: 'string' } },
      suggestions: { type: 'array', items: { type: 'string' } },
      questionsForNextSession: { type: 'array', items: { type: 'string' } },
      detectedCommitments: { type: 'array', items: { type: 'string' } }
    },
    required: ['overview', 'highlights', 'suggestions', 'questionsForNextSession', 'detectedCommitments']
  };

  function api() {
    if (typeof self !== 'undefined' && self.LanguageModel && typeof self.LanguageModel.create === 'function') return self.LanguageModel;
    if (typeof self !== 'undefined' && self.ai && self.ai.languageModel && typeof self.ai.languageModel.create === 'function') return self.ai.languageModel;
    return null;
  }

  async function status() {
    const LM = api();
    if (!LM) return { state: 'unsupported', label: 'Not available in this browser (Chrome on desktop offers it)' };
    try {
      const a = typeof LM.availability === 'function' ? await LM.availability() : (typeof LM.capabilities === 'function' ? (await LM.capabilities()).available : 'unavailable');
      const map = { available: 'Available', readily: 'Available', downloadable: 'Available after a one-time model download', 'after-download': 'Available after a one-time model download', downloading: 'Model is downloading', unavailable: 'Not supported on this device', no: 'Not supported on this device' };
      const norm = a === 'readily' ? 'available' : (a === 'after-download' ? 'downloadable' : (a === 'no' ? 'unavailable' : a));
      return { state: norm, label: map[a] || 'Unavailable' };
    } catch (e) { return { state: 'unavailable', label: 'Unavailable' }; }
  }

  async function createSession(monitor) {
    const LM = api();
    const opts = { initialPrompts: [{ role: 'system', content: INSTRUCTIONS }] };
    if (monitor) opts.monitor = monitor;
    try { return await LM.create(opts); } catch (e) {
      return await LM.create({ systemPrompt: INSTRUCTIONS });
    }
  }

  async function requestDownload(onProgress) {
    const s = await status();
    if (s.state !== 'downloadable' && s.state !== 'downloading') return s;
    const session = await createSession((m) => { try { m.addEventListener('downloadprogress', (e) => onProgress && onProgress(e.loaded, e.total)); } catch (e) { /* ignore */ } });
    try { session.destroy && session.destroy(); } catch (e) { /* ignore */ }
    return status();
  }

  function chunkWords(text, size) {
    const w = text.split(/\s+/).filter(Boolean);
    const out = [];
    for (let i = 0; i < w.length; i += size) out.push(w.slice(i, i + size).join(' '));
    return out;
  }
  function parseJSON(text) {
    try { return JSON.parse(text); } catch (e) { /* fall through */ }
    const m = text.match(/\{[\s\S]*\}/);
    if (m) { try { return JSON.parse(m[0]); } catch (e) { /* ignore */ } }
    return null;
  }
  function cleanList(a, cap) { return Array.isArray(a) ? a.map((x) => String(x || '').trim()).filter(Boolean).slice(0, cap) : []; }

  async function enrich(base, session) {
    const LM = api();
    if (!LM) throw new Error('No on-device model');
    const transcript = (session.segments || []).map((s) => s.text).join(' ').trim();
    if (!transcript) throw new Error('No transcript');
    const chunks = chunkWords(transcript, 1200);
    let material;
    if (chunks.length === 1) {
      material = 'Transcript of the session:\n\n' + chunkWords(transcript, 1500)[0];
    } else {
      const notes = [];
      for (let i = 0; i < chunks.length && i < 10; i++) {
        const s = await createSession();
        try {
          const r = await s.prompt('Here is part ' + (i + 1) + ' of ' + chunks.length + ' of a therapy session transcript (speakers are not labeled). Write 3 to 6 concise bullet notes capturing what was discussed, feelings expressed, insights, and any commitments.\n\n' + chunks[i]);
          notes.push(String(r || ''));
        } finally { try { s.destroy && s.destroy(); } catch (e) { /* ignore */ } }
      }
      material = 'Notes from the parts of the session, in order:\n\n' + notes.join('\n\n');
    }
    const prompt = material + '\n\nUsing only this material, return JSON with: "overview" (3 to 5 sentences, second person, what the session was about and how it moved), "highlights" (3 to 7 short bullets of what was discussed), "suggestions" (3 to 6 gentle, practical suggestions for the week ahead, each one or two sentences), "questionsForNextSession" (2 to 5 questions worth bringing to the next session), "detectedCommitments" (concrete things the person said they would do, as short imperative sentences; empty if none).';
    const s = await createSession();
    let raw;
    try {
      try { raw = await s.prompt(prompt, { responseConstraint: SCHEMA }); } catch (e) { raw = await s.prompt(prompt + '\n\nRespond with JSON only.'); }
    } finally { try { s.destroy && s.destroy(); } catch (e) { /* ignore */ } }
    const data = parseJSON(String(raw || ''));
    if (!data || typeof data.overview !== 'string' || !data.overview.trim()) throw new Error('Model returned no usable summary');

    const out = { ...base, engine: 'onDeviceModel', generatedAt: new Date().toISOString() };
    out.overview = data.overview.trim();
    const hl = cleanList(data.highlights, 7);
    if (hl.length) out.highlights = hl;
    const practiceWords = ['try', 'practice', 'write', 'schedule', 'breath', 'walk', 'exercise', 'set ', 'plan', 'list', 'notice'];
    const modelSuggestions = cleanList(data.suggestions, 6).map((t, i) => {
      const lowerT = t.toLowerCase();
      const cat = practiceWords.some((w) => lowerT.includes(w)) ? 'practice' : 'reflection';
      const firstStop = t.search(/[.!?](\s|$)/);
      const title = firstStop > 0 && firstStop < 90 ? t.slice(0, firstStop) : (t.length > 70 ? t.slice(0, 69).replace(/\s+\S*$/, '') + '…' : t);
      return { id: 'ai-' + i, category: cat, title, detail: t, rationale: 'Suggested by the on-device model from this session\'s transcript.' };
    });
    const titles = new Set(modelSuggestions.map((s) => s.title.toLowerCase()));
    const kept = (base.suggestions || []).filter((s) => s.category === 'pattern' && !titles.has(s.title.toLowerCase()));
    const extra = (base.suggestions || []).filter((s) => s.category !== 'pattern' && !titles.has(s.title.toLowerCase())).slice(0, 3);
    out.suggestions = [...modelSuggestions, ...kept, ...extra].slice(0, 10);
    const qs = cleanList(data.questionsForNextSession, 5);
    const qSeen = new Set(qs.map((q) => q.toLowerCase()));
    out.questionsForNextSession = [...qs, ...(base.questionsForNextSession || []).filter((q) => !qSeen.has(q.toLowerCase()))].slice(0, 6);
    const commits = cleanList(data.detectedCommitments, 8);
    const cSeen = new Set(commits.map((c) => c.toLowerCase()));
    out.detectedActionItems = [...commits, ...(base.detectedActionItems || []).filter((c) => !cSeen.has(c.toLowerCase()))].slice(0, 8);
    return out;
  }

  return { status, enrich, requestDownload, isSupported: () => !!api() };
})();
