'use strict';
// MameLLM front end: plain DOM, no dependencies.

const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];

// h('div.cls', {attrs}, ...children) — children are nodes or strings (as text).
function h(spec, attrs, ...kids) {
  const [tag, ...cls] = spec.split('.');
  const el = document.createElement(tag || 'div');
  if (cls.length) el.className = cls.join(' ');
  for (const [k, v] of Object.entries(attrs || {})) {
    if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (v === true) el.setAttribute(k, '');
    else if (v !== false && v != null) el.setAttribute(k, v);
  }
  for (const kid of kids.flat()) if (kid != null && kid !== false) el.append(kid);
  return el;
}

function toast(msg) {
  const t = $('#toast');
  t.textContent = msg;
  t.classList.add('on');
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => t.classList.remove('on'), 4000);
}

async function api(path, body) {
  const opt = body === undefined ? {} : {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'X-MameLLM': '1' }, body: JSON.stringify(body),
  };
  const res = await fetch(path, opt);
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}
// run an action, surface its error, then refresh
async function act(path, body) {
  try { const r = await api(path, body); await refresh(); return r; }
  catch (e) { toast(e.message); return null; }
}

const gb = n => n >= 1e9 ? (n / 2 ** 30).toFixed(1) + ' GB' : Math.max(1, Math.round(n / 2 ** 20)) + ' MB';
const FIT = { good: '快適', ok: '動作可', tight: 'ぎりぎり', no: 'メモリ不足', unknown: 'サイズ不明' };

let S = null;          // last /api/state
let filter = 'fit';
let lastKey = '';

// ---------- tabs ----------
$('#tabs').addEventListener('click', e => {
  const t = e.target.dataset.tab;
  if (!t) return;
  $$('#tabs button').forEach(b => b.classList.toggle('on', b === e.target));
  $$('.tab').forEach(s => s.classList.toggle('on', s.id === 'tab-' + t));
});
function showTab(t) { $(`#tabs button[data-tab="${t}"]`).click(); }

$('#filters').addEventListener('click', e => {
  if (!e.target.dataset.f) return;
  filter = e.target.dataset.f;
  $$('#filters .chip').forEach(b => b.classList.toggle('on', b === e.target));
  renderModels();
});
$('#addtabs').addEventListener('click', e => {
  const a = e.target.dataset.a;
  if (!a) return;
  $$('#addtabs .chip').forEach(b => b.classList.toggle('on', b === e.target));
  $$('form.add').forEach(f => f.classList.toggle('on', f.dataset.a === a));
});

// ---------- state polling ----------
async function refresh() {
  try { S = await api('/api/state'); } catch (e) { return; }
  const key = JSON.stringify([S.models, S.jobs, S.sources, S.runtime, S.engine]);
  renderHeader();
  if (key !== lastKey) {
    lastKey = key;
    renderRuntime(); renderJobs(); renderModels(); renderSources(); renderChatBar();
  }
  if (!refresh.filled) { fillSettings(); refresh.filled = true; }
}
function poll() {
  refresh().finally(() => {
    const busy = S && (S.jobs.some(j => j.status === 'running' || j.status === 'verifying') || S.engine.status === 'loading');
    setTimeout(poll, busy ? 800 : 2500);
  });
}

function renderHeader() {
  $('#ver').textContent = 'v' + S.version;
  const s = S.sys;
  const chip = s.chip || (s.arch === 'arm64' ? 'Apple Silicon' : s.arch);
  $('#sysline').textContent = `${chip}・メモリ ${gb(s.ram_total)}(空き約 ${gb(s.ram_avail)})`;
}

// ---------- runtime + jobs ----------
function renderRuntime() {
  const box = $('#runtime-box');
  box.replaceChildren();
  const job = S.jobs.find(j => j.model_id === '@runtime' && (j.status === 'running' || j.status === 'verifying'));
  if (S.runtime.found) {
    const i = S.runtime.info;
    const origin = { managed: `このアプリが導入 (${i.version})`, system: 'システムにインストール済みのもの', settings: '設定で指定したもの' }[i.origin];
    box.append(h('p.muted', {}, `ランタイム: llama.cpp(${origin}) `,
      S.runtime.installable && !job && h('button.ghost.small', { onclick: () => act('/api/runtime/install', {}) }, '最新版に更新')));
    return;
  }
  box.append(h('div.card.banner', {},
    h('div.title', {}, h('b', {}, '最初に: 推論ランタイム(llama.cpp)をインストールしてください')),
    h('p.muted', {}, S.runtime.installable
      ? 'モデルを動かすエンジンです(約数十MB)。公式ビルドを自動で取得します。'
      : 'この環境向けの公式ビルドがありません。llama-server を別途用意して「設定」でパスを指定してください。'),
    S.runtime.installable && h('button', { disabled: !!job, onclick: () => act('/api/runtime/install', {}) }, job ? 'インストール中…' : 'ランタイムをインストール')));
}

function jobView(j) {
  const active = j.status === 'running' || j.status === 'verifying';
  const pct = j.total > 0 ? Math.min(100, j.bytes / j.total * 100) : 0;
  const label = { running: 'ダウンロード中', verifying: '検証中(SHA-256)', done: '完了', error: '失敗', canceled: '中断(続きから再開できます)' }[j.status];
  return h('div.card.job', {},
    h('div.row', {},
      h('b', {}, j.name), h('span.badge' + (j.status === 'error' ? '.no' : ''), {}, label),
      h('span.muted.grow', {}, active ? `${j.source}・${gb(j.bytes)}${j.total ? ' / ' + gb(j.total) : ''}${j.speed > 0 ? '・' + gb(j.speed) + '/秒' : ''}` : ''),
      active
        ? h('button.ghost.small', { onclick: () => act('/api/downloads/cancel', { id: j.id }) }, '中断')
        : h('button.ghost.small', { onclick: () => act('/api/downloads/dismiss', { id: j.id }) }, '閉じる')),
    active && h('div.bar', {}, h('i', { style: `width:${pct}%` })),
    j.error && h('div', { style: 'color:var(--bad);font-size:13px' }, j.error),
    (active || j.status === 'error') && j.log.length > 0 && h('div.log', {}, j.log.slice(-5).join('\n')));
}
function renderJobs() {
  $('#jobs').replaceChildren(...S.jobs.filter(j => j.status !== 'done' || j.model_id === '@runtime').map(jobView));
}

// ---------- models ----------
function renderModels() {
  if (!S) return;
  const srcName = Object.fromEntries(S.sources.map(s => [s.id, s.name]));
  const list = S.models.filter(m => {
    if (filter === 'fit') return m.installed || m.fit === 'good' || m.fit === 'ok' || m.custom;
    if (filter === 'ja') return (m.tags || []).includes('日本語');
    if (filter === 'installed') return m.installed;
    return true;
  });
  const cards = list.map(m => {
    const job = S.jobs.find(j => j.model_id === m.id && (j.status === 'running' || j.status === 'verifying'));
    const actions = h('div.actions');
    if (m.installed) {
      actions.append(
        h('button', { onclick: () => useModel(m.id) }, 'チャットで使う'),
        m.local_path ? null : h('button.danger.small', { onclick: () => confirm(`「${m.name}」のファイルを削除しますか?`) && act('/api/models/delete', { id: m.id }) }, 'ファイルを削除'));
    } else if (job) {
      actions.append(h('button.ghost', { onclick: () => act('/api/downloads/cancel', { id: job.id }) }, '中断'));
    } else {
      const sel = h('select', { title: 'ダウンロード元' }, h('option', { value: '' }, '自動(優先順に試す)'),
        m.sources.map(id => h('option', { value: id }, srcName[id] || id)));
      actions.append(
        h('button', { disabled: !m.sources.length, onclick: () => act('/api/models/download', { id: m.id, source: sel.value }) }, 'ダウンロード'),
        m.sources.length ? sel : h('span.muted', {}, '有効な取得元なし'));
    }
    if (m.custom) actions.append(h('button.danger.small', {
      onclick: () => confirm(`「${m.name}」を一覧から削除しますか?${m.local_path ? '(元のファイルは残ります)' : '(ダウンロード済みファイルも削除)'}`) && act('/api/models/remove', { id: m.id }),
    }, '一覧から削除'));
    return h('div.card.model', {},
      h('div.title', {}, m.name, ' ', m.custom && h('span.tag', {}, '追加')),
      actions,
      h('div.desc', {}, m.description || (m.local_path ? m.local_path : '')),
      h('div.info', {},
        h('span.badge.' + m.fit, {}, FIT[m.fit]),
        m.size > 0 && h('span.muted', {}, `${gb(m.size)}・必要メモリ約 ${gb(m.need)}`),
        (m.tags || []).map(t => h('span.tag', {}, t)),
        m.license && h('span.muted', {}, m.license),
        !m.installed && m.sources.length > 0 && h('span.muted', {}, `取得元 ${m.sources.length}件`)),
      job && h('div', { style: 'grid-column:1/-1' },
        h('div.bar', {}, h('i', { style: `width:${job.total ? job.bytes / job.total * 100 : 0}%` })),
        h('span.muted', {}, `${job.status === 'verifying' ? '検証中' : job.source}・${gb(job.bytes)} / ${gb(job.total || m.size)}${job.speed > 0 ? '・' + gb(job.speed) + '/秒' : ''}`)));
  });
  $('#model-list').replaceChildren(...(cards.length ? cards : [h('p.muted', {}, '該当するモデルがありません。')]));
}

$$('form.add').forEach(f => f.addEventListener('submit', async e => {
  e.preventDefault();
  const d = Object.fromEntries(new FormData(f));
  const kind = f.dataset.a;
  if (kind === 'search') return search(d.q);
  const body = { name: d.name || '', download: true };
  if (kind === 'hf') body.refs = [{ kind: 'hf', repo: d.repo, file: d.file }];
  if (kind === 'ollama') body.refs = [{ kind: 'ollama', ref: d.ref }];
  if (kind === 'url') body.refs = [{ kind: 'url', url: d.url }];
  if (kind === 'local') body.local_path = d.path;
  if (await act('/api/models/add', body)) {
    f.reset();
    toast(kind === 'local' ? '登録しました' : '追加してダウンロードを開始しました');
    filter = 'all';
    $$('#filters .chip').forEach(b => b.classList.toggle('on', b.dataset.f === 'all'));
    renderModels();
    $('#jobs').scrollIntoView({ behavior: 'smooth' });
  }
}));

async function search(q) {
  const box = $('#search-results');
  box.replaceChildren(h('p.muted', {}, '検索中…'));
  try {
    const r = await api('/api/search?q=' + encodeURIComponent(q || ''));
    if (!r.results.length) return box.replaceChildren(h('p.muted', {}, '見つかりませんでした。'));
    box.replaceChildren(h('p.muted', {}, `${r.source} の検索結果(ダウンロード数順)`), ...r.results.map(x => {
      const files = h('div.files');
      const row = h('div.row', { onclick: () => loadFiles(x.id, files) },
        h('b.grow', {}, x.id), h('span.muted', {}, `↓${x.downloads.toLocaleString()}`));
      return h('div.repo', {}, row, files);
    }));
  } catch (e) { box.replaceChildren(h('p', { style: 'color:var(--bad)' }, e.message)); }
}
async function loadFiles(repo, box) {
  if (box.childElementCount) return box.replaceChildren();
  box.replaceChildren(h('span.muted', {}, 'ファイル一覧を取得中…'));
  try {
    const r = await api('/api/repo-files?repo=' + encodeURIComponent(repo));
    r.files.sort((a, b) => a.size - b.size);
    box.replaceChildren(...(r.files.length ? r.files.map(f => h('div.row', {},
      h('span.grow', { style: 'font-size:13px;overflow-wrap:anywhere' }, f.path),
      h('span.muted', {}, gb(f.size)), h('span.badge.' + f.fit, {}, FIT[f.fit]),
      h('button.small', {
        onclick: async () => {
          const ok = await act('/api/models/add', { name: '', download: true, size: f.size, refs: [{ kind: 'hf', repo, file: f.path, size: f.size, sha256: f.sha256 || '' }] });
          if (ok) { toast('追加してダウンロードを開始しました'); $('#jobs').scrollIntoView({ behavior: 'smooth' }); }
        },
      }, '追加'))) : [h('span.muted', {}, 'GGUFファイルがありません')]));
  } catch (e) { box.replaceChildren(h('span', { style: 'color:var(--bad)' }, e.message)); }
}

// ---------- sources ----------
const KIND = { hf: 'HF互換', modelscope: 'ModelScope', ollama: 'Ollama', template: 'テンプレート', url: '直接URL', github: 'GitHub', 'github-mirror': 'GitHubプロキシ' };
function renderSources() {
  const view = s => {
    const result = h('span.muted');
    return h('div.card.src' + (s.enabled ? '' : '.off'), {},
      h('input', { type: 'checkbox', checked: s.enabled, title: '有効/無効', onchange: e => act('/api/sources/enable', { id: s.id, on: e.target.checked }) }),
      h('div.grow', {},
        h('div', {}, h('span.name', {}, s.name), ' ', h('span.tag', {}, KIND[s.kind] || s.kind), ' ',
          s.unofficial && h('span.tag', {}, '非公式'), ' ', !s.builtin && h('span.tag', {}, '追加')),
        s.base && h('div.url', {}, s.base),
        s.note && h('div.muted', {}, s.note)),
      result,
      h('button.ghost.small', { onclick: async () => {
        result.textContent = '確認中…';
        try { const r = await api('/api/sources/test', { id: s.id }); result.textContent = (r.ok ? '✓ ' : '✗ ') + r.detail; }
        catch (e) { result.textContent = '✗ ' + e.message; }
      } }, '接続テスト'),
      h('button.ghost.small', { title: '優先度を上げる', onclick: () => act('/api/sources/move', { id: s.id, dir: -1 }) }, '↑'),
      h('button.ghost.small', { title: '優先度を下げる', onclick: () => act('/api/sources/move', { id: s.id, dir: 1 }) }, '↓'),
      !s.builtin && h('button.danger.small', { onclick: () => confirm(`「${s.name}」を削除しますか?`) && act('/api/sources/remove', { id: s.id }) }, '削除'));
  };
  $('#src-models').replaceChildren(...S.sources.filter(s => !s.runtime).map(view));
  $('#src-runtime').replaceChildren(...S.sources.filter(s => s.runtime).map(view));
}
const HINTS = {
  hf: 'Hugging Faceと同じURL構造のミラー。{入力したURL}/{リポジトリ}/resolve/main/{ファイル} から取得します。',
  template: '{repo} と {file} を含むURL。例: https://example.com/models/{repo}/{file}',
  ollama: 'Ollama(OCI)レジストリ互換のホスト。例: https://registry.example.com',
  modelscope: '{入力したURL}/models/{リポジトリ}/resolve/master/{ファイル} から取得します。',
  'github-mirror': 'GitHubのURLの前に付けるプロキシ。例: https://gh-proxy.com/',
};
const srcForm = $('#src-add');
const hint = () => { $('#src-hint').textContent = HINTS[srcForm.kind.value]; };
srcForm.kind.addEventListener('change', hint); hint();
srcForm.addEventListener('submit', async e => {
  e.preventDefault();
  if (await act('/api/sources/add', Object.fromEntries(new FormData(srcForm)))) { srcForm.reset(); hint(); toast('ダウンロード元を追加しました'); }
});

// ---------- settings ----------
const setForm = $('#settings');
function fillSettings() {
  const s = S.settings, a = S.auto;
  for (const k of ['context_size', 'threads', 'gpu_layers', 'idle_minutes', 'max_tokens', 'temperature', 'system_prompt', 'runtime_path', 'extra_args'])
    setForm[k].value = s[k];
  setForm.hf_token.value = '';
  $('#h-ctx').textContent = `0で自動(このMacでは ${a.context_size})。小さいほど省メモリ。`;
  $('#h-thr').textContent = `0で自動(このMacでは ${a.threads})。`;
  $('#h-gpu').textContent = `-1で自動(このMacでは ${a.gpu_layers}${a.gpu_layers ? '=Metal使用' : '=CPUのみ'})。`;
  $('#h-tok').textContent = s.hf_token ? '設定済み(変更する場合のみ入力。消すには半角スペースを1つ入力して保存)' : '';
  $('#datadir').textContent = `モデルと設定の保存先: ${S.data_dir}`;
}
setForm.addEventListener('submit', async e => {
  e.preventDefault();
  const body = {};
  for (const k of ['context_size', 'threads', 'gpu_layers', 'idle_minutes', 'max_tokens']) body[k] = parseInt(setForm[k].value || '0', 10);
  body.temperature = parseFloat(setForm.temperature.value || '0');
  for (const k of ['system_prompt', 'runtime_path', 'extra_args']) body[k] = setForm[k].value;
  if (setForm.hf_token.value !== '') body.hf_token = setForm.hf_token.value; // untouched = keep
  if (await act('/api/settings', body)) {
    fillSettings();
    $('#saved').textContent = '保存しました(モデル読み込みに関わる項目は次回の読み込みから反映)';
    setTimeout(() => { $('#saved').textContent = ''; }, 5000);
  }
});

$('#quit').addEventListener('click', async () => {
  if (!confirm('MameLLMを終了しますか?')) return;
  try { await api('/api/quit', {}); } catch { /* it may exit before answering */ }
  document.body.replaceChildren(h('p', { style: 'margin:auto;padding:40px' }, 'MameLLMを終了しました。このタブは閉じて構いません。'));
});

// ---------- chat ----------
const store = {
  get(k, d) { try { return JSON.parse(localStorage.getItem(k)) ?? d; } catch { return d; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch { /* private mode */ } },
};
let chat = store.get('mamellm.chat', []);   // [{role, content, reasoning?}]
let chatModel = store.get('mamellm.model', '');
let streaming = null;                        // AbortController while generating

function renderChatBar() {
  const installed = S.models.filter(m => m.installed);
  const sel = $('#chat-model');
  if (!installed.some(m => m.id === chatModel)) chatModel = installed[0]?.id || '';
  sel.replaceChildren(...installed.map(m => h('option', { value: m.id, selected: m.id === chatModel }, `${m.name}(${gb(m.size)})`)));
  sel.hidden = !installed.length;
  const e = S.engine, name = S.models.find(m => m.id === e.model_id)?.name || '';
  const pill = $('#engine-pill');
  pill.className = 'pill ' + e.status;
  pill.textContent = { stopped: 'メモリ未使用', loading: `${name} を読み込み中…`, ready: `${name} 読み込み済み`, error: 'エラー' }[e.status];
  pill.title = e.error || '';
  $('#unload').hidden = e.status !== 'ready';
  const empty = $('#chat-empty');
  empty.classList.toggle('on', !chat.length);
  if (!chat.length) {
    empty.replaceChildren(!installed.length
      ? h('div', {}, h('p', {}, 'まだモデルがありません。'), h('button', { onclick: () => showTab('models') }, 'モデルを選んでダウンロード'))
      : h('div', {}, h('p', {}, 'メッセージを送ると、モデルを読み込んで会話を始めます。'),
        e.status === 'error' && h('p', { style: 'color:var(--bad)' }, e.error)));
  }
  $('#send').disabled = !installed.length && !streaming;
}
$('#chat-model').addEventListener('change', e => { chatModel = e.target.value; store.set('mamellm.model', chatModel); });
$('#unload').addEventListener('click', () => act('/api/engine/stop', {}));
$('#newchat').addEventListener('click', () => {
  if (streaming) streaming.abort();
  chat = []; store.set('mamellm.chat', chat); renderMessages(); renderChatBar();
});
function useModel(id) {
  chatModel = id; store.set('mamellm.model', id);
  renderChatBar(); showTab('chat'); $('#input').focus();
}

// text with ``` fences rendered as <pre>; everything is inserted as text
function richText(text) {
  const out = [];
  text.split(/```/).forEach((part, i) => {
    if (i % 2) out.push(h('pre', {}, part.replace(/^[^\n]*\n/, '')));
    else if (part) out.push(part);
  });
  return out;
}
function msgNode(m) {
  if (m.role === 'error') return h('div.msg.error', {}, m.content);
  return h('div.msg.' + m.role, {},
    m.reasoning && h('details', {}, h('summary', {}, '思考過程'), m.reasoning),
    m.role === 'assistant' ? richText(m.content) : m.content,
    m.meta && h('span.meta', {}, m.meta));
}
function renderMessages() {
  const box = $('#messages');
  const stick = box.scrollHeight - box.scrollTop - box.clientHeight < 60;
  box.replaceChildren(...chat.map(msgNode));
  if (stick) box.scrollTop = box.scrollHeight;
}

async function send(text) {
  chat = chat.filter(m => m.role !== 'error');
  chat.push({ role: 'user', content: text });
  const reply = { role: 'assistant', content: '', meta: '読み込み・生成中…' };
  const history = chat.map(({ role, content }) => ({ role, content }));
  chat.push(reply);
  $('#chat-empty').classList.remove('on');
  renderMessages();
  $('#messages').scrollTop = $('#messages').scrollHeight;
  streaming = new AbortController();
  $('#send').textContent = '停止';
  const t0 = performance.now();
  let tokens = 0, tFirst = 0;
  setTimeout(refresh, 300); // show "loading" promptly
  try {
    const res = await fetch('/api/chat', {
      method: 'POST', signal: streaming.signal,
      headers: { 'Content-Type': 'application/json', 'X-MameLLM': '1' },
      body: JSON.stringify({ model: chatModel, messages: history }),
    });
    if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error || `HTTP ${res.status}`);
    const reader = res.body.getReader(), dec = new TextDecoder();
    let buf = '';
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      const lines = buf.split('\n');
      buf = lines.pop();
      for (const line of lines) {
        if (!line.startsWith('data:')) continue;
        const data = line.slice(5).trim();
        if (data === '[DONE]') continue;
        let j; try { j = JSON.parse(data); } catch { continue; }
        if (j.error) throw new Error(j.error.message || JSON.stringify(j.error));
        const d = j.choices?.[0]?.delta || {};
        if (d.reasoning_content) reply.reasoning = (reply.reasoning || '') + d.reasoning_content;
        if (d.content) reply.content += d.content;
        if (d.content || d.reasoning_content) { tokens++; tFirst ||= performance.now(); }
      }
      reply.meta = '生成中…';
      renderMessages();
    }
    const secs = (performance.now() - (tFirst || t0)) / 1000;
    reply.meta = tokens > 1 && secs > 0 ? `約 ${(tokens / secs).toFixed(1)} トークン/秒` : '';
    if (!reply.content && !reply.reasoning) reply.content = '(空の応答)';
  } catch (e) {
    reply.meta = '';
    if (e.name === 'AbortError') reply.meta = '停止しました';
    else chat.push({ role: 'error', content: e.message });
    if (!reply.content && !reply.reasoning) chat.splice(chat.indexOf(reply), 1);
  }
  streaming = null;
  $('#send').textContent = '送信';
  store.set('mamellm.chat', chat.filter(m => m.role !== 'error'));
  renderMessages();
  refresh();
}
$('#composer').addEventListener('submit', e => {
  e.preventDefault();
  if (streaming) return streaming.abort();
  const text = $('#input').value.trim();
  if (!text) return;
  if (!chatModel) return toast('先にモデルをダウンロードしてください');
  $('#input').value = '';
  send(text);
});
$('#input').addEventListener('keydown', e => {
  if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); $('#composer').requestSubmit(); }
});

renderMessages();
poll();
