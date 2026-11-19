// Exercise the actual embedded player script with delayed browser events.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const dart = fs.readFileSync(path.join(__dirname, '../lib/services/eme/eme_page_html.dart'), 'utf8');
const html = dart.split("const String emePageHtml = r'''")[1].split("''';")[0];
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
const deferred = () => {
  let resolve;
  const promise = new Promise(r => { resolve = r; });
  return { promise, resolve };
};
const flush = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };

function harness() {
  const audios = [], players = [], sessions = [];
  class Events {
    listeners = new Map();
    addEventListener(name, fn) {
      this.listeners.set(name, [...(this.listeners.get(name) || []), fn]);
    }
    removeEventListener(name, fn) {
      this.listeners.set(name, (this.listeners.get(name) || []).filter(f => f !== fn));
    }
    emit(name, event = {}) { for (const fn of this.listeners.get(name) || []) fn(event); }
  }
  class Media extends Events {
    paused = true;
    muted = false;
    currentTime = 0;
    duration = 100;
    playCalls = 0;
    playDone = null;
    play() {
      this.playCalls++;
      this.paused = false;
      return this.playDone?.promise || Promise.resolve();
    }
    pause() { this.paused = true; this.emit('pause'); }
    load() {}
    remove() { this.removed = true; }
    removeAttribute(name) { delete this[name]; }
    canPlayType() { return 'probably'; }
    webkitSetMediaKeys(keys) { this.webkitKeys = keys; }
  }
  class Hls extends Events {
    static Events = { ERROR: 'error', MANIFEST_PARSED: 'manifest' };
    static isSupported() { return true; }
    constructor(config) { super(); this.config = config; players.push(this); }
    on(name, fn) { this.addEventListener(name, fn); }
    destroy() { this.destroyed = true; }
    loadSource() {}
    attachMedia() {}
  }
  class WebKitMediaKeys {
    static isTypeSupported() { return true; }
    createSession() {
      const session = new Events();
      session.updates = 0;
      session.update = () => session.updates++;
      sessions.push(session);
      return session;
    }
  }
  const context = new Events();
  Object.assign(context, {
    Hls, WebKitMediaKeys, TextDecoder, performance: { now: () => 0 },
    document: {
      createElement: () => new Media(),
      body: { appendChild: a => audios.push(a) },
    },
    navigator: { userAgent: 'test' },
    flutter_inappwebview: { callHandler() {} },
    setInterval: () => 1, clearInterval() {}, setTimeout: () => 1, clearTimeout() {},
    fetch: async () => ({ ok: true, arrayBuffer: async () => new ArrayBuffer(8) }),
  });
  context.window = context;
  vm.runInNewContext(script, context);
  return { context, audios, players, sessions };
}

for (const mode of ['hls', 'fairplay']) {
  const start = (h, gen, autoplay = true, revision = 1, position = 0) => mode === 'hls'
    ? h.context.emePlayHls(false, gen, autoplay, revision, position)
    : h.context.emePlayNativeFps(gen, '0123456789abcdef', autoplay, revision, position);
  const manifest = h => { if (mode === 'hls') h.players.at(-1).emit('manifest'); };

  test(`${mode}: paused preparation preserves position and waits for explicit resume`, async () => {
    const h = harness();
    assert.equal(await start(h, 1, false, 1, 42), 'ok');
    const a = h.audios.at(-1);
    manifest(h);
    a.emit('loadedmetadata');
    assert.equal(a.currentTime, 42);
    assert.equal(a.playCalls, 0);
    h.context.emeResume(1, 2);
    await flush();
    assert.equal(a.playCalls, 1);
    assert.equal(a.muted, false);
  });

  test(`${mode}: a pause delivered before delayed start overrides autoplay`, async () => {
    const h = harness();
    h.context.emePause(1, 2);
    assert.equal(await start(h, 1, true), 'ok');
    manifest(h);
    assert.equal(h.audios.at(-1).playCalls, 0);
    h.context.emeResume(1, 3);
    await flush();
    assert.equal(h.audios.at(-1).paused, false);
  });

  test(`${mode}: late play acknowledgement cannot unmute after pause`, async () => {
    const h = harness();
    await start(h, 1, false);
    const a = h.audios.at(-1);
    a.playDone = deferred();
    h.context.emeResume(1, 2);
    h.context.emePause(1, 3);
    a.playDone.resolve();
    await flush();
    assert.equal(a.paused, true);
    assert.equal(a.muted, true);
  });

  test(`${mode}: stop rejects stale starts and stale resume commands`, async () => {
    const h = harness();
    await start(h, 1, false);
    h.context.emeStop(2, 2);
    assert.equal(await start(h, 1), 'cancelled');
    await start(h, 3, false, 3);
    const a = h.audios.at(-1);
    h.context.emeResume(1, 99);
    manifest(h);
    assert.equal(a.playCalls, 0);
  });
}

test('HLS: manifest arriving after pause never restarts audio', async () => {
  const h = harness();
  await h.context.emePlayHls(false, 1, true, 1);
  h.context.emePause(1, 2);
  h.players[0].emit('manifest');
  assert.equal(h.audios[0].playCalls, 0);
  await h.context.emePlayHls(false, 2, false, 3);
  h.players[0].emit('manifest');
  assert.equal(h.audios[1].playCalls, 0);
});

test('FairPlay: certificate completing after stop does not create a DRM session', async () => {
  const h = harness();
  const cert = deferred();
  h.context.fetch = () => cert.promise;
  await h.context.emePlayNativeFps(1, 'file', false, 1);
  h.audios[0].emit('webkitneedkey', { initData: new Uint8Array([1, 2]) });
  h.context.emeStop(2, 2);
  cert.resolve({ ok: true, arrayBuffer: async () => new ArrayBuffer(8) });
  await flush();
  assert.equal(h.sessions.length, 0);
});

test('FairPlay: stale license completion cannot update the previous session', async () => {
  const h = harness();
  await h.context.emePlayNativeFps(1, 'file', false, 1);
  h.audios[0].emit('webkitneedkey', { initData: new Uint8Array([1, 2]) });
  await flush();
  assert.equal(h.sessions.length, 1);
  const license = deferred();
  h.context.fetch = () => license.promise;
  h.sessions[0].emit('webkitkeymessage', { message: new Uint8Array([1]) });
  await h.context.emePlayNativeFps(2, 'next', false, 2);
  license.resolve({ ok: true, arrayBuffer: async () => new ArrayBuffer(8) });
  await flush();
  assert.equal(h.sessions[0].updates, 0);
});
