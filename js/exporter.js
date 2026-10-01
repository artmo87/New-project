/* Exports: Markdown reports, transcript text, prep sheet, full backup/restore, plus download/share/copy helpers. */
const Exporter = (() => {
  function mood(m) { return m ? m + '/10 ' + MoodScale.emoji(m) : '—'; }
  function speakerPrefix(s) { return s === 'me' ? 'Me: ' : (s === 'therapist' ? 'Therapist: ' : ''); }
  function title(session) { return (session.title || '').trim() || 'Session · ' + Fmt.shortDate(session.createdAt); }

  function transcriptText(session) {
    const lines = (session.segments || []).map((s) => '[' + Fmt.clock(s.start) + '] ' + speakerPrefix(s.speaker) + s.text);
    return lines.length ? lines.join('\n') : '(No transcript was captured for this session.)';
  }

  function report(session, opts) {
    const ins = session.insights;
    const L = [];
    L.push('# ' + title(session));
    L.push('');
    L.push('- **When:** ' + Fmt.dateTime(session.createdAt));
    L.push('- **Duration:** ' + Fmt.durationWords(session.duration || 0));
    if (session.therapistName) L.push('- **Therapist:** ' + session.therapistName);
    L.push('- **Mood before:** ' + mood(session.moodBefore) + '  ·  **Mood after:** ' + mood(session.moodAfter));
    if (session.tags && session.tags.length) L.push('- **Tags:** ' + session.tags.join(', '));
    L.push('');
    if (ins) {
      L.push('## Overview'); L.push(''); L.push(ins.overview); L.push('');
      L.push('_Generated with ' + (ins.engine === 'onDeviceModel' ? 'the on-device model' : 'classic analysis') + ' on ' + Fmt.dateTime(ins.generatedAt) + '._'); L.push('');
      if (ins.highlights && ins.highlights.length) { L.push('## Highlights'); L.push(''); ins.highlights.forEach((h) => L.push('- ' + h)); L.push(''); }
      if (ins.themes && ins.themes.length) { L.push('## Themes'); L.push(''); ins.themes.forEach((t) => L.push('- **' + t.name + '** (' + t.mentions + ')' + (t.quote ? ' — “' + t.quote + '”' : ''))); L.push(''); }
      if (ins.emotions && ins.emotions.length) { L.push('## Emotions'); L.push(''); L.push(ins.emotions.map((e) => e.name + ' (' + e.mentions + ')').join(', ')); L.push(''); }
      if (ins.keyMoments && ins.keyMoments.length) { L.push('## Key moments'); L.push(''); ins.keyMoments.forEach((k) => L.push('- [' + Fmt.clock(k.time || 0) + '] _' + k.reason + '_ — ' + k.text)); L.push(''); }
      if (ins.thoughtPatterns && ins.thoughtPatterns.length) { L.push('## Thinking patterns'); L.push(''); ins.thoughtPatterns.forEach((p) => { L.push('- **' + p.name + '** — “' + p.quote + '”'); L.push('  - Another way to see it: ' + p.reframe); }); L.push(''); }
    }
    if (session.actionItems && session.actionItems.length) { L.push('## Commitments'); L.push(''); session.actionItems.forEach((a) => L.push('- [' + (a.isDone ? 'x' : ' ') + '] ' + a.text)); L.push(''); }
    if (ins && ins.suggestions && ins.suggestions.length) {
      L.push('## Suggestions'); L.push('');
      ins.suggestions.forEach((s) => { L.push('- **' + s.title + '** (' + (CategoryMeta[s.category] ? CategoryMeta[s.category].label : s.category) + ')'); L.push('  ' + s.detail); L.push('  _' + s.rationale + '_'); });
      L.push('');
    }
    if (session.nextSessionQuestions && session.nextSessionQuestions.length) { L.push('## Questions for next session'); L.push(''); session.nextSessionQuestions.forEach((q) => L.push('- ' + q)); L.push(''); }
    if ((session.notes || '').trim()) { L.push('## Notes'); L.push(''); L.push(session.notes.trim()); L.push(''); }
    if (!opts || opts.transcript !== false) { L.push('## Transcript'); L.push(''); L.push(transcriptText(session)); L.push(''); }
    return L.join('\n');
  }

  function markdown(session) { return report(session) + '\n---\n_Exported from Therapist Copilot. This is a personal reflection aid, not medical advice._\n'; }

  function prepSheet(data) {
    const L = ['# Prep for my next session', '', '_' + Fmt.dateTime(new Date()) + '_', ''];
    L.push('## Open commitments'); L.push('');
    if (data.openItems.length) data.openItems.forEach((o) => L.push('- [ ] ' + o.item.text + '  _(' + o.sessionTitle + ')_')); else L.push('- Nothing open.');
    L.push(''); L.push('## Questions to bring'); L.push('');
    if (data.questions.length) data.questions.forEach((q) => L.push('- ' + q.question)); else L.push('- None saved yet.');
    L.push(''); L.push('## Recurring themes'); L.push('');
    if (data.themes.length) data.themes.forEach((t) => L.push('- ' + t.name + ' (' + t.sessionCount + ' sessions)')); else L.push('- Not enough sessions yet.');
    if (data.lastOverview) { L.push(''); L.push('## Last session'); L.push(''); L.push(data.lastOverview); }
    L.push('');
    return L.join('\n');
  }

  function fullExport(sessions, journal) {
    const L = ['# Therapist Copilot — full export', '', '_' + Fmt.dateTime(new Date()) + ' · ' + Fmt.plural(sessions.length, 'session') + ', ' + Fmt.plural(journal.length, 'journal entry').replace('entrys', 'entries') + '_', ''];
    for (const s of sessions.slice().sort((a, b) => new Date(a.createdAt) - new Date(b.createdAt))) { L.push(report(s)); L.push(''); L.push('---'); L.push(''); }
    if (journal.length) {
      L.push('# Journal'); L.push('');
      for (const j of journal.slice().sort((a, b) => new Date(a.createdAt) - new Date(b.createdAt))) { L.push('## ' + Fmt.dateTime(j.createdAt) + (j.mood ? ' · mood ' + j.mood + '/10' : '')); L.push(''); L.push(j.text); L.push(''); }
    }
    return L.join('\n');
  }

  function backup(sessions, journal, settings) {
    return JSON.stringify({ app: 'therapist-copilot', version: 1, exportedAt: new Date().toISOString(), sessions, journal, settings: settings || {} }, null, 1);
  }
  function parseBackup(text) {
    const data = JSON.parse(text);
    if (!data || data.app !== 'therapist-copilot' || !Array.isArray(data.sessions)) throw new Error('This file is not a Therapist Copilot backup.');
    return { sessions: data.sessions, journal: Array.isArray(data.journal) ? data.journal : [], settings: data.settings || {} };
  }

  function safeName(name) { return String(name || 'export').replace(/[\\/:*?"<>|]+/g, '-').replace(/\s+/g, ' ').trim().slice(0, 80) || 'export'; }

  function downloadBlob(name, blob) {
    try {
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url; a.download = safeName(name); a.rel = 'noopener';
      document.body.appendChild(a); a.click();
      setTimeout(() => { document.body.removeChild(a); URL.revokeObjectURL(url); }, 4000);
      return true;
    } catch (e) { return false; }
  }
  function downloadText(name, text, mime) { return downloadBlob(name, new Blob([text], { type: (mime || 'text/plain') + ';charset=utf-8' })); }

  async function share(opts) {
    if (!navigator.share) return false;
    try {
      if (opts.file && navigator.canShare && navigator.canShare({ files: [opts.file] })) { await navigator.share({ title: opts.title, files: [opts.file] }); return true; }
      if (opts.text) { await navigator.share({ title: opts.title, text: opts.text }); return true; }
    } catch (e) { if (e && e.name === 'AbortError') return true; }
    return false;
  }
  async function copy(text) {
    try { await navigator.clipboard.writeText(text); return true; } catch (e) {
      try { const ta = document.createElement('textarea'); ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0'; document.body.appendChild(ta); ta.select(); const ok = document.execCommand('copy'); document.body.removeChild(ta); return ok; } catch (e2) { return false; }
    }
  }
  function extensionFor(mime) {
    if (!mime) return 'webm';
    if (mime.includes('mp4') || mime.includes('aac') || mime.includes('m4a')) return 'm4a';
    if (mime.includes('ogg')) return 'ogg';
    if (mime.includes('wav')) return 'wav';
    return 'webm';
  }
  return { markdown, transcriptText, prepSheet, fullExport, backup, parseBackup, downloadText, downloadBlob, share, copy, title, safeName, extensionFor };
})();
