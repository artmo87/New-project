/* Live transcription on top of the browser's built-in speech recognition (Web Speech API).
   The recognizer restarts itself whenever the browser ends a run, so a 50-minute session is
   transcribed as a chain of short runs. Each final result becomes a timestamped segment.
   No audio is sent to this app's authors or to any third party; recognition is done by the
   browser/OS (on iPhone that is Apple's dictation service, on Chrome Google's or on-device). */
class LiveTranscriber {
  static get Recognition() { return window.SpeechRecognition || window.webkitSpeechRecognition || null; }
  static isSupported() { return !!LiveTranscriber.Recognition; }

  /** On-device availability for Chrome's local recognition. Resolves 'available' | 'downloadable' | 'downloading' | 'unavailable' | 'unsupported'. */
  static async localAvailability(lang) {
    const R = LiveTranscriber.Recognition;
    if (!R || typeof R.available !== 'function') return 'unsupported';
    try { return await R.available({ langs: [lang], processLocally: true }); } catch (e) { return 'unsupported'; }
  }
  static async installLocal(lang) {
    const R = LiveTranscriber.Recognition;
    if (!R || typeof R.install !== 'function') return false;
    try { return await R.install({ langs: [lang], processLocally: true }); } catch (e) { return false; }
  }

  constructor(opts) {
    this.lang = opts.lang || 'en-US';
    this.clock = opts.clock || (() => 0);
    this.onPartial = opts.onPartial || (() => {});
    this.onSegment = opts.onSegment || (() => {});
    this.onWarning = opts.onWarning || (() => {});
    this.onFatal = opts.onFatal || (() => {});
    this.preferLocal = !!opts.preferLocal;
    this.active = false;
    this.paused = false;
    this.stopping = false;
    this.rec = null;
    this.utteranceStart = null;
    this.lastPartial = '';
    this.runStartedAt = 0;
    this.gotResultsThisRun = false;
    this.quickEnds = 0;
    this.networkErrors = 0;
    this.captureErrors = 0;
    this.restartTimer = null;
    this.endResolvers = [];
    this.segmentCount = 0;
  }

  start() {
    if (!LiveTranscriber.isSupported()) throw new Error('Speech recognition is not available in this browser.');
    this.active = true;
    this.paused = false;
    this.stopping = false;
    this._startRun(0);
  }

  pause() {
    if (!this.active || this.paused) return;
    this.paused = true;
    clearTimeout(this.restartTimer);
    this._stopRun();
  }

  resume() {
    if (!this.active || !this.paused) return;
    this.paused = false;
    this._startRun(0);
  }

  /** Stops recognition and resolves once the last results are in (or after a short timeout). */
  async stop() {
    if (!this.active) return;
    this.active = false;
    this.stopping = true;
    clearTimeout(this.restartTimer);
    if (this.rec) {
      await new Promise((resolve) => {
        this.endResolvers.push(resolve);
        setTimeout(resolve, 2500);
        this._stopRun();
      });
    }
    this._flushPartial();
    this.rec = null;
  }

  _flushPartial() {
    const text = (this.lastPartial || '').trim();
    if (text) {
      const end = this.clock();
      const start = this.utteranceStart != null ? this.utteranceStart : Math.max(0, end - this._estimateSeconds(text));
      this.lastPartial = '';
      this.utteranceStart = null;
      this.segmentCount++;
      this.onSegment({ id: uid(), start: Math.max(0, start), end: Math.max(end, start + 0.5), text, speaker: 'unknown' });
      this.onPartial('');
    }
  }

  _estimateSeconds(text) { return Math.min(90, Math.max(1, text.split(/\s+/).length / 2.6)); }

  _startRun(delay) {
    clearTimeout(this.restartTimer);
    if (!this.active || this.paused) return;
    const begin = () => {
      if (!this.active || this.paused) return;
      const R = LiveTranscriber.Recognition;
      let rec;
      try { rec = new R(); } catch (e) { this.onFatal('Speech recognition could not be started in this browser.'); return; }
      rec.lang = this.lang;
      rec.continuous = true;
      rec.interimResults = true;
      rec.maxAlternatives = 1;
      if (this.preferLocal && 'processLocally' in rec) { try { rec.processLocally = true; } catch (e) { /* ignore */ } }
      this.rec = rec;
      this.gotResultsThisRun = false;
      rec.onstart = () => { this.runStartedAt = performance.now(); };
      rec.onresult = (event) => this._handleResult(event);
      rec.onerror = (event) => this._handleError(event);
      rec.onend = () => this._handleEnd(rec);
      try {
        rec.start();
      } catch (e) {
        // "already started" or a transient failure: try again shortly.
        this.rec = null;
        this._startRun(400);
      }
    };
    if (delay > 0) this.restartTimer = setTimeout(begin, delay); else begin();
  }

  _stopRun() {
    const rec = this.rec;
    if (!rec) return;
    try { rec.stop(); } catch (e) { try { rec.abort(); } catch (e2) { /* ignore */ } }
  }

  _handleResult(event) {
    this.gotResultsThisRun = true;
    this.quickEnds = 0;
    const now = this.clock();
    let partial = '';
    for (let i = event.resultIndex; i < event.results.length; i++) {
      const res = event.results[i];
      const alt = res[0];
      const text = alt && alt.transcript ? alt.transcript.trim() : '';
      if (res.isFinal) {
        if (text) {
          const start = this.utteranceStart != null ? this.utteranceStart : Math.max(0, now - this._estimateSeconds(text));
          this.segmentCount++;
          this.onSegment({ id: uid(), start: Math.max(0, start), end: Math.max(now, start + 0.5), text, speaker: 'unknown' });
        }
        this.utteranceStart = null;
      } else if (text) {
        if (this.utteranceStart == null) this.utteranceStart = Math.max(0, now - 1);
      }
    }
    for (let i = 0; i < event.results.length; i++) {
      const res = event.results[i];
      if (!res.isFinal && res[0] && res[0].transcript) partial += (partial ? ' ' : '') + res[0].transcript.trim();
    }
    this.lastPartial = partial;
    this.onPartial(partial);
  }

  _handleError(event) {
    const code = event && event.error ? event.error : 'unknown';
    switch (code) {
      case 'no-speech':
      case 'aborted':
        return;
      case 'audio-capture':
        this.captureErrors++;
        if (this.captureErrors === 1) this.onWarning('The microphone is not reachable for speech recognition right now. Retrying…');
        if (this.captureErrors >= 4) { this.onFatal('Speech recognition cannot access the microphone on this device while audio is being recorded. Try Recording mode "Transcript only" in Settings.'); this.active = false; }
        return;
      case 'not-allowed':
      case 'service-not-allowed':
        this.active = false;
        this.onFatal('Speech recognition is not allowed here. Allow the microphone for this site, or open the app directly in Safari/Chrome instead of an embedded view.');
        return;
      case 'network':
        this.networkErrors++;
        if (this.networkErrors === 1 || this.networkErrors % 5 === 0) this.onWarning('The speech service could not be reached (your browser does recognition through the system). Audio recording continues; retrying…');
        return;
      case 'language-not-supported':
        if (this.preferLocal) { this.preferLocal = false; this.onWarning('On-device recognition is not available for this language; using the standard recognizer.'); return; }
        this.active = false;
        this.onFatal('This language is not supported for speech recognition in this browser. Choose another language in Settings.');
        return;
      default:
        this.onWarning('Speech recognition hiccup (' + code + '). Retrying…');
    }
  }

  _handleEnd(rec) {
    if (this.rec === rec) this.rec = null;
    if (this.stopping || !this.active) {
      const resolvers = this.endResolvers; this.endResolvers = [];
      resolvers.forEach((r) => r());
      return;
    }
    if (this.paused) return;
    // The browser ended this run; chain a new one. If runs keep dying immediately, slow down and tell the user.
    const ranFor = performance.now() - this.runStartedAt;
    if (!this.gotResultsThisRun && ranFor < 1500) this.quickEnds++; else this.quickEnds = 0;
    let delay = 250;
    if (this.quickEnds >= 4) { delay = 3000; if (this.quickEnds === 4) this.onWarning('Live transcription keeps stopping. Still trying — your audio recording is unaffected.'); }
    if (this.networkErrors > 0) delay = Math.max(delay, 1500);
    this._startRun(delay);
  }
}
