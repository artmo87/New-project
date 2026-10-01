/* Records a session: microphone audio (MediaRecorder, saved in 10-second chunks so a crash loses
   almost nothing) plus live transcription (LiveTranscriber). Keeps the screen awake while recording. */
class SessionRecorder {
  constructor(opts) {
    this.sessionId = opts.sessionId;
    this.mode = opts.mode || 'both';                  // 'both' | 'transcript' | 'audio'
    this.lang = opts.lang || 'en-US';
    this.preferLocal = !!opts.preferLocal;
    this.onLevel = opts.onLevel || (() => {});
    this.onTick = opts.onTick || (() => {});
    this.onPartial = opts.onPartial || (() => {});
    this.onSegment = opts.onSegment || (() => {});
    this.onWarning = opts.onWarning || (() => {});
    this.onState = opts.onState || (() => {});
    this.state = 'idle';                               // idle | recording | paused | stopped
    this.segments = [];
    this.stream = null;
    this.mediaRecorder = null;
    this.chunks = [];
    this.chunkIndex = 0;
    this.mime = '';
    this.transcriber = null;
    this.transcriptionActive = false;
    this.audioActive = false;
    this.audioContext = null;
    this.analyser = null;
    this.levelTimer = null;
    this.tickTimer = null;
    this.wakeLock = null;
    this.base = 0;
    this.pausedTotal = 0;
    this.pauseStart = null;
    this.hiddenAt = null;
    this.mutedWarned = false;
    this._onVisibility = () => this._handleVisibility();
  }

  get elapsed() {
    if (!this.base) return 0;
    const now = performance.now();
    const paused = this.pausedTotal + (this.pauseStart != null ? now - this.pauseStart : 0);
    return Math.max(0, (now - this.base - paused) / 1000);
  }

  static pickMime() {
    if (typeof MediaRecorder === 'undefined') return '';
    const candidates = ['audio/mp4', 'audio/webm;codecs=opus', 'audio/webm', 'audio/ogg;codecs=opus', 'audio/aac'];
    for (const c of candidates) { try { if (MediaRecorder.isTypeSupported(c)) return c; } catch (e) { /* ignore */ } }
    return '';
  }

  async start() {
    if (this.state !== 'idle') throw new Error('Already recording.');
    const wantAudio = this.mode !== 'transcript';
    const wantTranscript = this.mode !== 'audio';
    const standaloneHint = navigator.standalone ? ' If you opened the app from your Home Screen, try opening the same address in Safari itself.' : '';
    if (wantTranscript && !LiveTranscriber.isSupported()) {
      if (!wantAudio) throw new Error('This browser has no speech recognition, so a transcript-only session is not possible here. Use Safari on iPhone/Mac or Chrome, or switch Recording mode to "Audio only".' + standaloneHint);
      this.onWarning('This browser has no built-in speech recognition, so the session is recorded as audio only.' + standaloneHint);
    }
    if (wantAudio && !this.audioContext) {
      const AC = window.AudioContext || window.webkitAudioContext;
      if (AC) { try { this.audioContext = new AC(); } catch (e) { this.audioContext = null; } }
    }
    this.base = performance.now();
    this.pausedTotal = 0;
    this.pauseStart = null;
    if (wantTranscript && LiveTranscriber.isSupported()) this._startTranscriber();
    if (wantAudio) {
      try { await this._startAudio(); } catch (e) {
        if (this.transcriber) { this.transcriber.active = false; this.transcriber.stopping = true; try { this.transcriber._stopRun(); } catch (e2) { /* ignore */ } this.transcriber = null; }
        this.state = 'idle';
        if (this.audioContext) { try { this.audioContext.close(); } catch (e2) { /* ignore */ } this.audioContext = null; }
        throw e;
      }
    }
    this.state = 'recording';
    this.onState(this.state);
    this.tickTimer = setInterval(() => this.onTick(this.elapsed), 200);
    document.addEventListener('visibilitychange', this._onVisibility);
    this._requestWakeLock();
  }

  async _startAudio() {
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) throw new Error('This browser cannot access the microphone. Open the app over https in Safari or Chrome.');
    let stream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: false, noiseSuppression: true, autoGainControl: true } });
    } catch (e) {
      const name = e && e.name;
      if (name === 'NotAllowedError' || name === 'SecurityError') throw new Error('Microphone access was denied. Allow the microphone for this site in your browser settings and try again.');
      if (name === 'NotFoundError') throw new Error('No microphone was found on this device.');
      throw new Error('The microphone could not be started (' + (name || 'unknown error') + ').');
    }
    this.stream = stream;
    const track = stream.getAudioTracks()[0];
    if (track) {
      track.onmute = () => {
        if (!this.mutedWarned && this.state === 'recording') {
          this.mutedWarned = true;
          this.onWarning('Your device paused the audio capture while speech recognition is listening. If the saved audio has gaps, set Recording mode to "Transcript only" in Settings.');
        }
      };
      track.onended = () => { if (this.state === 'recording') { this.onWarning('The microphone was taken over by another app or a call. Recording paused; tap Resume when it is free again.'); this.pause(); } };
    }
    if (typeof MediaRecorder === 'undefined') {
      this.onWarning('This browser cannot save audio recordings (no MediaRecorder). The transcript will still be saved.');
    } else {
      this.mime = SessionRecorder.pickMime();
      try {
        this.mediaRecorder = this.mime ? new MediaRecorder(stream, { mimeType: this.mime, audioBitsPerSecond: 64000 }) : new MediaRecorder(stream);
      } catch (e) {
        this.mediaRecorder = new MediaRecorder(stream);
      }
      this.mediaRecorder.ondataavailable = (ev) => {
        if (ev.data && ev.data.size > 0) {
          this.chunks.push(ev.data);
          const idx = this.chunkIndex++;
          DB.saveChunk(this.sessionId, idx, ev.data).catch(() => {});
        }
      };
      this.mediaRecorder.onerror = () => { this.onWarning('The audio recorder reported an error. The transcript continues; the audio file may be incomplete.'); };
      this.mediaRecorder.start(10000);
      this.audioActive = true;
    }
    this._startMeter(stream);
  }

  _startMeter(stream) {
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return;
    try {
      if (!this.audioContext) this.audioContext = new AC();
      const source = this.audioContext.createMediaStreamSource(stream);
      this.analyser = this.audioContext.createAnalyser();
      this.analyser.fftSize = 1024;
      source.connect(this.analyser);
      if (this.audioContext.state === 'suspended') this.audioContext.resume().catch(() => {});
      const data = new Uint8Array(this.analyser.fftSize);
      this.levelTimer = setInterval(() => {
        if (this.state !== 'recording') { this.onLevel(0); return; }
        this.analyser.getByteTimeDomainData(data);
        let sum = 0;
        for (let i = 0; i < data.length; i++) { const v = (data[i] - 128) / 128; sum += v * v; }
        const rms = Math.sqrt(sum / data.length);
        const db = rms > 0 ? 20 * Math.log10(rms) : -100;
        const level = Math.max(0, Math.min(1, (db + 50) / 50));
        this.onLevel(level);
      }, 90);
    } catch (e) { /* metering is optional */ }
  }

  _startTranscriber() {
    this.transcriber = new LiveTranscriber({
      lang: this.lang,
      preferLocal: this.preferLocal,
      clock: () => this.elapsed,
      onPartial: (t) => this.onPartial(t),
      onSegment: (seg) => { this.segments.push(seg); this.segments.sort((a, b) => a.start - b.start); this.onSegment(seg); },
      onWarning: (m) => this.onWarning(m),
      onFatal: (m) => { this.transcriptionActive = false; this.onWarning(m); this.onState(this.state); }
    });
    try {
      this.transcriber.start();
      this.transcriptionActive = true;
    } catch (e) {
      this.transcriptionActive = false;
      this.onWarning(e.message || 'Live transcription could not start.');
    }
  }

  pause() {
    if (this.state !== 'recording') return;
    this.state = 'paused';
    this.pauseStart = performance.now();
    if (this.mediaRecorder && this.mediaRecorder.state === 'recording') { try { this.mediaRecorder.pause(); } catch (e) { /* ignore */ } }
    if (this.transcriber) this.transcriber.pause();
    this.onLevel(0);
    this.onState(this.state);
  }

  resume() {
    if (this.state !== 'paused') return;
    if (this.pauseStart != null) { this.pausedTotal += performance.now() - this.pauseStart; this.pauseStart = null; }
    this.state = 'recording';
    if (this.mediaRecorder && this.mediaRecorder.state === 'paused') { try { this.mediaRecorder.resume(); } catch (e) { /* ignore */ } }
    if (this.transcriber) this.transcriber.resume();
    if (this.audioContext && this.audioContext.state === 'suspended') this.audioContext.resume().catch(() => {});
    this._requestWakeLock();
    this.onState(this.state);
  }

  /** Stops everything and returns the recorded material. */
  async stop() {
    if (this.state === 'idle' || this.state === 'stopped') return null;
    if (this.state === 'paused' && this.pauseStart != null) { this.pausedTotal += performance.now() - this.pauseStart; this.pauseStart = null; }
    const duration = this.elapsed;
    this.state = 'stopped';
    this.onState(this.state);
    clearInterval(this.tickTimer);
    if (this.transcriber) { try { await this.transcriber.stop(); } catch (e) { /* ignore */ } }
    let audio = null;
    if (this.mediaRecorder) {
      const mr = this.mediaRecorder;
      if (mr.state !== 'inactive') {
        await new Promise((resolve) => {
          const done = () => resolve();
          mr.onstop = done;
          setTimeout(done, 4000);
          try { mr.stop(); } catch (e) { done(); }
        });
      }
      if (this.chunks.length) {
        const type = mr.mimeType || this.mime || (this.chunks[0] && this.chunks[0].type) || 'audio/webm';
        audio = { blob: new Blob(this.chunks, { type }), mime: type };
      }
    }
    this._teardown();
    return { duration, segments: this.segments.slice(), audio, transcriptionUsed: this.transcriptionActive || this.segments.length > 0 };
  }

  async cancel() {
    if (this.state === 'idle') return;
    this.state = 'stopped';
    this.onState(this.state);
    clearInterval(this.tickTimer);
    if (this.transcriber) { this.transcriber.active = false; this.transcriber.stopping = true; try { this.transcriber._stopRun(); } catch (e) { /* ignore */ } }
    if (this.mediaRecorder && this.mediaRecorder.state !== 'inactive') { try { this.mediaRecorder.ondataavailable = null; this.mediaRecorder.stop(); } catch (e) { /* ignore */ } }
    this._teardown();
    await DB.deleteChunks(this.sessionId).catch(() => {});
  }

  _teardown() {
    clearInterval(this.levelTimer);
    clearInterval(this.tickTimer);
    document.removeEventListener('visibilitychange', this._onVisibility);
    if (this.stream) { this.stream.getTracks().forEach((t) => { try { t.stop(); } catch (e) { /* ignore */ } }); this.stream = null; }
    if (this.audioContext) { try { this.audioContext.close(); } catch (e) { /* ignore */ } this.audioContext = null; }
    if (this.wakeLock) { try { this.wakeLock.release(); } catch (e) { /* ignore */ } this.wakeLock = null; }
    this.onLevel(0);
  }

  async _requestWakeLock() {
    try {
      if ('wakeLock' in navigator && document.visibilityState === 'visible') {
        this.wakeLock = await navigator.wakeLock.request('screen');
        this.wakeLock.addEventListener('release', () => { this.wakeLock = null; });
      }
    } catch (e) { /* optional */ }
  }

  _handleVisibility() {
    if (document.visibilityState === 'hidden') {
      this.hiddenAt = performance.now();
    } else {
      if (this.state === 'recording') {
        this._requestWakeLock();
        if (this.audioContext && this.audioContext.state === 'suspended') this.audioContext.resume().catch(() => {});
        const away = this.hiddenAt ? (performance.now() - this.hiddenAt) / 1000 : 0;
        if (away > 4) this.onWarning('The app was in the background for ' + Math.round(away) + ' s. Browsers pause recording while the screen is off, so that part may be missing. Keep the screen on during the session.');
      }
      this.hiddenAt = null;
    }
  }
}
