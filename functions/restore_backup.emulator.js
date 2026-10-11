// Restore drill (master plan Phase 0): proves a backup in ../backups/ can be
// restored with the runbook's command, against the database EMULATOR only.
//   npm run test:restore            (uses the newest rtdb-full-*.json)
//   BACKUP=../backups/<file> npm run test:restore
// Live restores use the runbook command `firebase database:set / <backup.json>`,
// which sends the whole file as one PUT to /.json. The CLI can't target the
// emulator with a demo project (it insists on looking the instance up in
// Google's API, which 403s), so the drill sends that same PUT directly.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const admin = require('firebase-admin');

const host = process.env.FIREBASE_DATABASE_EMULATOR_HOST;
if (!host) throw new Error('Run via `npm run test:restore` (needs the database emulator).');

const PROJECT = 'demo-smartswitch';
const backupsDir = path.join(__dirname, '..', 'backups');
const backupFile = process.env.BACKUP
  ? path.resolve(process.env.BACKUP)
  : path.join(backupsDir, fs.readdirSync(backupsDir)
    .filter((f) => /^rtdb-full-.*\.json$/.test(f)).sort().pop());

admin.initializeApp({ projectId: PROJECT, databaseURL: `http://${host}?ns=${PROJECT}` });
const db = admin.database();

/** Number of leaf values under [v]. */
const leaves = (v) => (v !== null && typeof v === 'object'
  ? Object.values(v).reduce((n, c) => n + leaves(c), 0) : 1);

test.after(async () => {
  await db.ref().set(null);
  await admin.app().delete();
});

test(`restore ${path.basename(backupFile)} with database:set reproduces it exactly`, async () => {
  const backup = JSON.parse(fs.readFileSync(backupFile, 'utf8').replace(/^﻿/, ''));
  await db.ref().set(null);

  // The restore: the whole file as one PUT to /.json (what database:set does).
  const res = await fetch(`http://${host}/.json?ns=${PROJECT}`, {
    method: 'PUT',
    headers: { Authorization: 'Bearer owner', 'Content-Type': 'application/json' },
    body: fs.readFileSync(backupFile, 'utf8').replace(/^﻿/, ''),
  });
  assert.strictEqual(res.status, 200, await res.text());

  // Compare as JSON: the database returns 1-based lists (floorData) with an
  // empty slot 0, which the backup file writes as null -- same data.
  const restored = JSON.parse(JSON.stringify((await db.ref().get()).val()));
  for (const node of Object.keys(backup)) {
    assert.deepStrictEqual(restored[node], backup[node], `node "${node}" differs after restore`);
  }
  assert.deepStrictEqual(Object.keys(restored).sort(), Object.keys(backup).sort());
  console.log(`restored ${Object.keys(backup).length} top-level nodes, ${leaves(backup)} values: identical`);
});
