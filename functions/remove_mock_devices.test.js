// Run with: node --test   (from the functions/ folder)
const test = require('node:test');
const assert = require('node:assert');
const { planCleanup } = require('./remove_mock_devices');

test('removes DVC-* mocks from the registry, devices-only entries and floor copies', () => {
  const plan = planCleanup({
    master: {
      'ESP32-A': { source: 'real_iot' },
      'DVC-IC-001': { assignedTo: 'IC/1/Room 101' },
    },
    devices: { 'ESP32-A': {}, 'DVC-IC-001': {}, 'DVC-ITED-026': {} },
    buildings: { IC: { floorData: [null, { devices: { 'DVC-IC-001': {}, 'ESP32-A': {} } }] } },
  });
  assert.deepStrictEqual(plan.real, ['ESP32-A']);
  assert.deepStrictEqual(plan.mocks, ['DVC-IC-001', 'DVC-ITED-026']);
  assert.deepStrictEqual(plan.updates, {
    'master_devices/DVC-IC-001': null,
    'devices/DVC-IC-001': null,
    'devices/DVC-ITED-026': null,
    'buildings/IC/floorData/1/devices/DVC-IC-001': null,
  });
});

test('never deletes a registered non-mock device without real_iot: reports it', () => {
  const plan = planCleanup({
    master: { 'BOARD-7': { source: 'manual' }, 'ESP32-A': { source: 'real_iot' } },
    devices: { 'STRAY-1': {} },
  });
  assert.deepStrictEqual(plan.unknown, ['BOARD-7']);
  assert.deepStrictEqual(plan.orphans, ['STRAY-1']);
  assert.deepStrictEqual(plan.updates, {});
});

test('empty database: nothing to do', () => {
  assert.deepStrictEqual(planCleanup({}).updates, {});
});
