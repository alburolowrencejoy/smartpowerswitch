// Security rules tests (master plan Phase 7) against the Realtime Database
// EMULATOR. Run from functions/ with: npm run test:rules
// Rebuild the rules first if you changed rules/build_database_rules.js:
//   node ../rules/build_database_rules.js
const test = require('node:test');
const fs = require('fs');
const path = require('path');
const {
  initializeTestEnvironment, assertSucceeds, assertFails,
} = require('@firebase/rules-unit-testing');

const [host, port] = (process.env.FIREBASE_DATABASE_EMULATOR_HOST || '127.0.0.1:9000').split(':');
let env;

const USERS = {
  main: { role: 'main_admin', email: 'boss@dnsc.edu.ph', name: 'Main' },
  ic: { role: 'institute_admin', institute: 'IC', email: 'ic@dnsc.edu.ph', name: 'IC admin' },
  fac: { role: 'faculty', institute: 'IC', email: 'fac@dnsc.edu.ph', name: 'Faculty' },
  ited: { role: 'faculty', institute: 'ITED', email: 'ited@dnsc.edu.ph', name: 'ITED' },
};

const as = (uid) => env.authenticatedContext(uid, { email: USERS[uid]?.email ?? `${uid}@dnsc.edu.ph` }).database();
const anon = () => env.unauthenticatedContext().database();

test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-smartswitch',
    database: {
      host, port: Number(port),
      rules: fs.readFileSync(path.join(__dirname, '..', 'database.rules.json'), 'utf8'),
    },
  });
});

test.beforeEach(async () => {
  await env.clearDatabase();
  await env.withSecurityRulesDisabled(async (ctx) => {
    await ctx.database().ref().set({
      users: USERS,
      settings: { electricityRate: 13.24 },
      buildings: { IC: { name: 'IC', floors: 2 }, ITED: { name: 'ITED', floors: 2 } },
      master_devices: {
        'IC-1': { source: 'real_iot', assignedTo: 'IC/1/Room 101' },
        'ITED-1': { source: 'real_iot', assignedTo: 'ITED/1/Lab' },
        'FREE-1': { source: 'real_iot', assignedTo: '' },
      },
      devices: { 'IC-1': { building: 'IC', floor: '1', room: 'Room 101', utility: 'Lights', kwh: 1 } },
      device_commands: { 'IC-1': { desiredRelay: false, commandId: 'c0', wifiReset: true } },
      automations: { a1: { scope: 'building', target: 'IC', onTime: '08:00', offTime: '18:00' } },
      energy_summaries: { daily: { '2026-10-11': { campus: { kwh: 1 } } } },
      deletion_log: { d1: { type: 'device', timestamp: 1 } },
    });
  });
});

test.after(async () => { await env.cleanup(); });

const cmd = (on) => ({ desiredRelay: on, commandId: `c-${on}`, issuedAt: 1791700000000, issuedBy: 'x' });

// ── Users and sign-up ────────────────────────────────────────────────────

test('sign-up: a @dnsc.edu.ph account may create its own faculty record', async () => {
  const db = env.authenticatedContext('new1', { email: 'new1@dnsc.edu.ph' }).database();
  await assertSucceeds(db.ref('users/new1').set({ role: 'faculty', email: 'new1@dnsc.edu.ph', name: 'N' }));
});

test('sign-up: other email domains are refused', async () => {
  const db = env.authenticatedContext('x1', { email: 'x1@gmail.com' }).database();
  await assertFails(db.ref('users/x1').set({ role: 'faculty', email: 'x1@gmail.com' }));
});

test('sign-up: cannot grant itself isMainAdmin or an admin role', async () => {
  const db = env.authenticatedContext('x2', { email: 'x2@dnsc.edu.ph' }).database();
  await assertFails(db.ref('users/x2').set({ role: 'faculty', isMainAdmin: true }));
  await assertFails(db.ref('users/x2').set({ role: 'main_admin' }));
});

test('an institute admin cannot raise their own role (escalation fixed)', async () => {
  await assertFails(as('ic').ref('users/ic/role').set('main_admin'));
  await assertFails(as('ic').ref('users/ic/isMainAdmin').set(true));
  await assertSucceeds(as('ic').ref('users/ic/name').set('Renamed'));
});

test('an institute admin manages only their own institute\'s users, never as main admin', async () => {
  await assertSucceeds(as('ic').ref('users/fac/name').set('OK'));
  await assertFails(as('ic').ref('users/ited/name').set('No'));
  await assertFails(as('ic').ref('users/fac/role').set('main_admin'));
  await assertFails(as('ic').ref('users/fac/institute').set('ITED'));
});

test('faculty can edit their own profile but not their role or institute', async () => {
  await assertSucceeds(as('fac').ref('users/fac/name').set('Me'));
  await assertFails(as('fac').ref('users/fac/role').set('institute_admin'));
  await assertFails(as('fac').ref('users/fac/institute').set('ITED'));
});

// ── Institute scoping ────────────────────────────────────────────────────

test('commands: institute admin only for devices in their institute; faculty never', async () => {
  await assertSucceeds(as('ic').ref('device_commands/IC-1').update(cmd(true)));
  await assertFails(as('ic').ref('device_commands/ITED-1').update(cmd(true)));
  await assertFails(as('fac').ref('device_commands/IC-1').update(cmd(true)));
  await assertSucceeds(as('main').ref('device_commands/ITED-1').update(cmd(true)));
});

test('commands: unknown fields are refused', async () => {
  await assertFails(as('main').ref('device_commands/IC-1/extra').set(1));
});

test('registry: institute admin assigns only between unassigned and their institute', async () => {
  // Assign a free device to an IC room (registry + transition copy, atomically).
  await assertSucceeds(as('ic').ref().update({
    'master_devices/FREE-1/assignedTo': 'IC/2/Room 201',
    'devices/FREE-1/building': 'IC',
    'devices/FREE-1/room': 'Room 201',
  }));
  await assertFails(as('ic').ref('master_devices/ITED-1/assignedTo').set('IC/1/Room 101'));
  await assertFails(as('ic').ref('master_devices/IC-1/assignedTo').set('ITED/1/Lab'));
  await assertSucceeds(as('ic').ref('master_devices/IC-1/assignedTo').set(''));
});

test('registering a new device works for an institute admin (Settings flow)', async () => {
  await assertSucceeds(as('ic').ref().update({
    'master_devices/NEW-1': { assignedTo: '', utility: 'Unassigned', source: 'real_iot', createdAt: 1 },
    'devices/NEW-1/building': '',
    'devices/NEW-1/floor': '',
    'devices/NEW-1/room': '',
    'devices/NEW-1/utility': 'Unassigned',
  }));
  await assertFails(as('fac').ref('master_devices/NEW-2').set({ assignedTo: '', source: 'real_iot' }));
});

test('buildings and map zones: institute admin only their own', async () => {
  await assertSucceeds(as('ic').ref('buildings/IC/floors').set(3));
  await assertFails(as('ic').ref('buildings/ITED/floors').set(3));
  await assertSucceeds(as('ic').ref('hotspots/IC/x').set(0.5));
  await assertFails(as('ic').ref('hotspots/ITED/x').set(0.5));
});

test('schedules: institute admin only for their building or their devices', async () => {
  await assertSucceeds(as('ic').ref('automations/a2').set({ scope: 'building', target: 'IC' }));
  await assertSucceeds(as('ic').ref('automations/a3').set({ scope: 'device', target: 'IC-1' }));
  await assertFails(as('ic').ref('automations/a4').set({ scope: 'building', target: 'ITED' }));
  await assertFails(as('ic').ref('automations/a5').set({ scope: 'global', target: 'all' }));
  await assertSucceeds(as('ic').ref('automations/a1/enabled').set(false));
  await assertSucceeds(as('main').ref('automations/a6').set({ scope: 'global', target: 'all' }));
});

test('campus settings: main admins only; the rate must be sane', async () => {
  await assertFails(as('ic').ref('settings/electricityRate').set(14));
  await assertFails(as('ic').ref('settings/timezone').set('UTC'));
  await assertSucceeds(as('main').ref('settings/electricityRate').set(14));
  await assertFails(as('main').ref('settings/electricityRate').set(500));
  await assertSucceeds(as('ic').ref('settings/appMode').set('normal'));
});

// ── Boards (unauthenticated, registered ID only) ────────────────────────

const v2Push = {
  telemetry: { voltage: 229.8, current: 0.25, power: 55.1, cumulativeKwh: 12.3456, powerFactor: 0.96, frequency: 60, voltageWarning: '' },
  connectivity: { status: 'online', lastUpdatedAt: 1791700000000, lastSeenAt: 1791700000000, wifiSsid: 'DNSC', wifiRssi: -61 },
  state: { reportedRelay: true, lastCommandId: 'c1', lastCommandAt: 1791700000000 },
};

test('firmware 2.0 push (real payload shape) is accepted for a registered board', async () => {
  await assertSucceeds(anon().ref('device_live/IC-1').update(v2Push));
  // PZEM missing: the board omits the readings.
  await assertSucceeds(anon().ref('device_live/IC-1').update({
    telemetry: { voltageWarning: '' },
    connectivity: { ...v2Push.connectivity, status: 'offline' },
    state: { reportedRelay: false },
  }));
});

test('board writes are validated and limited to its own record', async () => {
  await assertFails(anon().ref('device_live/NOT-REGISTERED').update(v2Push));
  await assertFails(anon().ref('device_live/IC-1/telemetry/cumulativeKwh').set(-1));
  await assertFails(anon().ref('device_live/IC-1/telemetry/power').set(99999));
  await assertFails(anon().ref('device_live/IC-1/extra').set(1));
  await assertFails(as('main').ref('device_live/IC-1/state/reportedRelay').set(true)); // only the board
});

test('board reads its commands and may only clear its wifiReset', async () => {
  await assertSucceeds(anon().ref('device_commands/IC-1').get());
  await assertSucceeds(anon().ref('device_commands/IC-1/wifiReset').remove());
  await assertFails(anon().ref('device_commands/IC-1/desiredRelay').set(true));
  await assertFails(anon().ref('device_commands/NOT-REGISTERED').get());
});

test('old firmware push (real payload shape) still works, assignment can\'t change', async () => {
  await assertSucceeds(anon().ref('devices/IC-1').update({
    status: 'online', relay: false, wifi_ssid: 'DNSC', wifi_rssi: -60, voltage_warning: '',
    last_updated: 1791700000000, last_seen: 1791700000000,
    voltage: 230.1, current: 0.2, power: 46, kwh: 1.25, powerFactor: 0.9, frequency: 60,
  }));
  await assertFails(anon().ref('devices/IC-1/building').set('ITED'));
  await assertFails(anon().ref('devices/IC-1/kwh').set(-5));
});

// ── Server-only data ─────────────────────────────────────────────────────

test('nobody but the server writes history, summaries, meter state or alerts', async () => {
  for (const db of [as('main'), as('ic'), anon()]) {
    await assertFails(db.ref('energy_summaries/daily/2026-10-11/campus/kwh').set(99));
    await assertFails(db.ref('history/predictions/daily').set({}));
    await assertFails(db.ref('meterState/IC-1/lastAcceptedKwh').set(0));
    await assertFails(db.ref('anomalies/x').set({}));
    await assertFails(db.ref('rollup/lock').set({}));
  }
  await assertSucceeds(as('fac').ref('energy_summaries/daily').get());
  await assertFails(as('fac').ref('meterState').get());
});

test('deletion log is append-only', async () => {
  await assertSucceeds(as('ic').ref('deletion_log/d2').set({ type: 'room', timestamp: 2 }));
  await assertFails(as('main').ref('deletion_log/d1').remove());
  await assertFails(as('main').ref('deletion_log/d1/type').set('edited'));
});
