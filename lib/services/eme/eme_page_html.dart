/// 空白 EME 宿主页（HLS.js 驱动；无任何 UI/Spotify 前端；零外部请求）。
/// 页面加载 HLS.js → 加载本地 m3u8 → EME 解密 → MSE 播放。
const String emePageHtml = r'''
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>Flutify</title></head>
<body>
<script src="/hls.js"></script>
<script>
'use strict';
let hls = null, audio = null, telemetryTimer = null;
// 最近一次 emeSetVolume 的音量：每首歌都新建 audio 元素（默认 1.0），建好就沿用它
let pageVolume = 1;
// 本机输出设备（按系统设备名匹配；空串 = 系统默认）。每首歌新建 audio 元素后都要重新应用
let pageSinkLabel = '';
async function applySink(el) {
  if (!el || typeof el.setSinkId !== 'function') return;
  let id = '';
  if (pageSinkLabel) {
    try {
      // 只取输出设备，并去掉 Chromium 给出的「默认值 - xxx」「通信 - xxx」两个别名项
      const outs = (await navigator.mediaDevices.enumerateDevices()).filter((d) =>
        d.kind === 'audiooutput' && d.deviceId !== 'default' && d.deviceId !== 'communications');
      // 1) 完整名称精确匹配
      let hit = outs.find((d) => d.label === pageSinkLabel);
      // 2) 兜底：系统与 libmpv 的设备名写法略有出入时，比较括号里的硬件名（如「(Realtek(R) Audio)」）；
      //   只有唯一命中才用，同一声卡有多个输出时宁可回落系统默认也不切错
      if (!hit) {
        const hw = (t) => { const i = t.indexOf('('); return i >= 0 ? t.slice(i).trim() : ''; };
        const key = hw(pageSinkLabel);
        const same = key ? outs.filter((d) => hw(d.label) === key) : [];
        if (same.length === 1) hit = same[0];
      }
      if (hit) id = hit.deviceId;
      else send('log', {msg: '输出设备未唯一匹配（可选 ' + outs.length + ' 个），使用系统默认'});
    } catch (e) {
      send('log', {msg: '枚举输出设备失败: ' + e});
    }
  }
  try { await el.setSinkId(id); } catch (e) { send('log', {msg: 'setSinkId 失败: ' + e}); }
}
// 页面级：createMediaKeys 曾挂起则置真，之后所有 hls 实例不再带 serverCertificateUrl
//（部分 Android WebView 的 EME 带证书请求时 createMediaKeys 永不 settle；不带也能播）
let certDegraded = false;
// 当前曲目实例的播放代次（Dart 侧 emePlayHls 传入）；hook 在调用点捕获它给 stall 信号打标，
// 旧实例遗留的 6s 计时器晚到时带的是旧代次，新曲目的监听据此忽略
let curGen = 0;
let intentGen = 0, intentRevision = 0, playRequested = false;
const acceptIntent = (gen, revision, playing) => {
  if (gen < intentGen || (gen === intentGen && revision < intentRevision)) return false;
  intentGen = gen; intentRevision = revision; playRequested = playing;
  return true;
};
const playIfRequested = (el, gen) => {
  if (audio !== el || gen !== intentGen || !playRequested) return;
  el.muted = true;
  el.play().then(() => {
    if (audio === el && gen === intentGen && playRequested) el.muted = false;
    else el.pause();
  }).catch((e) => {
    const name = e && e.name ? e.name : '';
    const msg = e && e.message ? e.message : String(e || 'unknown');
    send('log', {msg: 'audio.play() 失败: ' + (name ? name + ': ' : '') + msg, gen});
    if (name !== 'AbortError' && audio === el && gen === intentGen && playRequested) {
      send('error', {msg: 'audio.play() 失败: ' + (name ? name + ': ' : '') + msg, gen});
    }
  });
};
// 当前曲目的 'emeStall' 监听（模块级保存，换歌时先摘掉上一首的，避免旧闭包对新曲目报错）
let stallListener = null;

// ---- 每首歌只请求一次 license（对齐官方 Web 播放器）----
// hls.js 1.5.13 从清单 EXT-X-KEY 的 pssh 与媒体 encrypted 事件的 pssh 用两套固定偏移推 keyId，
// 对 Spotify 的 pssh 推出来不一致，于是给同一首歌建第二个会话、多请求一次 license（用量翻倍、更易被限流）。
// 官方 Web 播放器只用清单（seektable）里的 pssh 建会话，原生 encrypted 事件只记日志、没有回退。这里同样：
// 清单 key 已建会话后拦下 encrypted 事件。实机验证（83B / 89B 两种 initData）拦下后均正常解密播放。
// 只留诊断：拿到可用密钥后媒体仍卡在缺密钥，记一行日志（真遇到时说明内容需要第二把 key）。
let emeSessions = 0, emeKeyUsable = false, emeWaitingForKey = false;
let emeKeyUsableListener = null;
const resetEmeDedup = () => {
  emeSessions = 0; emeKeyUsable = false; emeWaitingForKey = false;
};

const send = (type, data) => {
  try { window.flutter_inappwebview.callHandler('emeEvent', JSON.stringify({type, ...(data||{})})); } catch (e) {}
};

// ---- EME 原生 API 时间戳 hook（非侵入 monkey-patch：只记录，不改时序、不吞错、返回原 Promise） ----
// 用于定位「无 encrypted、无 /license、无报错」卡死：hls.js / 页面里任何人走
// createMediaKeys → setServerCertificate → createSession → generateRequest 都会被记下。
// Promise 类步骤用 settle 标记，5s 未 settle 报「疑似挂起」。
try {
  const tapPromise = (p, tag, t0, timeout) => {
    timeout = timeout || 5000;
    const gen = curGen; // 调用时所属曲目实例的代次
    let settled = false;
    p.then(() => { settled = true; send('log', {msg: '[hook] ' + tag + ' resolve ' + (performance.now() - t0).toFixed(0) + 'ms'}); },
           (e) => { settled = true; send('log', {msg: '[hook] ' + tag + ' reject: ' + e}); });
    setTimeout(() => {
      if (settled) return;
      send('log', {msg: '[hook] ' + tag + ' ' + (timeout / 1000) + 's 未 settle（疑似挂起）'});
      // createMediaKeys 挂起是可恢复场景：除日志外发 stall 信号，
      // Dart 侧记一条，页面内广播给 emePlayHls 触发「无 serverCertificate」降级重建
      if (tag === 'createMediaKeys') {
        send('emeStall', {stage: tag, gen});
        try { window.dispatchEvent(new CustomEvent('emeStall', {detail: {stage: tag, gen}})); } catch (e) {}
      }
    }, timeout);
    return p;
  };
  if (window.MediaKeySystemAccess) {
    const _cmk = MediaKeySystemAccess.prototype.createMediaKeys;
    MediaKeySystemAccess.prototype.createMediaKeys = function (...args) {
      send('log', {msg: '[hook] createMediaKeys 调用'});
      return tapPromise(_cmk.apply(this, args), 'createMediaKeys', performance.now(), 6000);
    };
  }
  if (window.MediaKeys) {
    const _ssc = MediaKeys.prototype.setServerCertificate;
    MediaKeys.prototype.setServerCertificate = function (...args) {
      const cert = args[0];
      send('log', {msg: '[hook] setServerCertificate 调用 cert=' + (cert && cert.byteLength || 0) + 'B'});
      return tapPromise(_ssc.apply(this, args), 'setServerCertificate', performance.now());
    };
    const _cs = MediaKeys.prototype.createSession;
    MediaKeys.prototype.createSession = function (...args) {
      send('log', {msg: '[hook] createSession 调用'});
      emeSessions++;
      const s = _cs.apply(this, args);
      s.addEventListener('message', (ev) => send('log',
        {msg: '[hook] session message type=' + ev.messageType + ' body=' + (ev.message ? ev.message.byteLength : 0) + 'B'}));
      s.addEventListener('keystatuseschange', () => {
        send('log', {msg: '[hook] session keystatuseschange'});
        try { s.keyStatuses.forEach((status) => { if (status === 'usable') emeKeyUsable = true; }); } catch (e) {}
        if (emeKeyUsable) window.dispatchEvent(new Event('emeKeyUsable'));
      });
      return s;
    };
  }
  if (window.MediaKeySession) {
    const _gr = MediaKeySession.prototype.generateRequest;
    MediaKeySession.prototype.generateRequest = function (initDataType, initData) {
      send('log', {msg: '[hook] generateRequest 调用 initDataType=' + initDataType + ' initData=' + (initData && initData.byteLength || 0) + 'B'});
      return tapPromise(_gr.apply(this, arguments), 'generateRequest', performance.now());
    };
  }
  send('log', {msg: '[hook] EME API hook 已安装'});
} catch (e) {
  send('log', {msg: '[hook] EME API hook 安装失败: ' + e});
}

// 诊断（FairPlay）：每 2s 看一眼 currentTime 是否推进、缓冲范围、是否被置 mute，
// 只在「没暂停却不走 / 数据不够」时记日志（正常播放不刷屏，诊断日志尾部不被它挤掉）；
// 暂停、播完、出错时停表，再次 playing 时重开。
// 注意不能用 WebAudio（createMediaElementSource）接管元素输出来测电平：受 EME 保护的
// 媒体经 WebAudio 一律输出静音，明文 lead-in（约前 10s）有声、进入加密段即无声。
const watchStall = (el, gsend) => {
  let timer = null, lastT = -1;
  const stop = () => {
    if (!timer) return;
    clearInterval(timer);
    if (telemetryTimer === timer) telemetryTimer = null;
    timer = null;
  };
  const start = () => {
    if (timer || audio !== el) return;
    lastT = -1;
    timer = setInterval(() => {
      if (audio !== el) { stop(); return; }
      const t = el.currentTime || 0;
      const stuck = !el.paused && !el.ended && (el.readyState < 3 || Math.abs(t - lastT) < 0.05);
      lastT = t;
      if (!stuck) return;
      const end = el.buffered.length ? el.buffered.end(el.buffered.length - 1) : -1;
      gsend('log', {msg: '遥测（疑似卡住）t=' + t.toFixed(1) + ' rdy=' + el.readyState +
        ' net=' + el.networkState + ' buf→' + end.toFixed(1) + ' paused=' + el.paused +
        ' muted=' + el.muted + ' vol=' + el.volume});
    }, 2000);
    telemetryTimer = timer;
  };
  el.addEventListener('playing', start);
  ['pause', 'ended', 'error', 'emptied'].forEach((n) => el.addEventListener(n, stop));
  start();
};

// [gen] 为 Dart 侧播放代次：本实例发出的所有事件都带上它，Dart 据此丢弃上一首的残留事件
//（旧 audio / 旧 hls 的晚到 error、旧 stall 计时器等），不会把健康的新曲目标成失败。
window.emePlayHls = (fairPlay, gen, autoplay = true, revision = 0, position = 0) => (async () => {
  const myGen = Number(gen) || 0;
  const gsend = (type, data) => send(type, {...(data||{}), gen: myGen});
  try {
    if (myGen < intentGen || myGen < curGen) return 'cancelled';
    acceptIntent(myGen, revision, autoplay);
    curGen = myGen;
    // 先摘掉上一首的 stall 监听（它只在 stall 触发时才自摘，正常换歌会一直挂着）
    if (stallListener) { window.removeEventListener('emeStall', stallListener); stallListener = null; }
    if (!window.Hls) return 'ERR:Hls.js 未加载';
    if (!Hls.isSupported()) return 'ERR:HLS 不支持';
    const useFairPlay = !!fairPlay;
    window.__fpsContentId = null; // 换歌清掉上一首的 FairPlay content ID
    // FairPlay 的 generateRequest 过滤器（等价于 hls.js 官方 FPS 集成）：
    // 播放列表 KEY 不带 pssh，改成 initDataType 'skd' 交给 CDM。
    // 实测：FPS content ID 必须是「剥掉 skd:// scheme 的裸 file_id」（40 位 hex）——
    // 带 scheme 的完整 URI（包括 sneaktables 自产的 skd:///fairplay-license/... 形态）
    // 换 license 一律 HTTP 500，裸 file_id 返回 200 CKC（2026-10 线上实测，见 fairplay.dart）。
    const fpsDrmSystems = {
      'com.apple.fps': {
        licenseUrl: '/license',
        serverCertificateUrl: '/cert',
        generateRequest: (initDataType, initData, keyContext) => {
          const uri = keyContext && keyContext.decryptdata && keyContext.decryptdata.uri;
          let contentId = (uri || '').replace(/^skd:\/\//, '');
          // fmp4 moov 里的 FPS pssh 会再触发一次 initDataType=sinf 的会话，hls 给它
          // 合成的 uri 是截断 KID（必 400）；它与 playlist KEY 是同一内容密钥，复用即可
          // 注意：此 hls.js/MSE 路径在 macOS 上已不用于 FairPlay（见 emePlayNativeFps）：
          // MSE 下系统按样本 KID 要密钥，skd 会话的密钥对不上 KID → 进度走但无声；
          // 把 sinf 原样透传则 SPC 的 content ID 变成 KID → Spotify license 500。
          if (initDataType === 'cenc' && contentId) {
            window.__fpsContentId = contentId;
          } else if (window.__fpsContentId) {
            contentId = window.__fpsContentId;
          }
          gsend('log', {msg: 'fairplay generateRequest: ' + initDataType + ' → skd contentId=' + contentId});
          return { initDataType: 'skd', initData: new TextEncoder().encode(contentId) };
        },
      },
    };
    // 换歌 / 失败重试：销毁上一首的 hls 与 audio，避免残留状态串台
    if (hls) { try { hls.destroy(); } catch (e) {} hls = null; }
    if (audio) { try { audio.pause(); audio.remove(); } catch (e) {} audio = null; }
    resetEmeDedup();
    audio = document.createElement('audio');
    audio.volume = pageVolume;
    applySink(audio);
    document.body.appendChild(audio);
    const el = audio;
    el.addEventListener('loadedmetadata', () => { if (position > 0) el.currentTime = position; }, {once: true});
    audio.addEventListener('timeupdate', () => gsend('position', {position: audio.currentTime, duration: audio.duration}));
    audio.addEventListener('playing', () => gsend('playing', {}));
    audio.addEventListener('waiting', () => gsend('buffering', {}));
    audio.addEventListener('ended', () => gsend('ended', {}));
    audio.addEventListener('error', () => gsend('error', {msg: audio.error ? (audio.error.code + ':' + audio.error.message) : 'unknown'}));
    audio.addEventListener('encrypted', (ev) => {
      gsend('log', {msg: 'encrypted 事件 initDataType=' + ev.initDataType + ' initData=' + (ev.initData ? ev.initData.byteLength : 0) + 'B'});
      // 先于 hls.js 注册（attachMedia 在后），stopImmediatePropagation 即可让它看不到这次事件
      if (!useFairPlay && emeSessions > 0) {
        ev.stopImmediatePropagation();
        gsend('log', {msg: '已拦截重复 license 会话（清单 key 已建会话，与官方 Web 播放器一样忽略媒体 encrypted 事件）'});
      }
    });
    // 诊断：已拿到可用密钥、媒体仍卡在缺密钥 1.5s（license 在路上时 waitingforkey 本来就会触发，所以要先有可用密钥）
    const reportStillMissingKey = () => {
      if (!emeWaitingForKey || !emeKeyUsable) return;
      setTimeout(() => {
        if (el !== audio || !emeWaitingForKey || audio.readyState >= 3) return;
        gsend('log', {msg: '可用密钥已到但仍缺密钥：被拦下的 encrypted 事件可能带了另一把 key'});
      }, 1500);
    };
    audio.addEventListener('waitingforkey', () => { emeWaitingForKey = true; reportStillMissingKey(); });
    audio.addEventListener('playing', () => { emeWaitingForKey = false; });
    if (emeKeyUsableListener) window.removeEventListener('emeKeyUsable', emeKeyUsableListener);
    emeKeyUsableListener = reportStillMissingKey;
    window.addEventListener('emeKeyUsable', reportStillMissingKey);
    // 诊断：媒体元素状态迁移（定位「不出声也不报错」卡在 readyState 哪一级）
    ['play','pause','waiting','stalled','canplay','canplaythrough','playing','waitingforkey','loadeddata','loadedmetadata','durationchange']
      .forEach((n) => audio.addEventListener(n, () => gsend('log',
        {msg: 'audio 事件 ' + n + ' t=' + (audio.currentTime || 0).toFixed(2) + ' readyState=' + audio.readyState})));
    // 诊断（FairPlay）：卡住检测遥测，见 watchStall
    if (telemetryTimer) { clearInterval(telemetryTimer); telemetryTimer = null; }
    if (useFairPlay) watchStall(audio, gsend);

    // hls 实例构建（降级重建时复用）：certDegraded 为真则不带 serverCertificateUrl，
    // 让 EMEController 跳过 setServerCertificate（已验证桌面 Chrome 无证书也能播）。
    // FairPlay 无此降级：WebKit FPS CDM 无 serverCertificate 直接拒绝 generateRequest。
    const buildHls = () => {
      if (hls) { try { hls.destroy(); } catch (e) {} hls = null; }
      const widevine = certDegraded
        ? { licenseUrl: '/license' }                                    // 降级：不碰 setServerCertificate
        : { licenseUrl: '/license', serverCertificateUrl: '/cert' };
      hls = new Hls({
        startPosition: position > 0 ? position : -1,
        emeEnabled: true,
        drmSystems: useFairPlay ? fpsDrmSystems : {
          'com.widevine.alpha': widevine,
        },
        // 宽限：本地服务，无需重试策略
        fragLoadingMaxRetry: 2,
        manifestLoadingMaxRetry: 2,
        // license 走本地中转：被 Spotify 限流时中转会把请求挂起到冷却结束（最长 15s），
        // 首字节超时要比它长；出错时少量、指数退避重试，避免密集重试让限流越来越久
        keyLoadPolicy: {default: {
          maxTimeToFirstByteMs: 30000,
          maxLoadTimeMs: 40000,
          timeoutRetry: {maxNumRetry: 1, retryDelayMs: 2000, maxRetryDelayMs: 8000, backoff: 'exponential'},
          errorRetry: {maxNumRetry: 2, retryDelayMs: 3000, maxRetryDelayMs: 15000, backoff: 'exponential'},
        }},
      });
      // 诊断：hls 管线关键事件逐个埋点；bundle 是 hls.js 1.5.13，不暴露
      // KEY_SYSTEM_* 公共事件（只有 ErrorDetails 常量），按存在性守卫自动跳过
      let firstFragLogged = false, firstBufferedLogged = false;
      const evt = (name, fn) => {
        if (Hls.Events && Hls.Events[name]) { hls.on(Hls.Events[name], fn); return true; }
        gsend('log', {msg: 'hls.js 无 ' + name + ' 事件（当前版本不暴露，跳过）'});
        return false;
      };
      evt('MEDIA_ATTACHED', () => gsend('log', {msg: 'MSE attach 完成'}));
      evt('BUFFER_CREATED', (e, d) => gsend('log', {msg: 'MSE SourceBuffer 已建: ' + Object.keys(d.tracks || {}).join('+')}));
      evt('LEVEL_LOADED', (e, d) => gsend('log', {
        msg: 'LEVEL_LOADED 分段数='
          + (d.details && d.details.fragments ? d.details.fragments.length : '?')
          + ' 时长=' + (d.details ? d.details.totalduration.toFixed(1) : '?') + 's'}));
      evt('FRAG_LOADED', (e, d) => {
        if (!firstFragLogged) {
          firstFragLogged = true;
          gsend('log', {msg: '首个 FRAG_LOADED sn=' + (d.frag ? d.frag.sn : '?') + ' bytes=' + (d.payload ? d.payload.byteLength : '?')});
        }
      });
      evt('FRAG_BUFFERED', (e, d) => {
        if (!firstBufferedLogged) {
          firstBufferedLogged = true;
          gsend('log', {msg: '首个 FRAG_BUFFERED（分段已进 MSE）sn=' + (d.frag ? d.frag.sn : '?')});
        }
      });
      evt('BUFFER_APPENDED', (e, d) => gsend('log', {msg: 'BUFFER_APPENDED type=' + d.type}));
      evt('KEY_SYSTEM_ACCESS', (e, d) => gsend('log', {msg: 'KEY_SYSTEM_ACCESS'}));
      hls.on(Hls.Events.ERROR, (ev, data) => {
        // 反代把 license / 证书失败原因写在 500 响应体里；HLS.js 错误数据带响应时就一并带回 Dart
        let extra = '';
        try {
          const r = data.response;
          if (r && r.code) extra += ' http=' + r.code;
          const d = r && r.data;
          if (d) {
            const text = typeof d === 'string' ? d : new TextDecoder().decode(d.slice(0, 256));
            if (text) extra += ' ' + text;
          }
        } catch (e) {}
        gsend('log', {msg: 'HLS ERROR ' + data.type + '/' + data.details + ' fatal=' + data.fatal + extra});
        if (data.fatal) gsend('error', {msg: data.details + extra});
      });
      hls.on(Hls.Events.MANIFEST_PARSED, () => {
        gsend('log', {msg: '清单已解析'});
        playIfRequested(el, myGen);
      });
      hls.loadSource('/audio.m3u8');
      hls.attachMedia(audio);
      gsend('log', {msg: certDegraded ? 'hls 已启动（降级：无 serverCertificate）' : 'hls 已启动'});
    };

    // createMediaKeys 挂起（hook 6s 未 settle 广播 'emeStall'）→ 原地销毁 hls 重建为无证书配置。
    // 只降级一次（stallHandled）；降配实例仍挂起则 gsend('error') 交回 Dart 现有错误通道。
    let stallHandled = certDegraded; // 已降级的页面本次直接算「已降级」，再挂立即报错
    const onEmeStall = (ev) => {
      if (!ev.detail || ev.detail.stage !== 'createMediaKeys') return;
      // 旧曲目实例的计时器晚到（代次不符）：与本曲目无关，忽略
      if (ev.detail.gen !== myGen || curGen !== myGen || intentGen !== myGen) return;
      if (useFairPlay) {
        // FairPlay 依赖 serverCertificate，无「去证书」降级空间，直接报错
        window.removeEventListener('emeStall', onEmeStall);
        if (stallListener === onEmeStall) stallListener = null;
        gsend('error', {msg: 'createMediaKeys 挂起（FairPlay，本机 WebView EME 不可用）'});
        return;
      }
      if (stallHandled) {
        // 降配实例仍挂起：不可恢复，只报一次并摘除监听
        window.removeEventListener('emeStall', onEmeStall);
        if (stallListener === onEmeStall) stallListener = null;
        gsend('error', {msg: 'createMediaKeys 仍挂起（已按无 serverCertificate 降级重建，本机 WebView EME 不可用）'});
        return;
      }
      stallHandled = true;
      certDegraded = true;
      gsend('log', {msg: 'createMediaKeys 挂起 → 原地重建 hls（去掉 serverCertificateUrl）'});
      buildHls(); // 监听保留：继续观察降配实例是否也挂起
    };
    stallListener = onEmeStall;
    window.addEventListener('emeStall', onEmeStall);
    buildHls();
    return 'ok';
  } catch (e) {
    return 'ERR:' + String(e);
  }
})();

// macOS FairPlay：WebKit 原生 HLS（<audio src=m3u8>）+ 旧版 EME（webkitneedkey / WebKitMediaKeys
// 'com.apple.fps.1_0'），即 Spotify 自家 Safari 播放器与 Apple FPS 示例的路线。
// 不用 hls.js/MSE 的原因：MSE 下 AVFoundation 按样本 KID 发起密钥请求，SPC 的 content ID 只能是 KID，
// Spotify 的 license 服务只认裸 file_id → 500；而 playlist skd 会话虽拿到密钥却对不上 KID → 无声。
// 旧版 EME 里 SPC 的 content ID 由页面拼进 createSession 的 initData（裸 file_id），
// 密钥则按清单 skd:// URI 回填给原生播放器的那次请求，两头一致。
window.emePlayNativeFps = (gen, fileIdHex, autoplay = true, revision = 0, position = 0) => (async () => {
  const myGen = Number(gen) || 0;
  const gsend = (type, data) => send(type, {...(data||{}), gen: myGen});
  try {
    if (myGen < intentGen || myGen < curGen) return 'cancelled';
    acceptIntent(myGen, revision, autoplay);
    curGen = myGen;
    if (stallListener) { window.removeEventListener('emeStall', stallListener); stallListener = null; }
    // 'ERR:NOFPS:' 前缀：本机缺 FairPlay（Dart 侧据此提示「设备不支持」而不是「请重试」）
    if (typeof WebKitMediaKeys === 'undefined') return 'ERR:NOFPS:本机 WebView 无旧版 EME（WebKitMediaKeys）';
    if (!WebKitMediaKeys.isTypeSupported('com.apple.fps.1_0', 'audio/mp4')) return 'ERR:NOFPS:本机 WebView 不支持 com.apple.fps.1_0';
    if (hls) { try { hls.destroy(); } catch (e) {} hls = null; }
    if (audio) { try { audio.pause(); audio.removeAttribute('src'); audio.load(); audio.remove(); } catch (e) {} audio = null; }
    if (telemetryTimer) { clearInterval(telemetryTimer); telemetryTimer = null; }
    audio = document.createElement('audio');
    audio.volume = pageVolume;
    applySink(audio);
    document.body.appendChild(audio);
    const el = audio;
    el.addEventListener('loadedmetadata', () => { if (position > 0) el.currentTime = position; }, {once: true});
    el.addEventListener('timeupdate', () => gsend('position', {position: el.currentTime, duration: el.duration}));
    el.addEventListener('playing', () => gsend('playing', {}));
    el.addEventListener('waiting', () => gsend('buffering', {}));
    el.addEventListener('ended', () => gsend('ended', {}));
    el.addEventListener('error', () => gsend('error', {msg: 'native-hls ' + (el.error ? (el.error.code + ':' + el.error.message) : 'unknown')}));
    ['play','pause','waiting','stalled','canplay','canplaythrough','playing','loadedmetadata','durationchange']
      .forEach((n) => el.addEventListener(n, () => gsend('log',
        {msg: 'audio 事件 ' + n + ' t=' + (el.currentTime || 0).toFixed(2) + ' readyState=' + el.readyState})));
    watchStall(el, gsend);

    // needkey 的 initData 是 UTF-16LE 的 skd:// URI；content ID = 剥掉 scheme 的裸 file_id。
    // createSession 的 initData 按 Apple 示例拼：initData | len(u32le) | contentId(UTF-16LE) | len(u32le) | cert
    const utf16 = (bytes) => { let s = ''; for (let i = 0; i + 1 < bytes.length; i += 2) s += String.fromCharCode(bytes[i] | (bytes[i + 1] << 8)); return s; };
    const toUtf16 = (str) => { const out = new Uint8Array(str.length * 2); for (let i = 0; i < str.length; i++) { const c = str.charCodeAt(i); out[i * 2] = c & 0xff; out[i * 2 + 1] = c >> 8; } return out; };
    const buildSpcInit = (initData, contentId, cert) => {
      const id = toUtf16(contentId);
      const buf = new Uint8Array(initData.byteLength + 4 + id.byteLength + 4 + cert.byteLength);
      const dv = new DataView(buf.buffer);
      let o = 0;
      buf.set(initData, o); o += initData.byteLength;
      dv.setUint32(o, id.byteLength, true); o += 4;
      buf.set(id, o); o += id.byteLength;
      dv.setUint32(o, cert.byteLength, true); o += 4;
      buf.set(cert, o);
      return buf;
    };
    let certBytes = null;
    const sessions = {};
    el.addEventListener('webkitneedkey', async (ev) => {
      try {
        const initData = new Uint8Array(ev.initData);
        // initData 的编码随 WebKit 版本而异（UTF-16 URI / 其他封装），只做诊断打印；
        // content ID 直接用 Dart 传来的 file_id（与清单 skd:// 一致），不依赖解析 initData
        const hex = Array.from(initData.slice(0, 48), (b) => b.toString(16).padStart(2, '0')).join('');
        const asU16 = utf16(initData).replace(/[^\x20-\x7e]/g, '.');
        const asU8 = new TextDecoder().decode(initData).replace(/[^\x20-\x7e]/g, '.');
        gsend('log', {msg: 'webkitneedkey initData=' + initData.byteLength + 'B hex=' + hex + ' u16=' + asU16.slice(0, 80) + ' u8=' + asU8.slice(0, 80)});
        const contentId = String(fileIdHex || '');
        if (!contentId) throw new Error('缺 file_id（content ID）');
        if (sessions[contentId]) { gsend('log', {msg: 'needkey 重复（已有会话），忽略'}); return; }
        if (!el.webkitKeys) el.webkitSetMediaKeys(new WebKitMediaKeys('com.apple.fps.1_0'));
        if (!certBytes) {
          const r = await fetch('/cert');
          if (!r.ok) throw new Error('证书 HTTP ' + r.status);
          certBytes = new Uint8Array(await r.arrayBuffer());
        }
        if (audio !== el || curGen !== myGen || intentGen !== myGen) return;
        const session = el.webkitKeys.createSession('audio/mp4', buildSpcInit(initData, contentId, certBytes));
        sessions[contentId] = session;
        gsend('log', {msg: 'FPS 会话已建 sessionId=' + session.sessionId});
        session.addEventListener('webkitkeymessage', async (e) => {
          if (audio !== el || curGen !== myGen || intentGen !== myGen) return;
          const spc = new Uint8Array(e.message);
          gsend('log', {msg: 'webkitkeymessage SPC=' + spc.byteLength + 'B'});
          try {
            const r = await fetch('/license', {method: 'POST', body: spc});
            if (!r.ok) { gsend('error', {msg: 'license HTTP ' + r.status + ' ' + (await r.text()).slice(0, 200)}); return; }
            const ckc = new Uint8Array(await r.arrayBuffer());
            gsend('log', {msg: 'CKC=' + ckc.byteLength + 'B → session.update'});
            if (audio === el && curGen === myGen && intentGen === myGen) session.update(ckc);
          } catch (err) { gsend('error', {msg: 'license 请求异常: ' + err}); }
        });
        session.addEventListener('webkitkeyadded', () => gsend('log', {msg: 'FPS 密钥已装载（webkitkeyadded）'}));
        session.addEventListener('webkitkeyerror', () => gsend('error',
          {msg: 'FPS keyerror code=' + (session.error && session.error.code) + ' systemCode=' + (session.error && session.error.systemCode)}));
      } catch (err) { gsend('error', {msg: 'needkey 处理异常: ' + err}); }
    });
    el.src = '/audio.m3u8';
    el.load();
    playIfRequested(el, myGen);
    gsend('log', {msg: '原生 HLS 已启动（FairPlay 旧版 EME）'});
    return 'ok';
  } catch (e) {
    return 'ERR:' + String(e);
  }
})();

// 启动时探测一次各 DRM 体系是否可用：结果写进日志，不可用时上报给 Dart
//（该设备随后的播放错误按「缺 Widevine/FairPlay」归类，提示重试无意义。
// 两套都探：macOS 用 com.apple.fps，桌面其余用 com.widevine.alpha；
// FairPlay 的 initDataTypes 对齐 hls.js 的 ['cenc','sinf']）
(async () => {
  // 原生 HLS + 旧版 EME（Spotify 自家 Safari 播放器走的路：SPC 的 content ID 由页面自填）能力探测
  try {
    const a = document.createElement('audio');
    const legacy = typeof WebKitMediaKeys !== 'undefined';
    const fps10 = legacy && WebKitMediaKeys.isTypeSupported('com.apple.fps.1_0', 'audio/mp4');
    send('log', {msg: '原生 HLS canPlayType=' + JSON.stringify(a.canPlayType('application/vnd.apple.mpegurl'))
      + ' WebKitMediaKeys=' + legacy
      + ' fps.1_0=' + (legacy ? fps10 : 'n/a')
      + ' webkitSetMediaKeys=' + (typeof a.webkitSetMediaKeys)});
    // FairPlay 播放走的就是这套旧版 API（emePlayNativeFps），可用与否以它为准
    if (!fps10) send('fairplayUnavailable', {msg: legacy ? 'WebKitMediaKeys 不支持 com.apple.fps.1_0' : '无 WebKitMediaKeys（旧版 EME）'});
  } catch (e) { send('log', {msg: '原生 HLS/旧版 EME 探测异常: ' + e}); }
  for (const [ks, label, init] of [
    ['com.widevine.alpha', 'widevine', ['cenc']],
    ['com.apple.fps', 'fairplay', ['cenc', 'sinf']],
  ]) {
    try {
      const access = await navigator.requestMediaKeySystemAccess(ks, [{
        initDataTypes: init,
        audioCapabilities: [{contentType: 'audio/mp4; codecs="mp4a.40.2"'}],
      }]);
      send('log', {msg: ks + ' 可用 ' + JSON.stringify(access.getConfiguration().audioCapabilities)});
    } catch (e) {
      // 其他平台本来就没有 FairPlay：探测结果不是错误，不带错误名（避免日志按错误附调用栈）
      const unsupportedHere = label === 'fairplay' && e && e.name === 'NotSupportedError';
      send('log', {msg: unsupportedHere ? ks + ' 本平台不支持（正常）' : ks + ' 不可用: ' + e});
      // 新版 com.apple.fps 只记日志：FairPlay 的可用性以上面的旧版 API 探测为准
      if (label !== 'fairplay') send(label + 'Unavailable', {msg: String(e)});
    }
  }
  send('log', {msg: 'UA ' + navigator.userAgent});
})();

window.emePause = (gen = curGen, revision = intentRevision + 1) => {
  if (acceptIntent(gen, revision, false) && audio) audio.pause();
};
window.emeResume = (gen = curGen, revision = intentRevision + 1) => {
  if (acceptIntent(gen, revision, true) && curGen === gen && audio) playIfRequested(audio, gen);
};
window.emeStop = (gen, revision) => {
  if (!acceptIntent(gen, revision, false)) return;
  if (hls) { hls.destroy(); hls = null; }
  if (audio) { audio.pause(); audio.removeAttribute('src'); audio.load(); audio.remove(); audio = null; }
  if (telemetryTimer) { clearInterval(telemetryTimer); telemetryTimer = null; }
};
window.emeSeek = (sec) => { if (audio) audio.currentTime = sec; };
window.emeSyncPosition = (gen = curGen) => {
  if (audio && curGen === (Number(gen) || 0)) {
    send('position', {position: audio.currentTime, duration: audio.duration, gen: curGen});
  }
};
window.emeSetSink = (label) => {
  pageSinkLabel = typeof label === 'string' ? label : '';
  if (audio) applySink(audio);
};
window.emeSetVolume = (v) => {
  if (!(v >= 0 && v <= 1)) return;
  pageVolume = v;
  if (audio) audio.volume = v;
};
</script>
</body>
</html>
''';
