#!/usr/bin/node
const { spawnSync } = require('node:child_process');
let a = process.argv.slice(2);
const map = [];
if (a[0] === 'add') { map.push('install', ...a.slice(1)); }
else if (a[0] === 'remove') { map.push('uninstall', ...a.slice(1)); }
else if (a[0] === 'install' || a[0] === 'i') { map.push('install'); for (const x of a.slice(1)) { if (x === '--frozen-lockfile' || x === '--config.lockfile=false') continue; map.push(x); } }
else map.push(...a);
const out = [];
for (let i = 0; i < map.length; i++) {
  const x = map[i];
  if (x.startsWith('--config.registry=')) out.push('--registry=' + x.slice('--config.registry='.length));
  else if (x.startsWith('--config.')) { /* drop other pnpm config flags */ }
  else out.push(x);
}
const r = spawnSync('npm', out, { stdio: 'inherit', env: process.env });
process.exit(r.status === null ? 1 : r.status);
