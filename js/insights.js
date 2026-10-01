/* Classic insight engine: rule- and lexicon-based analysis of a transcript. Runs entirely in the browser.
   Produces: overview, highlights, themes, emotions, key moments, thinking patterns, commitments,
   suggestions, questions for next session, mood trajectory, crisis-language flag. */
const Insights = (() => {
  const NEGATORS = new Set(['not', 'no', 'never', 'dont', 'cant', 'cannot', 'isnt', 'wasnt', 'werent', 'didnt', 'wont', 'couldnt', 'shouldnt', 'wouldnt', 'nothing', 'hardly', 'without', 'neither', 'nor', 'aint', 'havent', 'hasnt', 'doesnt', 'arent', 'nobody', 'none', 'barely']);
  const INTENSIFIERS = new Set(['very', 'really', 'so', 'extremely', 'incredibly', 'totally', 'completely', 'absolutely', 'super', 'deeply', 'truly', 'quite']);
  const INSIGHT_PHRASES = ['i realized', 'i realised', 'i think the reason', 'i noticed', 'it makes sense', 'i never thought', 'i understand now', 'i see now', 'it clicked', 'i figured out', 'what i learned', 'i get it now', 'i didnt realize', 'i didnt realise', 'looking back', 'the pattern is', 'maybe the reason', 'now i see', 'that explains', 'i hadnt seen'];
  const BREAK_WORDS = new Set(['and', 'but', 'so', 'because', 'then', 'which', 'when', 'after', 'before', 'although', 'though', 'while']);

  function normalize(text) {
    return String(text || '').toLowerCase().replace(/[’'`‘]/g, '').replace(/[^\p{L}\p{N}]+/gu, ' ').replace(/\s+/g, ' ').trim();
  }
  function stem(w) {
    if (w.length <= 3) return w;
    if (w.endsWith('ies') && w.length > 4) return w.slice(0, -3) + 'y';
    if (w.endsWith('ing') && w.length > 5) { const b = w.slice(0, -3); return b.length > 2 && b[b.length - 1] === b[b.length - 2] ? b.slice(0, -1) : b; }
    if (w.endsWith('ed') && w.length > 4) { const b = w.slice(0, -2); return b.length > 2 && b[b.length - 1] === b[b.length - 2] ? b.slice(0, -1) : b; }
    if (w.endsWith('ly') && w.length > 4) return w.slice(0, -2);
    if (w.endsWith('es') && w.length > 4) return w.slice(0, -2);
    if (w.endsWith('s') && !w.endsWith('ss') && w.length > 3) return w.slice(0, -1);
    return w;
  }
  function words(text) { const n = normalize(text); return n ? n.split(' ') : []; }

  // Lexicon indexes built once
  function buildMatcher(list) {
    const single = new Set(), phrases = [];
    for (const raw of list) {
      const n = normalize(raw);
      if (!n) continue;
      if (n.includes(' ')) phrases.push(' ' + n + ' '); else { single.add(n); single.add(stem(n)); }
    }
    return { single, phrases };
  }
  const THEMES = Lexicon.themes.map((t) => ({ ...t, m: buildMatcher(t.keywords) }));
  const EMOTIONS = Lexicon.emotions.map((e) => ({ ...e, m: buildMatcher(e.keywords) }));
  const DISTORTIONS = Lexicon.distortions.map((d) => ({ ...d, m: buildMatcher(d.patterns) }));
  const COMMIT = buildMatcher(Lexicon.commitmentPatterns);
  const CRISIS = buildMatcher(Lexicon.crisisPatterns);
  const INSIGHT = buildMatcher(INSIGHT_PHRASES);
  const STOP = new Set([...Lexicon.stopWords, ...Lexicon.fillerWords].map(normalize));
  const POS = new Set(Lexicon.positiveWords.flatMap((w) => [normalize(w), stem(normalize(w))]));
  const NEG = new Set(Lexicon.negativeWords.flatMap((w) => [normalize(w), stem(normalize(w))]));

  function countMatches(sentence, m) {
    let n = 0;
    for (const w of sentence.toks) if (m.single.has(w) || m.single.has(stem(w))) n++;
    for (const p of m.phrases) { let i = sentence.padded.indexOf(p); while (i !== -1) { n++; i = sentence.padded.indexOf(p, i + 1); } }
    return n;
  }
  function hasMatch(sentence, m) { return countMatches(sentence, m) > 0; }

  function sentimentOf(sentence) {
    const toks = sentence.toks;
    let score = 0;
    for (let i = 0; i < toks.length; i++) {
      const w = toks[i], s = stem(w);
      let v = 0;
      if (POS.has(w) || POS.has(s)) v = 1; else if (NEG.has(w) || NEG.has(s)) v = -1;
      if (!v) continue;
      let mult = 1;
      for (let k = Math.max(0, i - 3); k < i; k++) { if (NEGATORS.has(toks[k])) mult *= -1; if (INTENSIFIERS.has(toks[k])) mult *= 1.5; }
      score += v * mult;
    }
    for (const e of EMOTIONS) { const c = countMatches(sentence, e.m); if (c) score += c * e.valence * 0.8; }
    const denom = Math.sqrt(toks.length) + 1;
    return clamp(score / denom, -1, 1);
  }

  function splitSentences(text, lang) {
    const out = [];
    let pieces = null;
    try {
      if (typeof Intl !== 'undefined' && Intl.Segmenter) {
        const seg = new Intl.Segmenter(lang || 'en', { granularity: 'sentence' });
        pieces = Array.from(seg.segment(text), (s) => s.segment);
      }
    } catch (e) { pieces = null; }
    if (!pieces) pieces = text.match(/[^.!?]+[.!?]+["')\]]*|[^.!?]+$/g) || [text];
    for (const p of pieces) {
      const t = p.trim();
      if (!t) continue;
      const ws = t.split(/\s+/);
      if (ws.length <= 28) { out.push(t); continue; }
      // Long unpunctuated run (common with speech recognition): break at conjunctions, hard cap 25 words.
      let cur = [];
      for (const w of ws) {
        const bare = normalize(w);
        if (cur.length >= 12 && BREAK_WORDS.has(bare)) { out.push(cur.join(' ')); cur = [w]; continue; }
        cur.push(w);
        if (cur.length >= 25) { out.push(cur.join(' ')); cur = []; }
      }
      if (cur.length) out.push(cur.join(' '));
    }
    return out;
  }

  function buildSentences(session) {
    const lang = (session.language || 'en').slice(0, 2);
    const segs = (session.segments || []).filter((g) => String(g.text || '').trim());
    if (!segs.length) return [];
    // Concatenate the transcript and remember where each segment starts, so sentences can span segment boundaries.
    let full = '';
    const spans = [];
    for (const g of segs) {
      const text = String(g.text).trim();
      if (full) full += ' ';
      spans.push({ from: full.length, to: full.length + text.length, start: g.start || 0, end: Math.max(g.end || 0, g.start || 0) });
      full += text;
    }
    const timeAt = (offset) => {
      let sp = spans[spans.length - 1];
      for (const x of spans) { if (offset >= x.from && offset <= x.to) { sp = x; break; } if (offset < x.from) { sp = x; break; } }
      const frac = sp.to > sp.from ? clamp((offset - sp.from) / (sp.to - sp.from), 0, 1) : 0;
      return sp.start + frac * Math.max(0, sp.end - sp.start);
    };
    const sentences = [];
    let cursor = 0;
    for (const p of splitSentences(full, lang)) {
      let idx = full.indexOf(p, cursor);
      if (idx === -1) idx = cursor;
      cursor = idx + p.length;
      const toks = words(p);
      if (toks.length < 3) continue;
      const s = { text: trimDangling(p), time: timeAt(idx), toks, padded: ' ' + toks.join(' ') + ' ' };
      s.content = toks.map(stem).filter((w) => w.length > 2 && !STOP.has(w));
      s.sentiment = sentimentOf(s);
      sentences.push(s);
    }
    return sentences;
  }

  const DANGLING = new Set(['to', 'with', 'of', 'and', 'the', 'a', 'an', 'in', 'on', 'at', 'for', 'or', 'but', 'so', 'that', 'instead', 'because', 'which', 'when', 'if', 'like', 'about', 'from', 'as', 'than', 'then', 'just', 'really', 'very', 'i', 'im', 'my', 'is', 'was', 'be', 'it', 'its']);
  function trimDangling(text) {
    let t = String(text || '').trim().replace(/[\s,;:\-–—]+$/g, '');
    for (let guard = 0; guard < 6; guard++) {
      const m = t.match(/(\S+)$/);
      if (!m) break;
      const last = normalize(m[1]);
      if (!DANGLING.has(last)) break;
      t = t.slice(0, m.index).trim().replace(/[\s,;:\-–—]+$/g, '');
    }
    return t;
  }

  function capitalize(t) { t = t.trim().replace(/^["'“‘]+|["'”’]+$/g, ''); return t ? t[0].toUpperCase() + t.slice(1) : t; }
  function tidy(t) { t = capitalize(t); if (t && !/[.!?]$/.test(t)) t += '.'; return t; }
  function trimTo(t, n) { return t.length <= n ? t : t.slice(0, n - 1).replace(/\s+\S*$/, '') + '…'; }
  function fill(template, n, theme) {
    return String(template || '')
      .replace(/\{n\} times?/g, n === 1 ? 'once' : n + ' times')
      .replace(/\{n\}/g, String(n))
      .replace(/\{theme\}/g, theme);
  }
  function joinList(items) {
    if (!items.length) return '';
    if (items.length === 1) return items[0];
    if (items.length === 2) return items[0] + ' and ' + items[1];
    return items.slice(0, -1).join(', ') + ' and ' + items[items.length - 1];
  }
  function lower(s) { return s.replace(/^([A-Z])(?![A-Z])/, (m) => m.toLowerCase()); }

  function empty(language) {
    return {
      engine: 'classic', generatedAt: new Date().toISOString(),
      overview: 'No transcript was captured for this session, so there is nothing to analyze yet. You can still listen to the recording and write notes.',
      highlights: [], themes: [], emotions: [], keyMoments: [], thoughtPatterns: [], suggestions: [], detectedActionItems: [],
      questionsForNextSession: [], moodTrajectory: [], overallSentiment: 0, needsSupportFlag: false, languageNote: null, wordCount: 0
    };
  }

  function analyze(session, history) {
    history = history || [];
    const sentences = buildSentences(session);
    const language = session.language || 'en-US';
    if (!sentences.length) return empty(language);
    const fullText = ' ' + normalize((session.segments || []).map((s) => s.text).join(' ')) + ' ';
    const wordCount = fullText.trim().split(' ').filter(Boolean).length;
    const minutes = Math.max(1, Math.round((session.duration || 0) / 60));

    // Themes
    const themeHits = THEMES.map((t) => {
      let mentions = 0; let quote = null; const hitSentences = [];
      for (const s of sentences) { const c = countMatches(s, t.m); if (c) { mentions += c; hitSentences.push(s); } }
      if (hitSentences.length) {
        const good = hitSentences.filter((s) => s.toks.length >= 6).sort((a, b) => a.toks.length - b.toks.length);
        quote = (good[0] || hitSentences[0]).text;
      }
      return { def: t, mentions, quote, hitSentences };
    }).filter((t) => t.mentions > 0).sort((a, b) => b.mentions - a.mentions);
    let keptThemes = themeHits.filter((t) => t.mentions >= 2);
    if (!keptThemes.length) keptThemes = themeHits.slice(0, 3);
    keptThemes = keptThemes.slice(0, 6);
    const themeSet = new Set(keptThemes.map((t) => t.def));

    // Emotions
    const emotionHits = EMOTIONS.map((e) => ({ def: e, mentions: sentences.reduce((a, s) => a + countMatches(s, e.m), 0) })).filter((e) => e.mentions > 0).sort((a, b) => b.mentions - a.mentions).slice(0, 6);
    const maxEm = emotionHits.length ? emotionHits[0].mentions : 1;
    const emotions = emotionHits.map((e) => ({ name: e.def.name, intensity: Math.round((e.mentions / maxEm) * 100) / 100, mentions: e.mentions }));

    // Thinking patterns
    const thoughtPatterns = [];
    for (const d of DISTORTIONS) {
      const hit = sentences.find((s) => hasMatch(s, d.m));
      if (hit) thoughtPatterns.push({ name: d.name, description: d.description, quote: capitalize(trimTo(hit.text, 200)), reframe: d.reframe, _s: hit });
      if (thoughtPatterns.length >= 4) break;
    }

    // Commitments
    const seenCommit = new Set();
    const detectedActionItems = [];
    const commitSentences = new Set();
    for (const s of sentences) {
      if (!hasMatch(s, COMMIT)) continue;
      commitSentences.add(s);
      const txt = tidy(trimTo(s.text, 160));
      const key = normalize(txt);
      if (seenCommit.has(key)) continue;
      seenCommit.add(key);
      detectedActionItems.push(txt);
      if (detectedActionItems.length >= 8) break;
    }

    // Key moments
    const distortionSentences = new Set(thoughtPatterns.map((p) => p._s));
    const scored = sentences.map((s) => {
      const themeHitsHere = keptThemes.reduce((a, t) => a + countMatches(s, t.def.m), 0);
      const insight = hasMatch(s, INSIGHT);
      const commit = commitSentences.has(s);
      const distortion = distortionSentences.has(s);
      let score = Math.abs(s.sentiment) * 2 + themeHitsHere * 0.5 + (commit ? 1.5 : 0) + (distortion ? 1 : 0) + (insight ? 1.5 : 0);
      if (s.toks.length < 5) score *= 0.6;
      let reason = 'Core theme';
      if (insight) reason = 'Insight'; else if (commit) reason = 'Commitment'; else if (Math.abs(s.sentiment) >= 0.35) reason = 'Strong emotion'; else if (distortion) reason = 'Thinking pattern';
      return { s, score, reason };
    }).filter((x) => x.score > 0.6).sort((a, b) => b.score - a.score).slice(0, 5).sort((a, b) => a.s.time - b.s.time);
    const keyMoments = scored.map((x) => ({ time: x.s.time, text: capitalize(trimTo(x.s.text, 220)), reason: x.reason }));

    // Highlights (extractive)
    const freq = new Map();
    for (const s of sentences) for (const w of s.content) freq.set(w, (freq.get(w) || 0) + 1);
    const n = sentences.length;
    const hl = sentences.map((s, i) => {
      let sum = 0; for (const w of s.content) sum += (freq.get(w) || 0);
      let score = s.content.length ? sum / Math.sqrt(s.content.length + 1) : 0;
      if (i < n * 0.1 || i > n * 0.9) score += 0.3;
      score += keptThemes.reduce((a, t) => a + (hasMatch(s, t.def.m) ? 0.8 : 0), 0);
      if (s.toks.length < 6) score *= 0.5;
      return { s, score };
    }).sort((a, b) => b.score - a.score);
    const highlights = [];
    const usedKeys = new Set();
    for (const h of hl) {
      const key = h.s.content.slice(0, 6).join(' ');
      if (usedKeys.has(key)) continue;
      usedKeys.add(key);
      highlights.push(h);
      if (highlights.length >= 5) break;
    }
    highlights.sort((a, b) => a.s.time - b.s.time);
    const highlightTexts = highlights.map((h) => tidy(trimTo(h.s.text, 180)));

    // Mood trajectory (8 buckets)
    const span = Math.max(session.duration || 0, (sentences[sentences.length - 1].time || 0) + 1, 1);
    const buckets = Array.from({ length: 8 }, () => []);
    for (const s of sentences) { const b = Math.min(7, Math.floor((s.time / span) * 8)); buckets[b].push(s.sentiment); }
    const traj = buckets.map((b) => (b.length ? b.reduce((a, v) => a + v, 0) / b.length : null));
    for (let i = 0; i < traj.length; i++) {
      if (traj[i] != null) continue;
      let l = i - 1; while (l >= 0 && traj[l] == null) l--;
      let r = i + 1; while (r < traj.length && traj[r] == null) r++;
      const lv = l >= 0 ? traj[l] : null, rv = r < traj.length ? traj[r] : null;
      traj[i] = lv != null && rv != null ? lv + ((rv - lv) * (i - l)) / (r - l) : (lv != null ? lv : (rv != null ? rv : 0));
    }
    const moodTrajectory = traj.map((v) => Math.round(v * 100) / 100);
    const overallSentiment = Math.round((sentences.reduce((a, s) => a + s.sentiment, 0) / sentences.length) * 100) / 100;
    const q = Math.max(1, Math.floor(sentences.length / 4));
    const firstQ = sentences.slice(0, q).reduce((a, s) => a + s.sentiment, 0) / q;
    const lastQ = sentences.slice(-q).reduce((a, s) => a + s.sentiment, 0) / q;
    const trend = lastQ - firstQ > 0.12 ? 'lifted' : (lastQ - firstQ < -0.12 ? 'dipped' : 'steady');

    // Overview
    const themeNames = keptThemes.slice(0, 3).map((t) => lower(t.def.name));
    const emotionNames = emotions.slice(0, 2).map((e) => e.name.toLowerCase());
    const parts = [];
    let first = 'In this ' + minutes + '-minute session you ';
    first += themeNames.length ? 'mainly talked about ' + joinList(themeNames) + '.' : 'covered a lot of ground.';
    parts.push(first);
    if (emotionNames.length) {
      const em = joinList(emotionNames);
      const toneWord = trend === 'lifted' ? 'and the tone lifted toward the end' : (trend === 'dipped' ? 'and the tone grew heavier toward the end' : 'and the tone stayed fairly steady throughout');
      parts.push(capitalize(em) + ' came through most often, ' + toneWord + '.');
    } else {
      parts.push(trend === 'lifted' ? 'The tone lifted toward the end.' : (trend === 'dipped' ? 'The tone grew heavier toward the end.' : 'The tone stayed fairly steady throughout.'));
    }
    if (detectedActionItems.length) parts.push('You made ' + Fmt.plural(detectedActionItems.length, 'commitment') + ' for the time until your next session.');
    if (thoughtPatterns.length) parts.push('A few thinking patterns showed up that might be worth a gentle second look.');
    const overview = parts.join(' ');

    // Suggestions
    const suggestions = [];
    const titles = new Set();
    const titleKey = (t) => words(t).map(stem).filter((w) => !STOP.has(w) && w.length > 2).sort().join(' ');
    const push = (sug) => { if (!sug.title) return; const k = titleKey(sug.title); if (titles.has(k)) return; titles.add(k); suggestions.push({ id: 'sg-' + suggestions.length, ...sug }); };
    for (const t of keptThemes) {
      for (const s of (t.def.suggestions || []).slice(0, 2)) push({ category: s.category, title: s.title, detail: s.detail, rationale: fill(s.rationale, t.mentions, t.def.name) });
    }
    const emotionDriven = {
      Overwhelmed: { category: 'practice', title: 'Name five things you can see, four you can touch', detail: 'When everything feels like too much, slow down with 5-4-3-2-1 grounding: five things you see, four you can feel, three you hear, two you smell, one you taste. It pulls attention out of the spiral and into the room.', rationale: 'Feeling overwhelmed came up {n} times.' },
      Anxious: { category: 'practice', title: 'Give the adrenaline somewhere to go', detail: 'When anxiety peaks, do one physical thing for five minutes: wash the dishes, walk around the block, take a shower. The body is primed to move; letting it usually shortens the spike.', rationale: 'Anxiety came through {n} times.' },
      Exhausted: { category: 'selfCare', title: 'Protect one early night this week', detail: 'Pick a night, decide the time you will be in bed, and tell someone. Tiredness makes every other problem louder.', rationale: 'Exhaustion came up {n} times.' },
      Lonely: { category: 'practice', title: 'Send one low-stakes message today', detail: 'Not a plan, not a big talk: a photo, a memory, a question. Connection usually restarts with something small.', rationale: 'Loneliness came up {n} times.' },
      Ashamed: { category: 'reflection', title: 'Write what you would say to a friend in your place', detail: 'Describe the situation as if it happened to someone you care about, then write them two sentences. Read them back to yourself.', rationale: 'Shame or self-criticism came up {n} times.' },
      Angry: { category: 'practice', title: 'Catch anger at the first sign in your body', detail: 'Notice the earliest physical cue (jaw, chest, heat) and take a 10-minute break before responding. Decide what you want the outcome to be before you speak.', rationale: 'Anger or irritability came up {n} times.' },
      Hopeful: { category: 'reflection', title: 'Write down what gave you hope today', detail: 'Hope tends to evaporate by midweek. One or two lines about what felt possible in this session keeps it reachable.', rationale: 'Hope came through {n} times.' },
      Sad: { category: 'selfCare', title: 'Plan one small pleasant activity', detail: 'Choose something short and concrete for tomorrow (a walk, a call, music). Mood often follows action rather than the other way round.', rationale: 'Sadness came up {n} times.' },
      Guilty: { category: 'reflection', title: 'Separate what you did from who you are', detail: 'Write the specific action you feel guilty about, what you can repair or learn, and one sentence that is true about you beyond that moment.', rationale: 'Guilt came up {n} times.' }
    };
    let emotionAdded = 0;
    for (const e of emotionHits) { const d = emotionDriven[e.def.name]; if (d && emotionAdded < 2) { push({ ...d, rationale: fill(d.rationale, e.mentions, e.def.name) }); emotionAdded++; } }
    for (const p of thoughtPatterns) {
      push({ category: 'reflection', title: 'Look again at a moment of ' + lower(p.name), detail: p.reframe, rationale: 'You said: “' + trimTo(p.quote, 120) + '”' });
    }
    // Cross-session patterns
    const recent = history.filter((h) => h && h.insights && h.insights.themes).slice(0, 6);
    for (const t of keptThemes) {
      const count = recent.filter((h) => h.insights.themes.some((x) => x.name === t.def.name)).length;
      if (count >= 2) {
        push({ category: 'pattern', title: t.def.name + ' keeps coming back', detail: t.def.name + ' has come up in ' + count + ' of your last ' + recent.length + ' sessions as well as this one. It might be worth asking your therapist whether this deserves a session of its own, or whether something underneath it connects them.', rationale: 'Seen in ' + (count + 1) + ' of your last ' + (recent.length + 1) + ' sessions.' });
      }
    }
    for (const g of Lexicon.generalSuggestions.slice(0, 2)) push({ category: g.category, title: g.title, detail: g.detail, rationale: fill(g.rationale, detectedActionItems.length, 'this session') });
    const finalSuggestions = suggestions.slice(0, 10);

    // Questions for next session
    const questions = [];
    const qSeen = new Set();
    for (const t of keptThemes) for (const qq of (t.def.questions || []).slice(0, 1)) { const k = normalize(qq); if (!qSeen.has(k)) { qSeen.add(k); questions.push(qq); } }
    for (const t of keptThemes) for (const qq of (t.def.questions || []).slice(1, 2)) { if (questions.length >= 4) break; const k = normalize(qq); if (!qSeen.has(k)) { qSeen.add(k); questions.push(qq); } }
    for (const p of thoughtPatterns) { if (questions.length >= 6) break; questions.push('Could we look at the thought “' + trimTo(p.quote, 90) + '” together?'); }

    const needsSupportFlag = CRISIS.phrases.some((p) => fullText.includes(p)) || fullText.split(' ').some((w) => CRISIS.single.has(w));
    const langCode = language.slice(0, 2).toLowerCase();
    const languageNote = langCode && langCode !== 'en' ? 'Insights are tuned for English transcripts; results for ' + Fmt.languageName(language) + ' will be rougher.' : null;

    return {
      engine: 'classic', generatedAt: new Date().toISOString(), overview, highlights: highlightTexts,
      themes: keptThemes.map((t) => ({ name: t.def.name, mentions: t.mentions, quote: t.quote ? capitalize(trimTo(t.quote, 200)) : null })),
      emotions, keyMoments, thoughtPatterns: thoughtPatterns.map(({ _s, ...p }) => p), suggestions: finalSuggestions,
      detectedActionItems, questionsForNextSession: questions, moodTrajectory, overallSentiment, needsSupportFlag, languageNote, wordCount
    };
  }

  return { analyze, empty, normalize, stem, splitSentences };
})();
