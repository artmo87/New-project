/* IndexedDB storage. Everything the app knows lives here, in this browser only.
   Falls back to in-memory storage (with a warning) when IndexedDB is unavailable, e.g. some private modes. */
const DB = (() => {
  const NAME = 'therapist-copilot';
  const VERSION = 1;
  const STORES = ['sessions', 'audio', 'journal', 'settings', 'chunks'];
  let dbPromise = null;
  let memory = null;      // Map per store when IndexedDB fails
  const api = { volatile: false };

  function useMemory() {
    if (!memory) { memory = {}; for (const s of STORES) memory[s] = new Map(); api.volatile = true; }
    return memory;
  }
  function keyOf(store, value) { return store === 'settings' ? value.key : value.id; }

  function open() {
    if (dbPromise) return dbPromise;
    dbPromise = new Promise((resolve, reject) => {
      let req;
      try { req = indexedDB.open(NAME, VERSION); } catch (e) { reject(e); return; }
      req.onupgradeneeded = () => {
        const db = req.result;
        for (const s of STORES) {
          if (!db.objectStoreNames.contains(s)) {
            const os = db.createObjectStore(s, { keyPath: s === 'settings' ? 'key' : 'id' });
            if (s === 'chunks') os.createIndex('bySession', 'sessionId', { unique: false });
          }
        }
      };
      req.onsuccess = () => { const db = req.result; db.onversionchange = () => db.close(); resolve(db); };
      req.onerror = () => reject(req.error || new Error('IndexedDB open failed'));
      req.onblocked = () => reject(new Error('IndexedDB blocked'));
    });
    dbPromise.catch(() => { useMemory(); });
    return dbPromise;
  }

  async function run(store, mode, work) {
    let db;
    try { db = await open(); } catch (e) { db = null; }
    if (!db) {
      const m = useMemory()[store];
      return work({
        getAll: () => fake(Array.from(m.values())),
        get: (k) => fake(m.get(k)),
        put: (v) => { m.set(keyOf(store, v), v); return fake(keyOf(store, v)); },
        delete: (k) => { m.delete(k); return fake(undefined); },
        clear: () => { m.clear(); return fake(undefined); },
        index: () => ({ getAll: (k) => fake(Array.from(m.values()).filter((v) => v.sessionId === k)) })
      }, true);
    }
    return new Promise((resolve, reject) => {
      let t;
      try { t = db.transaction(store, mode); } catch (e) { reject(e); return; }
      const os = t.objectStore(store);
      let result;
      let request = null;
      try { request = work(os, false); } catch (e) { reject(e); return; }
      t.oncomplete = () => resolve(request && 'result' in request ? request.result : result);
      t.onerror = () => reject(t.error || new Error('IndexedDB transaction failed'));
      t.onabort = () => reject(t.error || new Error('IndexedDB transaction aborted'));
    });
  }
  function fake(result) { return { result }; }

  api.getAll = (store) => run(store, 'readonly', (os) => os.getAll());
  api.get = (store, key) => run(store, 'readonly', (os) => os.get(key));
  api.put = (store, value) => run(store, 'readwrite', (os) => os.put(value));
  api.del = (store, key) => run(store, 'readwrite', (os) => os.delete(key));
  api.clear = (store) => run(store, 'readwrite', (os) => os.clear());

  // Sessions
  api.loadSessions = async () => {
    const all = (await api.getAll('sessions')) || [];
    return all.sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));
  };
  api.saveSession = (s) => api.put('sessions', s);
  api.deleteSession = async (id) => { await api.del('sessions', id); await api.deleteAudio(id); await api.deleteChunks(id); };

  // Audio (one blob per session)
  api.saveAudio = (id, blob, mime) => api.put('audio', { id, blob, mime: mime || blob.type || '', size: blob.size, savedAt: new Date().toISOString() });
  api.getAudio = async (id) => (await api.get('audio', id)) || null;
  api.deleteAudio = (id) => api.del('audio', id);

  // Progressive chunks while recording (crash recovery)
  api.saveChunk = (sessionId, index, blob) => api.put('chunks', { id: sessionId + ':' + String(index).padStart(6, '0'), sessionId, index, blob });
  api.getChunks = async (sessionId) => {
    const all = await run('chunks', 'readonly', (os, isMemory) => isMemory ? os.index().getAll(sessionId) : os.index('bySession').getAll(sessionId));
    return (all || []).sort((a, b) => a.index - b.index);
  };
  api.deleteChunks = async (sessionId) => {
    const chunks = await api.getChunks(sessionId);
    for (const c of chunks) await api.del('chunks', c.id);
  };
  api.chunkSessionIds = async () => {
    const all = (await api.getAll('chunks')) || [];
    return Array.from(new Set(all.map((c) => c.sessionId)));
  };

  // Journal
  api.loadJournal = async () => ((await api.getAll('journal')) || []).sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));
  api.saveJournalEntry = (e) => api.put('journal', e);
  api.deleteJournalEntry = (id) => api.del('journal', id);

  // Settings (single record)
  api.loadSettings = async () => { const rec = await api.get('settings', 'app'); return (rec && rec.value) || {}; };
  api.saveSettings = (value) => api.put('settings', { key: 'app', value });
  api.loadDraft = async () => { const rec = await api.get('settings', 'draft'); return (rec && rec.value) || null; };
  api.saveDraft = (value) => api.put('settings', { key: 'draft', value });
  api.clearDraft = () => api.del('settings', 'draft');

  api.clearAll = async () => { for (const s of STORES) await api.clear(s); };
  api.estimate = async () => {
    try { if (navigator.storage && navigator.storage.estimate) return await navigator.storage.estimate(); } catch (e) { /* ignore */ }
    return null;
  };
  api.persist = async () => {
    try { if (navigator.storage && navigator.storage.persist) return await navigator.storage.persist(); } catch (e) { /* ignore */ }
    return false;
  };
  api.persisted = async () => {
    try { if (navigator.storage && navigator.storage.persisted) return await navigator.storage.persisted(); } catch (e) { /* ignore */ }
    return false;
  };
  return api;
})();
