#!/usr/bin/env node
// /usr/local/bin/dsh-supervisor.mjs
import { spawn } from 'node:child_process';
import { appendFileSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:net';
import { get as httpGet } from 'node:http';
import { setTimeout as sleep } from 'node:timers/promises';

const HOME = '/root';
const PORT0 = Number(process.env.DSH_PORT || 8790);
const URL_FILE = '/tmp/dsh.url';
const STATE_FILE = '/tmp/dsh.state';
const LOG_FILE = '/var/log/dsh.log';
const DSH_BIN = process.env.DSH_BIN || '/usr/local/bin/dsh';
const HEALTH_MS = 30_000;
const START_TIMEOUT_MS = 300_000;

mkdirSync('/var/run', { recursive: true });
mkdirSync('/var/log', { recursive: true });

let port = PORT0;
let child = null;
let readyUrl = null;
let rapidFail = 0;
let stopping = false;
let restartTimer = null;

function log(line) {
  try {
    const s = `[${new Date().toISOString()}] ${line}\n`;
    const st = (() => { try { return statSync(LOG_FILE).size; } catch { return 0; } })();
    if (st > 5 * 1024 * 1024) rmSync(LOG_FILE, { force: true });
    appendFileSync(LOG_FILE, s);
  } catch {}
}

function writeAtomic(path, text) {
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, text);
  renameSync(tmp, path);
}

function setState(s) { writeAtomic(STATE_FILE, `${s}\n`); }
function setUrl(u) { readyUrl = u; writeAtomic(URL_FILE, `${u}\n`); }
function clearUrl() { readyUrl = null; rmSync(URL_FILE, { force: true }); }

// undici's fetch is fragile inside the guest (single-threaded V8, no epoll
// edge triggers), so probe with node:http instead.
function httpProbe(url, timeoutMs = 5_000) {
  return new Promise((resolve) => {
    let settled = false;
    const done = (v) => { if (!settled) { settled = true; resolve(v); } };
    let req;
    try {
      req = httpGet(url, { timeout: timeoutMs }, (res) => {
        res.resume();
        done({ status: res.statusCode || 0 });
      });
    } catch (e) { done({ error: e }); return; }
    req.on('timeout', () => { req.destroy(new Error('timeout')); done({ error: new Error('timeout') }); });
    req.on('error', (e) => done({ error: e }));
  });
}

async function pickPort() {
  for (let p = PORT0; p < PORT0 + 20; p += 1) {
    const ok = await new Promise((resolve) => {
      const srv = createServer();
      srv.once('error', () => resolve(false));
      srv.once('listening', () => srv.close(() => resolve(true)));
      srv.listen(p, '127.0.0.1');
    });
    if (ok) return p;
  }
  return PORT0;
}

function scheduleRestart(delay) {
  if (stopping || restartTimer) return;
  restartTimer = setTimeout(() => {
    restartTimer = null;
    start().catch((e) => { log(`start failed: ${e.message}`); scheduleRestart(30_000); });
  }, delay);
}

async function start() {
  port = await pickPort();
  setState('starting');
  clearUrl();
  try {
  const args = ['web'];
  if (process.env.DSH_FAST_MODE === '1') {
    // Minimal startup layer: drops office/automation/subagent/web-tool rows.
    args.push('--patch', '/usr/local/share/idsh/fast.patch.yml');
  }
  args.push('--host', '127.0.0.1', '--port', String(port), '--no-open');
  child = spawn(DSH_BIN, args, {
    env: {
      ...process.env,
      HOME,
      DSH_HOME: `${HOME}/.dsh`,
      DSH_PERMISSION_MODE: 'danger-full-access',
      DSH_TELEMETRY_DISABLED: '1',
      PATH: `/usr/local/bin:/usr/bin:/bin`,
      NODE_COMPILE_CACHE: '/tmp/dsh-compile-cache',
    },
    // stdin must stay open: dsh web treats EOF on stdin as a shutdown request.
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  } catch (e) { log(`spawn failed: ${e.message}`); setState('failed'); scheduleRestart(5000); return; }

  let buf = '';
  const onData = (d) => {
    const text = d.toString('utf8').replace(/\x1b\[[0-9;]*m/g, '');
    buf += text;
    const m = buf.match(/dsh web:\s*(https?:\/\/\S+)/);
    if (m && !readyUrl) {
      setUrl(m[1].trim());
      setState('ready');
      rapidFail = 0;
      log(`ready: ${new URL(m[1]).host}`);
    }
    if (text.trim()) log(text.trimEnd());
  };
  child.stdout.on('data', onData);
  child.stderr.on('data', onData);

  // 首选：DSH 启动补丁把 authenticatedUrl 写进 /tmp/dsh.url；stdout 解析只是兜底。
  // URL 出现时 server 可能还没 accept，先 probe 一次再置 ready。
  let checking = false;
  const poll = setInterval(async () => {
    if (readyUrl || checking) return;
    checking = true;
    try {
      const u = readFileSync(URL_FILE, 'utf8').trim();
      if (!u.startsWith('http://') && !u.startsWith('https://')) return;
      const res = await httpProbe(u, 4_000);
      if (res.status >= 200 && res.status < 500) {
        setUrl(u);
        setState('ready');
        rapidFail = 0;
        log(`ready(file): ${new URL(u).host}`);
      }
    } catch {}
    finally { checking = false; }
  }, 500);

  const started = Date.now();
  const timer = setInterval(() => {
    if (readyUrl) { clearInterval(timer); clearInterval(poll); return; }
    if (Date.now() - started > START_TIMEOUT_MS) {
      log('start timeout; killing child');
      child.kill('SIGKILL');
      clearInterval(timer);
      clearInterval(poll);
    }
  }, 1000);

  child.on('exit', (code, signal) => {
    clearInterval(timer);
    clearInterval(poll);
    clearUrl();
    setState('restarting');
    log(`child exit code=${code} signal=${signal}`);
    child = null;
    if (stopping) return;
    rapidFail += 1;
    scheduleRestart(rapidFail >= 5 ? 30_000 : 2_000);
  });

  child.on('error', (e) => {
    log(`spawn error: ${e.message}`);
    child = null;
    if (stopping) return;
    rapidFail += 1;
    scheduleRestart(rapidFail >= 5 ? 30_000 : 2_000);
  });
}

async function health() {
  if (!readyUrl) return;
  try {
    const res = await httpProbe(readyUrl, 8_000);
    if (res.status >= 200 && res.status < 400) return;
    log(`health ${res.error ? `error=${res.error.message}` : `status=${res.status}`}`);
  } catch (e) {
    log(`health error: ${e.message}`);
  }
  // 连续失败才重启，避免一次抖动杀 Host
  const fails = (health.fails = (health.fails || 0) + 1);
  if (fails >= 3) {
    health.fails = 0;
    log('health failed 3x; restarting');
    child?.kill('SIGKILL');
  }
}

process.on('SIGTERM', () => { stopping = true; child?.kill('SIGTERM'); process.exit(0); });
process.on('SIGINT', () => { stopping = true; child?.kill('SIGTERM'); process.exit(0); });

// The guest runtime has a single V8 isolate and no supervisor above us:
// one unhandled rejection would kill the whole DSH host. Log and continue.
process.on('uncaughtException', (e) => { log(`uncaught: ${e && (e.stack || e.message || e)}`); });
process.on('unhandledRejection', (e) => { log(`unhandled rejection: ${e && (e.stack || e.message || e)}`); });

start().catch((e) => { log(`initial start failed: ${e.message}`); scheduleRestart(30_000); });
setInterval(() => { health().catch((e) => log(`health threw: ${e && (e.stack || e.message)}`)); }, HEALTH_MS).unref();
