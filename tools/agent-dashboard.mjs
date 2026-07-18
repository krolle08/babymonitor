// Live dashboard for the implement-babymonitor workflow.
// Zero dependencies. Reads journal.jsonl + agent transcript tails, serves a
// self-refreshing page on http://localhost:5599
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';

const WF_DIR = String.raw`C:\Users\dichl\.claude\projects\D--Projekter-babymonitor\62593734-6fd3-4223-951e-2ba384a86d1c\subagents\workflows\wf_ca21c17c-39b`;
const PORT = 5599;

// Known agents: key-hash prefix -> identity. Later phases get named by order of appearance.
const KNOWN = {
  '9d2437a9': { id: 'server',   emoji: '🖥️', name: 'Server',      role: 'Node signaling + sleep-log REST + tests', phase: 'Foundations' },
  '5c036e6b': { id: 'core',     emoji: '🧠', name: 'Dart core',   role: 'Health FSM · backoff · freeze · noise (pure Dart)', phase: 'Foundations' },
  '33c10897': { id: 'platform', emoji: '📱', name: 'Platform',    role: 'Android minSdk 26 · iOS 14 · permissions', phase: 'Foundations' },
};
const LATER = [
  { id: 'services', emoji: '🔌', name: 'Services',    role: 'WebRTC sessions · signaling client · sleep logger', phase: 'Services' },
  { id: 'ui',       emoji: '🎨', name: 'UI',          role: 'Screens · widgets · main.dart', phase: 'UI' },
  { id: 'green',    emoji: '✅', name: 'Build green', role: 'analyze · all tests · wire compat · APK attempt', phase: 'Build green' },
];
const PHASES = ['Foundations', 'Services', 'UI', 'Build green'];

function readJournal() {
  try {
    const txt = fs.readFileSync(path.join(WF_DIR, 'journal.jsonl'), 'utf8');
    return txt.split('\n').filter(Boolean).map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  } catch { return []; }
}

function lastActivity(agentId) {
  // Scan the transcript backwards for the most recent assistant tool_use.
  try {
    const f = path.join(WF_DIR, `agent-${agentId}.jsonl`);
    const stat = fs.statSync(f);
    const lines = fs.readFileSync(f, 'utf8').split('\n').filter(Boolean);
    for (let i = lines.length - 1; i >= Math.max(0, lines.length - 25); i--) {
      let msg; try { msg = JSON.parse(lines[i]); } catch { continue; }
      if (msg.type !== 'assistant' || !msg.message?.content) continue;
      for (const block of [...msg.message.content].reverse()) {
        if (block.type === 'tool_use') {
          const inp = block.input || {};
          const detail = inp.description
            || (inp.file_path && `${block.name} ${path.basename(inp.file_path)}`)
            || (inp.command && String(inp.command).slice(0, 80))
            || (inp.pattern && `search: ${inp.pattern}`) || '';
          return { tool: block.name, detail: String(detail).slice(0, 110), steps: lines.length, mtime: stat.mtimeMs };
        }
        if (block.type === 'text' && block.text) {
          return { tool: 'thinking', detail: String(block.text).slice(0, 110), steps: lines.length, mtime: stat.mtimeMs };
        }
      }
    }
    return { tool: '…', detail: 'working', steps: lines.length, mtime: stat.mtimeMs };
  } catch { return null; }
}

function buildState() {
  const journal = readJournal();
  const seenKeys = [];
  const byKey = new Map();
  for (const e of journal) {
    if (!e.key) continue;
    if (!byKey.has(e.key)) { byKey.set(e.key, {}); seenKeys.push(e.key); }
    const rec = byKey.get(e.key);
    if (e.type === 'started') { rec.agentId = e.agentId; rec.started = true; }
    if (e.type === 'result') { rec.agentId = e.agentId; rec.result = e.result; }
  }
  let laterIdx = 0;
  const agents = [];
  const assigned = new Set();
  for (const key of seenKeys) {
    const hash = key.replace(/^v2:/, '').slice(0, 8);
    let ident = KNOWN[hash];
    if (!ident) ident = LATER[Math.min(laterIdx++, LATER.length - 1)];
    assigned.add(ident.id);
    const rec = byKey.get(key);
    const act = rec.agentId ? lastActivity(rec.agentId) : null;
    agents.push({
      ...ident,
      status: rec.result ? (rec.result.status === 'done' ? 'done' : 'blocked') : 'running',
      summary: rec.result?.summary || null,
      files: rec.result?.files?.length ?? null,
      testsPassed: rec.result?.testsPassed ?? null,
      activity: rec.result ? null : act,
      steps: act?.steps ?? null,
      lastTouch: act?.mtime ?? null,
    });
  }
  for (const ident of [...Object.values(KNOWN), ...LATER]) {
    if (!assigned.has(ident.id)) agents.push({ ...ident, status: 'queued', summary: null, files: null, testsPassed: null, activity: null });
  }
  let startMs = null;
  try { startMs = fs.statSync(path.join(WF_DIR, 'journal.jsonl')).birthtimeMs; } catch {}
  const doneCount = agents.filter(a => a.status === 'done').length;
  const blocked = agents.some(a => a.status === 'blocked');
  const allDone = doneCount === agents.length;
  return { agents, phases: PHASES, startMs, now: Date.now(), doneCount, total: agents.length, overall: blocked ? 'blocked' : allDone ? 'complete' : 'running' };
}

const PAGE = `<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Baby Monitor — Agent Workflow</title><style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0d0f14;color:#e8eaf0;font-family:'SF Mono','Cascadia Code','Fira Code',monospace;font-size:13px;padding:28px 22px;min-height:100vh}
h1{font-family:system-ui,sans-serif;font-size:19px;font-weight:600;color:#fff;letter-spacing:-.3px}
.sub{font-family:system-ui,sans-serif;font-size:12px;color:#6b7280;margin:4px 0 24px}
.sub b{color:#9ca3af}
.overall{display:inline-block;font-size:11px;font-weight:700;letter-spacing:1px;text-transform:uppercase;padding:3px 10px;border-radius:5px;margin-left:8px}
.overall.running{background:#2e1065;color:#c4b5fd}
.overall.complete{background:#064e3b;color:#10b981}
.overall.blocked{background:#450a0a;color:#ef4444}
.phases{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;max-width:1200px}
@media(max-width:900px){.phases{grid-template-columns:1fr 1fr}}
.phase{background:#12141c;border:1px solid #232838;border-radius:12px;padding:14px;min-height:120px}
.phase h2{font-family:system-ui,sans-serif;font-size:10px;font-weight:700;letter-spacing:1.5px;text-transform:uppercase;color:#4b5563;margin-bottom:12px}
.phase.active h2{color:#8b5cf6}
.card{background:#161920;border:1px solid #2a2f3d;border-radius:10px;padding:12px;margin-bottom:10px;transition:border-color .3s}
.card.running{border-color:#8b5cf6}
.card.done{border-color:#1e4536}
.card.blocked{border-color:#ef4444}
.card .head{display:flex;align-items:center;gap:8px;font-family:system-ui,sans-serif;font-size:13px;font-weight:600}
.dot{width:8px;height:8px;border-radius:50%;flex-shrink:0}
.dot.queued{background:#374151}
.dot.done{background:#10b981}
.dot.blocked{background:#ef4444}
.dot.running{background:#8b5cf6;animation:pulse 1.2s ease-in-out infinite}
@keyframes pulse{0%,100%{opacity:1;box-shadow:0 0 0 0 rgba(139,92,246,.6)}50%{opacity:.6;box-shadow:0 0 0 6px rgba(139,92,246,0)}}
.role{font-family:system-ui,sans-serif;font-size:11px;color:#6b7280;margin:6px 0 0;line-height:1.4}
.act{margin-top:9px;padding:7px 9px;background:#0d0f14;border-radius:6px;font-size:11px;color:#a78bfa;line-height:1.5;word-break:break-word}
.act .tool{color:#60a5fa;font-weight:600}
.meta{margin-top:8px;font-family:system-ui,sans-serif;font-size:11px;color:#4b5563}
.meta .ok{color:#10b981}.meta .bad{color:#ef4444}
.sum{margin-top:8px;font-family:system-ui,sans-serif;font-size:11px;color:#9ca3af;line-height:1.5;max-height:76px;overflow:hidden}
.bar{height:4px;background:#1e2330;border-radius:2px;margin:18px 0 26px;max-width:1200px;overflow:hidden}
.bar>div{height:100%;background:linear-gradient(90deg,#3b82f6,#8b5cf6,#10b981);border-radius:2px;transition:width .8s}
footer{margin-top:22px;font-family:system-ui,sans-serif;font-size:11px;color:#374151}
</style></head><body>
<h1>Baby Monitor — Implementation Workflow <span id="overall" class="overall running">running</span></h1>
<div class="sub">run <b>wf_ca21c17c-39b</b> · <span id="prog"></span> · elapsed <b id="elapsed">–</b> · auto-refreshes every 2s</div>
<div class="bar"><div id="barfill" style="width:0%"></div></div>
<div class="phases" id="phases"></div>
<footer>Reading journal.jsonl + live agent transcripts · Claude Code workflow</footer>
<script>
const esc = s => String(s??'').replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
async function tick(){
  let s; try { s = await (await fetch('/api/state')).json(); } catch { return; }
  document.getElementById('overall').textContent = s.overall;
  document.getElementById('overall').className = 'overall ' + s.overall;
  document.getElementById('prog').textContent = s.doneCount + ' / ' + s.total + ' agents done';
  document.getElementById('barfill').style.width = Math.round(100*s.doneCount/s.total) + '%';
  if (s.startMs) {
    const sec = Math.max(0, Math.floor((s.now - s.startMs)/1000));
    document.getElementById('elapsed').textContent = Math.floor(sec/60) + 'm ' + (sec%60) + 's';
  }
  const container = document.getElementById('phases');
  container.innerHTML = s.phases.map(ph => {
    const agents = s.agents.filter(a => a.phase === ph);
    const active = agents.some(a => a.status === 'running');
    return '<div class="phase' + (active ? ' active' : '') + '"><h2>' + esc(ph) + '</h2>' + agents.map(a =>
      '<div class="card ' + a.status + '">'
      + '<div class="head"><span class="dot ' + a.status + '"></span>' + a.emoji + ' ' + esc(a.name) + '</div>'
      + '<div class="role">' + esc(a.role) + '</div>'
      + (a.activity ? '<div class="act"><span class="tool">' + esc(a.activity.tool) + '</span> ' + esc(a.activity.detail) + '</div>' : '')
      + (a.status === 'running' && a.steps ? '<div class="meta">' + a.steps + ' transcript steps</div>' : '')
      + (a.status === 'done' ? '<div class="meta"><span class="ok">✓ done</span> · ' + (a.files ?? '?') + ' files · tests ' + (a.testsPassed ? '<span class="ok">passing</span>' : '<span class="bad">not passing</span>') + '</div>' : '')
      + (a.status === 'blocked' ? '<div class="meta"><span class="bad">✗ blocked</span></div>' : '')
      + (a.summary ? '<div class="sum">' + esc(a.summary.slice(0, 260)) + '…</div>' : '')
      + '</div>').join('') + '</div>';
  }).join('');
}
tick(); setInterval(tick, 2000);
</script></body></html>`;

http.createServer((req, res) => {
  if (req.url === '/api/state') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(buildState()));
  } else {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(PAGE);
  }
}).listen(PORT, () => console.log(`dashboard on http://localhost:${PORT}`));
