// Run with: node --test   (from the functions/ folder)
// The window cases mirror test/schedule_windows_test.dart; the server must
// run schedules exactly like the app's scheduler does.
const test = require('node:test');
const assert = require('node:assert');
const {
  parseWindows, parseSchedule, clockAt, actionFor, targetsDevice, planRelayChanges,
} = require('./schedule_logic');

// Philippine wall-clock time -> epoch ms (PH is UTC+8 all year).
const ph = (y, mo, d, h, mi) => Date.UTC(y, mo - 1, d, h - 8, mi);
// A schedule's action at a PH wall-clock time. 2026-09-21 is a Monday.
const at = (schedule, d, h, mi) =>
  actionFor(schedule, clockAt(ph(2026, 9, d, h, mi), 'Asia/Manila'));
const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri'];

test('clock is the PH wall clock, including across UTC midnight', () => {
  const c = clockAt(Date.UTC(2026, 8, 20, 22, 30), 'Asia/Manila'); // Mon 06:30 PH
  assert.strictEqual(c.minute, 6 * 60 + 30);
  assert.strictEqual(c.day, Date.UTC(2026, 8, 21));
});

test('an invalid time zone falls back to Asia/Manila', () => {
  assert.deepStrictEqual(clockAt(ph(2026, 9, 21, 8, 0), 'Not/AZone'),
    clockAt(ph(2026, 9, 21, 8, 0), 'Asia/Manila'));
});

test('windows: OFF one minute after the end; overnight and 23:59 end the next day', () => {
  const [a, b, c] = parseWindows([
    { on: '08:00', until: '11:59' }, { on: '22:00', until: '05:59' }, { on: '18:00', until: '23:59' },
  ]);
  assert.deepStrictEqual([a.offMinute, a.offDayOffset, a.overnight], [12 * 60, 0, false]);
  assert.deepStrictEqual([b.offMinute, b.offDayOffset, b.overnight], [6 * 60, 1, true]);
  assert.deepStrictEqual([c.offMinute, c.offDayOffset, c.overnight], [0, 1, false]);
});

test('windows: lists and index-keyed maps parse, bad entries are skipped', () => {
  assert.strictEqual(parseWindows([{ on: '08:00', until: '09:59' }, { on: 'bad', until: '10:00' }]).length, 1);
  const fromMap = parseWindows({ 1: { on: '13:00', until: '14:00' }, 0: { on: '08:00', until: '09:00' } });
  assert.deepStrictEqual(fromMap.map((w) => w.on), [8 * 60, 13 * 60]);
  assert.deepStrictEqual(parseWindows(null), []);
});

test('windows fire ON and OFF for each window on a matching day', () => {
  const s = parseSchedule('s', {
    days: WEEKDAYS, windows: [{ on: '08:00', until: '11:59' }, { on: '13:00', until: '16:59' }],
  });
  assert.strictEqual(at(s, 21, 8, 0), 'on');
  assert.strictEqual(at(s, 21, 12, 0), 'off');
  assert.strictEqual(at(s, 21, 13, 0), 'on');
  assert.strictEqual(at(s, 21, 17, 0), 'off');
  assert.strictEqual(at(s, 21, 10, 0), null);
});

test('windows replace onTime/offTime (never fire at the stored 08:00/18:00)', () => {
  const s = parseSchedule('s', {
    days: WEEKDAYS, onTime: '08:00', offTime: '18:00', windows: [{ on: '09:00', until: '09:59' }],
  });
  assert.strictEqual(at(s, 21, 8, 0), null);
  assert.strictEqual(at(s, 21, 18, 0), null);
  assert.strictEqual(at(s, 21, 9, 0), 'on');
  assert.strictEqual(at(s, 21, 10, 0), 'off');
});

test('windows do nothing on a non-matching day', () => {
  const s = parseSchedule('s', { days: WEEKDAYS, windows: [{ on: '08:00', until: '11:59' }] });
  assert.strictEqual(at(s, 26, 8, 0), null); // Saturday
});

test('windows: ON wins when back-to-back windows meet', () => {
  const s = parseSchedule('s', {
    days: WEEKDAYS, windows: [{ on: '08:00', until: '11:59' }, { on: '12:00', until: '13:00' }],
  });
  assert.strictEqual(at(s, 21, 12, 0), 'on');
});

test('windows: an overnight OFF belongs to the day the window started', () => {
  const s = parseSchedule('s', { days: WEEKDAYS, windows: [{ on: '22:00', until: '05:59' }] });
  assert.strictEqual(at(s, 26, 6, 0), 'off'); // Friday night -> Saturday 06:00
  assert.strictEqual(at(s, 21, 6, 0), null); // Sunday night started nothing
});

test('single on/off pair, including overnight and legacy action/time', () => {
  const day = parseSchedule('s', { days: ['Mon'], onTime: '08:30', offTime: '18:00' });
  assert.strictEqual(at(day, 21, 8, 30), 'on');
  assert.strictEqual(at(day, 21, 18, 0), 'off');
  assert.strictEqual(at(day, 22, 8, 30), null); // Tuesday

  const night = parseSchedule('s', { days: ['Wed'], onTime: '17:00', offTime: '15:00' });
  assert.strictEqual(at(night, 23, 17, 0), 'on'); // Wednesday
  assert.strictEqual(at(night, 24, 15, 0), 'off'); // Thursday, started Wednesday
  assert.strictEqual(at(night, 23, 15, 0), null); // Tuesday didn't start one

  const legacy = parseSchedule('s', { days: ['Mon'], action: 'on', time: '07:15' });
  assert.strictEqual(at(legacy, 21, 7, 15), 'on');
});

test('calendar mode runs every day from startDate to endDate, inclusive, ignoring days', () => {
  const s = parseSchedule('s', {
    scheduleMode: 'calendar', startDate: '2026-09-25', endDate: '2026-09-27',
    days: ['Mon'], onTime: '08:00', offTime: '18:00',
  });
  assert.strictEqual(at(s, 24, 8, 0), null); // day before
  assert.strictEqual(at(s, 25, 8, 0), 'on'); // first day (Friday)
  assert.strictEqual(at(s, 27, 18, 0), 'off'); // last day (Sunday)
  assert.strictEqual(at(s, 28, 8, 0), null); // day after endDate (Monday)
});

test('calendar mode without both dates never fires', () => {
  const s = parseSchedule('s', { scheduleMode: 'calendar', startDate: '2026-09-25' });
  assert.strictEqual(at(s, 25, 8, 0), null);
});

test('calendar mode with windows', () => {
  const s = parseSchedule('s', {
    scheduleMode: 'calendar', startDate: '2026-09-25', endDate: '2026-09-30',
    windows: [{ on: '08:00', until: '17:59' }],
  });
  assert.strictEqual(at(s, 26, 8, 0), 'on');
  assert.strictEqual(at(s, 30, 18, 0), 'off');
  assert.strictEqual(at(s, 30, 8, 0), 'on'); // last day is inside
  assert.strictEqual(actionFor(s, clockAt(ph(2026, 10, 1, 8, 0))), null); // Oct 1 is after
});

test('scopes: global, building, utility and device', () => {
  const dev = { building: 'ic', utility: 'Aircon' };
  assert.ok(targetsDevice(parseSchedule('a', { scope: 'global', utility: 'All' }), 'D1', dev));
  assert.ok(targetsDevice(parseSchedule('a', { scope: 'global', utility: 'AC' }), 'D1', dev));
  assert.ok(!targetsDevice(parseSchedule('a', { scope: 'global', utility: 'Lights' }), 'D1', dev));
  assert.ok(targetsDevice(parseSchedule('a', { scope: 'building', target: 'IC' }), 'D1', dev));
  assert.ok(!targetsDevice(parseSchedule('a', { scope: 'building', target: 'ITED' }), 'D1', dev));
  assert.ok(targetsDevice(parseSchedule('a', { scope: 'utility', target: 'air conditioner' }), 'D1', dev));
  assert.ok(targetsDevice(parseSchedule('a', { scope: 'device', target: ' D1 ' }), 'D1', dev));
  assert.ok(!targetsDevice(parseSchedule('a', { scope: 'device', target: 'D2' }), 'D1', dev));
  assert.ok(!targetsDevice(parseSchedule('a', { scope: 'nonsense' }), 'D1', dev));
});

test('planRelayChanges: only due, enabled schedules; skips devices already there', () => {
  const automations = {
    a: { scope: 'building', target: 'IC', days: ['Mon'], onTime: '08:00', offTime: '18:00' },
    b: { scope: 'global', days: ['Mon'], onTime: '08:00', offTime: '18:00', enabled: false },
    c: { scope: 'device', target: 'ITED-1', days: ['Tue'], onTime: '08:00', offTime: '18:00' },
  };
  const devices = {
    'IC-1': { building: 'IC', floor: '1', relay: false },
    'IC-2': { building: 'IC', floor: '2', relay: true },
    'ITED-1': { building: 'ITED', floor: '1', relay: false },
  };
  const changes = planRelayChanges({ automations, devices, nowMs: ph(2026, 9, 21, 8, 0), timeZone: 'Asia/Manila' });
  assert.deepStrictEqual(changes, [{ deviceId: 'IC-1', relay: true, building: 'IC', floor: '1' }]);
  assert.deepStrictEqual(
    planRelayChanges({ automations, devices, nowMs: ph(2026, 9, 21, 9, 0), timeZone: 'Asia/Manila' }), []);
});

test('planRelayChanges: a calendar schedule past its endDate changes nothing', () => {
  const automations = {
    expired: { scope: 'global', scheduleMode: 'calendar', startDate: '2026-09-01', endDate: '2026-09-24', onTime: '08:00', offTime: '18:00' },
  };
  const devices = { 'IC-1': { building: 'IC', relay: false } };
  assert.deepStrictEqual(
    planRelayChanges({ automations, devices, nowMs: ph(2026, 10, 11, 8, 0), timeZone: 'Asia/Manila' }), []);
});
