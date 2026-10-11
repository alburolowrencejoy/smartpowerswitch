// Source of database.rules.json (master plan Phase 7). Edit THIS file, then
// run `node rules/build_database_rules.js` and the rules tests
// (`npm run test:rules` in functions/). Each check is defined once with a
// name instead of being copy-pasted into every path.
//
// Roles (users/{uid}/role): faculty (member, read-only), institute_admin
// (manages ONLY their own institute = users/{uid}/institute, a building
// code), and the main-admin tiers admin / main_admin / super_admin (+ the
// legacy isMainAdmin flag and admin@dnsc.edu.ph), which manage everything.
// Boards are unauthenticated (until per-board identity exists) and may only
// touch their own registered record.
'use strict';

const fs = require('fs');
const path = require('path');

const me = "root.child('users').child(auth.uid)";
const role = `${me}.child('role').val()`;
const inst = `${me}.child('institute').val()`;

const signedIn = 'auth != null';
const isMainAdmin = `(${role} === 'admin' || ${role} === 'main_admin' || ${role} === 'super_admin' || ` +
  `${me}.child('isMainAdmin').val() === true || auth.token.email === 'admin@dnsc.edu.ph')`;
const isInstAdmin = `${role} === 'institute_admin'`;
const isAdmin = `(${isMainAdmin} || ${isInstAdmin})`;
const isMember = `(${isAdmin} || ${role} === 'faculty')`;

const and = (...xs) => xs.map((x) => `(${x})`).join(' && ');
const or = (...xs) => xs.map((x) => `(${x})`).join(' || ');

const members = and(signedIn, isMember);
const admins = and(signedIn, isAdmin);
const mainAdmins = and(signedIn, isMainAdmin);
const instAdmin = and(signedIn, isInstAdmin);

// A registry assignment "IC/1/Room 101" inside the caller's institute.
// Takes a snapshot expression; checks it is a string first, because calling
// beginsWith on a missing value is a rules ERROR, which denies the whole
// write even when another branch would allow it.
const inMyInst = (snap) => `(${snap}.isString() && ${snap}.val().beginsWith(${inst} + '/'))`;
const masterAssigned = (idExpr, tree = 'root') =>
  `${tree}.child('master_devices').child(${idExpr}).child('assignedTo')`;
// Before or after this write, the device is in the caller's institute.
const deviceInMyInst = (idExpr) => or(
  inMyInst(masterAssigned(idExpr)),
  inMyInst(masterAssigned(idExpr, 'newData.parent().parent()')),
);
const registered = "root.child('master_devices').child($deviceId).exists()";
const board = and('auth == null', registered);

const num = (min, max) => `newData.isNumber() && newData.val() >= ${min} && newData.val() <= ${max}`;
const numOrNull = (min, max) => `!newData.exists() || (${num(min, max)})`;
const strOrNull = (maxLen) => `!newData.exists() || (newData.isString() && newData.val().length <= ${maxLen})`;
const boolOnly = 'newData.isBoolean()';
const hhmm = "newData.isString() && newData.val().matches(/^([01][0-9]|2[0-3]):[0-5][0-9]$/)";
const isoDate = "newData.isString() && newData.val().matches(/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/)";
const str = (maxLen) => `newData.isString() && newData.val().length <= ${maxLen}`;
const oneOf = (...vals) => vals.map((v) => `newData.val() === '${v}'`).join(' || ');

// Energy history lists: only bounded, key-ordered queries (newest N, or a
// date range); one period at a time is always readable. Stops a client from
// downloading the whole, ever-growing tree (screens use these bounds).
const MAX_KEYS = 1100;
const boundedQuery = or(
  `query.limitToLast != null && query.limitToLast <= ${MAX_KEYS}`,
  `query.limitToFirst != null && query.limitToFirst <= ${MAX_KEYS}`,
  'query.startAt != null && query.endAt != null',
);
const ms = numOrNull(0, 9999999999999);

// Firmware readings (PZEM-004T 100 A; ranges the firmware itself accepts).
const telemetryFields = {
  voltage: numOrNull(0, 300),
  current: numOrNull(0, 100),
  power: numOrNull(0, 26000),
  powerFactor: numOrNull(0, 1),
  frequency: numOrNull(0, 70),
};

// A schedule (automations/{id}) is inside the caller's institute when it
// targets their building, or one device assigned to their institute.
const scheduleInMyInst = (x) => or(
  `!${x}.exists()`,
  and(`${x}.child('scope').val() === 'building'`, `${x}.child('target').val() === ${inst}`),
  and(`${x}.child('scope').val() === 'device'`,
    and(`${x}.child('target').isString()`,
      inMyInst(`root.child('master_devices').child(${x}.child('target').val()).child('assignedTo')`))),
);

const rules = {
  rules: {
    '.read': false,
    '.write': false,

    users: {
      '.read': admins,
      $uid: {
        '.read': or(admins, and(signedIn, 'auth.uid === $uid')),
        '.write': or(
          mainAdmins,
          // Institute admins manage other users of their own institute, as
          // faculty or institute_admin only (never a main-admin tier).
          and(instAdmin, 'auth.uid !== $uid',
            `!data.exists() || data.child('institute').val() === ${inst}`,
            or('!newData.exists()', and(
              `newData.child('institute').val() === ${inst}`,
              "newData.child('role').val() === 'faculty' || newData.child('role').val() === 'institute_admin'",
              "newData.child('isMainAdmin').val() !== true"))),
          // Sign-up: a @dnsc.edu.ph account creates its own faculty record,
          // without any admin flag.
          and(signedIn, 'auth.uid === $uid', '!data.exists()',
            "auth.token.email.endsWith('@dnsc.edu.ph')",
            "newData.child('role').val() === 'faculty'",
            "!newData.child('isMainAdmin').exists()", "!newData.child('coAdmin').exists()"),
          // Own profile edits: role, admin flags and institute can't change.
          and(signedIn, 'auth.uid === $uid', 'data.exists()', 'newData.exists()',
            "newData.child('role').val() === data.child('role').val()",
            "newData.child('isMainAdmin').val() === data.child('isMainAdmin').val()",
            "newData.child('institute').val() === data.child('institute').val()",
            "newData.child('coAdmin').val() === data.child('coAdmin').val()"),
        ),
      },
    },

    settings: {
      '.read': members,
      // Campus-wide settings (rate, rate proposal, time zone, app mode):
      // main admins only.
      '.write': mainAdmins,
      electricityRate: { '.validate': 'newData.isNumber() && newData.val() > 0 && newData.val() < 100' },
      // Written by the app itself for any admin: the app-update notification
      // lock and the app mode reset (RuntimeModeService only sets 'normal').
      updateNotifications: { '.write': admins },
      appMode: { '.write': admins },
    },

    buildings: {
      '.read': members,
      $code: {
        '.write': or(mainAdmins, and(instAdmin, `$code === ${inst}`)),
        name: { '.validate': str(80) },
        floors: { '.validate': 'newData.isNumber() && newData.val() >= 1 && newData.val() <= 50' },
        floorData: { $floor: { rooms: { $i: { '.validate': str(60) } } } },
      },
    },

    hotspots: {
      '.read': members,
      $code: { '.write': or(mainAdmins, and(instAdmin, `$code === ${inst}`)) },
    },

    // Registry: which devices exist and where they are.
    master_devices: {
      '.read': members,
      $deviceId: {
        '.write': or(
          mainAdmins,
          // Institute admins register / assign / unassign devices only
          // between "unassigned" and their own institute.
          and(instAdmin,
            or(`!data.exists()`, `data.child('assignedTo').val() === ''`, inMyInst("data.child('assignedTo')")),
            or('!newData.exists()', `newData.child('assignedTo').val() === ''`, inMyInst("newData.child('assignedTo')"))),
        ),
        assignedTo: { '.validate': 'newData.isString() && newData.val().length <= 120' },
        source: { '.validate': "newData.val() === 'real_iot'" },
        writeKey: { '.read': false },
      },
    },

    // Old-firmware record (live readings + the transition copy of the
    // assignment). Firmware 2.0+ uses device_live / device_commands instead.
    devices: {
      '.read': members,
      $deviceId: {
        '.read': or(members, board),
        '.write': or(
          mainAdmins,
          // Institute admins: their institute's devices, and unassigned ones
          // (registering a device writes its transition copy here).
          and(instAdmin, or(deviceInMyInst('$deviceId'),
            `${masterAssigned('$deviceId', 'newData.parent().parent()')}.val() === ''`)),
          // Old firmware: may update its own readings, never its assignment.
          and(board,
            "newData.child('building').val() == data.child('building').val()",
            "newData.child('floor').val() == data.child('floor').val()",
            "newData.child('room').val() == data.child('room').val()",
            "newData.child('utility').val() == data.child('utility').val()"),
        ),
        kwh: { '.validate': numOrNull(0, 1000000) },
        ...Object.fromEntries(Object.entries(telemetryFields).map(([k, v]) => [k, { '.validate': v }])),
        relay: { '.validate': boolOnly },
        last_seen: { '.validate': ms },
        last_updated: { '.validate': ms },
        status: { '.validate': strOrNull(20) },
        wifi_ssid: { '.validate': strOrNull(64) },
        wifi_rssi: { '.validate': numOrNull(-200, 0) },
        voltage_warning: { '.validate': strOrNull(40) },
      },
    },

    // Firmware 2.0+: what the board reports. Written only by the board.
    device_live: {
      '.read': members,
      $deviceId: {
        '.read': or(members, board),
        '.write': board,
        telemetry: {
          cumulativeKwh: { '.validate': numOrNull(0, 1000000) },
          ...Object.fromEntries(Object.entries(telemetryFields).map(([k, v]) => [k, { '.validate': v }])),
          voltageWarning: { '.validate': strOrNull(40) },
          $other: { '.validate': false },
        },
        connectivity: {
          status: { '.validate': strOrNull(20) },
          lastSeenAt: { '.validate': ms },
          lastUpdatedAt: { '.validate': ms },
          wifiSsid: { '.validate': strOrNull(64) },
          wifiRssi: { '.validate': numOrNull(-200, 0) },
          $other: { '.validate': false },
        },
        state: {
          reportedRelay: { '.validate': boolOnly },
          lastCommandId: { '.validate': strOrNull(64) },
          lastCommandAt: { '.validate': ms },
          $other: { '.validate': false },
        },
        $other: { '.validate': false },
      },
    },

    // What the app / schedulers ask a board to do.
    device_commands: {
      '.read': members,
      $deviceId: {
        '.read': or(members, board),
        '.write': or(mainAdmins, and(instAdmin, deviceInMyInst('$deviceId'))),
        desiredRelay: { '.validate': boolOnly },
        commandId: { '.validate': 'newData.isString() && newData.val().length <= 64' },
        issuedAt: { '.validate': ms },
        issuedBy: { '.validate': strOrNull(128) },
        // The board clears its own wifiReset after acting on it.
        wifiReset: { '.write': and(board, '!newData.exists()'), '.validate': boolOnly },
        $other: { '.validate': false },
      },
    },

    // Energy history: written only by the server (rollupEnergy, the
    // forecast script). history/ only holds history/predictions now.
    history: { '.read': members, '.write': false },
    energy_summaries: {
      '.write': false,
      $range: {
        '.read': and(members, 'query.orderByKey', boundedQuery),
        $key: { '.read': members },
      },
    },

    notifications: {
      '.read': members,
      // "Clear all" of the whole list: main admins only.
      '.write': mainAdmins,
      '.indexOn': ['timestamp'],
      $id: {
        '.write': or(
          // Any admin's app may post the app-update notice.
          and(admins, '!data.exists()', "newData.child('type').val() === 'app_update'"),
          // Institute admins clear only their own institute's notifications
          // (no building = campus-wide, main admins only).
          and(instAdmin, '!newData.exists()', `data.child('building').val() === ${inst}`),
        ),
      },
    },

    rate_changes: {
      '.read': members,
      '.write': mainAdmins,
      '.indexOn': ['timestamp'],
    },

    // Audit log: append-only.
    deletion_log: {
      '.read': admins,
      '.indexOn': ['timestamp'],
      $id: { '.write': and(admins, '!data.exists()') },
    },

    automations: {
      '.read': members,
      $id: {
        '.write': or(
          mainAdmins,
          // Institute admins: only schedules for their own building or for
          // one of their own devices (before and after the change).
          and(instAdmin, scheduleInMyInst('data'), scheduleInMyInst('newData')),
        ),
        name: { '.validate': str(80) },
        scope: { '.validate': oneOf('global', 'building', 'utility', 'device') },
        target: { '.validate': str(64) },
        utility: { '.validate': str(40) },
        onTime: { '.validate': hhmm },
        offTime: { '.validate': hhmm },
        time: { '.validate': hhmm },
        action: { '.validate': oneOf('on', 'off') },
        enabled: { '.validate': boolOnly },
        scheduleMode: { '.validate': oneOf('weekly', 'calendar') },
        startDate: { '.validate': isoDate },
        endDate: { '.validate': isoDate },
        days: { $i: { '.validate': oneOf('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun') } },
        windows: {
          $i: {
            on: { '.validate': hhmm },
            until: { '.validate': hhmm },
            $other: { '.validate': false },
          },
        },
        $other: { '.validate': false },
      },
    },

    davao_light: { '.read': admins, '.write': false },

    meta: { '.read': admins, '.write': mainAdmins },

    // meterState, anomalies, rollup, system_health: server only (no client
    // access, inherited from the root).
  },
};

const out = path.join(__dirname, '..', 'database.rules.json');
fs.writeFileSync(out, JSON.stringify(rules, null, 2) + '\n');
console.log(`wrote ${out}`);
