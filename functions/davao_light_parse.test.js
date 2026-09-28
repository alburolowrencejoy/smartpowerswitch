// Run with: node --test   (from the functions/ folder)
// Fixtures are real sentences from Davao Light / Aboitiz Eyes advisories.
const test = require('node:test');
const assert = require('node:assert');
const {
  parseRateAdvisory, isOfficialUrl, parseRss, isNewsworthy,
} = require('./davao_light_parse');

const JULY_2026 =
  'The overall residential rate of Davao Light and Power Co., Inc. (Davao Light) ' +
  'for the billing period of July 11 to August 10, 2026 increased by P0.78 per ' +
  'kilowatt-hour (kWh), bringing the rate to P13.09/kWh from P12.30/kWh in the ' +
  'previous billing period. The increase was primarily driven by higher generation charges.';

const SEPT_2025 =
  "Posted on September 24, 2025 Davao Light Communications Team By Jade Chiu Davao " +
  "Light's overall residential electricity rate increased by P1.5625 per " +
  'kilowatt-hour (kWh) this September 2025, bringing the rate up to PHP10.6407/kWh ' +
  'from PHP9.0782/kWh in the previous month.';

const OTHER_UTILITY =
  "Visayan Electric's overall residential rate is P11.7187 per kilowatt-hour (kWh), " +
  'a P2.0052/kWh increase from P9.7135/kWh last December 2025.';

const FAQ_NOISE =
  'The amount is collected from consumers at a fixed rate of 0.01 Php/kWh. The ' +
  'Environmental Charge of P0.0025 per kilowatt hour shall be collected from all end users.';

const DAY = 24 * 3600 * 1000;

test('July 2026 advisory is parsed and verified during its billing period', () => {
  const r = parseRateAdvisory(JULY_2026, { now: Date.UTC(2026, 6, 20) });
  assert.ok(r);
  assert.strictEqual(r.rate, 13.09);
  assert.strictEqual(r.previousRate, 12.3);
  assert.strictEqual(r.delta, 0.78);
  assert.strictEqual(r.periodLabel, 'July 11 – August 10, 2026');
  assert.ok(r.verified, JSON.stringify(r.checks));
});

test('the same advisory is stale two months later', () => {
  const r = parseRateAdvisory(JULY_2026, { now: Date.UTC(2026, 8, 29) });
  assert.ok(r);
  assert.strictEqual(r.verified, false);
  assert.strictEqual(r.checks.find((c) => c.name === 'Current billing period').pass, false);
});

test('"this September 2025" wording with PHP prefix and 4 decimals', () => {
  const r = parseRateAdvisory(SEPT_2025, { now: Date.UTC(2025, 8, 25) });
  assert.ok(r);
  assert.strictEqual(r.rate, 10.6407);
  assert.strictEqual(r.previousRate, 9.0782);
  assert.strictEqual(r.delta, 1.5625);
  assert.ok(r.verified, JSON.stringify(r.checks));
});

test('another utility is not accepted as Davao Light', () => {
  const r = parseRateAdvisory(OTHER_UTILITY, {
    now: Date.UTC(2026, 0, 17), publishedAt: Date.UTC(2026, 0, 16),
  });
  assert.ok(r);
  assert.strictEqual(r.verified, false);
  assert.strictEqual(r.checks.find((c) => c.name === 'Names Davao Light').pass, false);
});

test('fixed charges on the FAQ page are not read as a rate', () => {
  assert.strictEqual(parseRateAdvisory(FAQ_NOISE), null);
});

test('numbers that do not add up fail verification', () => {
  const bad = JULY_2026.replace('P0.78', 'P0.50');
  const r = parseRateAdvisory(bad, { now: Date.UTC(2026, 6, 20) });
  assert.strictEqual(r.verified, false);
  assert.strictEqual(r.checks.find((c) => c.name === 'Numbers add up').pass, false);
});

test('a decrease is read as negative', () => {
  const text = JULY_2026.replace('increased by P0.78', 'decreased by P0.19')
    .replace('P13.09/kWh from P12.30/kWh', 'P12.90/kWh from P13.09/kWh');
  const r = parseRateAdvisory(text, { now: Date.UTC(2026, 6, 20) });
  assert.strictEqual(r.delta, -0.19);
  assert.ok(r.verified, JSON.stringify(r.checks));
});

test('"is at P12.30 per kilowatt-hour" with no delta uses what it can', () => {
  const text = 'The overall residential rate of Davao Light this June 2026 is at P12.30 per kilowatt-hour.';
  const r = parseRateAdvisory(text, { now: Date.UTC(2026, 5, 15) });
  assert.strictEqual(r.rate, 12.3);
  assert.strictEqual(r.checks.some((c) => c.name === 'Numbers add up'), false);
  assert.ok(r.verified, JSON.stringify(r.checks));
});

const MINDANAO_TIMES_AUG =
  'DAVAO Light and Power Co. (Davao Light) has cut its overall residential ' +
  'electricity rate for August by P0.19 per kilowatt-hour. This brings the new ' +
  'rate to P12.90 per kilowatt-hour (kWh), down by P0.19 per kWh from last ' +
  "month’s rate of P13.09 per kWh. Davao Light said the rate applies to the " +
  'billing period of Aug. 11 to Sept. 10, 2026. It said the movement in the ' +
  'overall rate reflects changes in the different components of the bill.';

test('news wording: "has cut … brings the new rate to", short month names', () => {
  const r = parseRateAdvisory(MINDANAO_TIMES_AUG, {
    now: Date.UTC(2026, 8, 5), publishedAt: Date.UTC(2026, 8, 4),
  });
  assert.ok(r);
  assert.strictEqual(r.rate, 12.9);
  assert.strictEqual(r.previousRate, 13.09);
  assert.strictEqual(r.delta, -0.19);
  assert.strictEqual(r.periodLabel, 'August 11 – September 10, 2026');
  assert.ok(r.verified, JSON.stringify(r.checks));
});

test('month-only period takes its year from the post date', () => {
  const text = 'The overall residential rate of Davao Light for August increased ' +
    'by P0.20 per kWh, bringing the rate to P13.10/kWh from P12.90/kWh.';
  const r = parseRateAdvisory(text, {
    now: Date.UTC(2026, 7, 20), publishedAt: Date.UTC(2026, 7, 15),
  });
  assert.strictEqual(r.periodLabel, 'August 2026 billing');
  assert.ok(r.verified, JSON.stringify(r.checks));
});

// Davao Light's Facebook advisory for Sept-Oct 2026 (as quoted by Google).
const FACEBOOK_SEPT_2026 =
  'DAVAO LIGHT RATE RISES TO ₱13.24/KWH FOR SEPT. -OCT. BILLING Davao Light\'s ' +
  'residential electricity rate increased to ₱13.24 per kilowatt-hour (kWh) for the ' +
  'September 11 to October 10, 2026 billing period, representing an increase of ' +
  '₱0.34/kWh from the previous month\'s rate of ₱12.90/kWh.';

test('Facebook wording: "residential electricity rate", "for the … billing period"', () => {
  const r = parseRateAdvisory(FACEBOOK_SEPT_2026, { now: Date.UTC(2026, 8, 29) });
  assert.ok(r);
  assert.strictEqual(r.rate, 13.24);
  assert.strictEqual(r.previousRate, 12.9);
  assert.strictEqual(r.delta, 0.34);
  assert.strictEqual(r.periodLabel, 'September 11 – October 10, 2026');
  assert.ok(r.verified, JSON.stringify(r.checks));
});

const DAVAOLIGHT_JUNE_2026 =
  'An increase in the generation charge has caused an uptick in the overall ' +
  'residential rate of Davao Light and Power Co., Inc. (Davao Light) for the billing ' +
  'period of June 11 to July 10, 2026. This adjustment is the result of tight power ' +
  'supply conditions. The P1.95-per-kilowatt-hour (kWh) adjustment brought the rate ' +
  'up to P12.30/kWh from P10.35/kWh in the previous billing period.';

test('website wording: "P1.95-per-kilowatt-hour (kWh) adjustment brought the rate up to"', () => {
  const r = parseRateAdvisory(DAVAOLIGHT_JUNE_2026, { now: Date.UTC(2026, 5, 20) });
  assert.ok(r);
  assert.strictEqual(r.rate, 12.3);
  assert.strictEqual(r.previousRate, 10.35);
  assert.strictEqual(r.delta, 1.95);
  assert.strictEqual(r.periodLabel, 'June 11 – July 10, 2026');
  assert.ok(r.verified, JSON.stringify(r.checks));
});

test('post date comes from page metadata, not body dates', () => {
  const { extractPostDate } = require('./davao_light_parse');
  const html = '<meta property="article:published_time" content="2026-06-19T02:24:14.422Z"/>' +
    '<p>for the billing period of June 11 to July 10, 2026</p>';
  assert.strictEqual(new Date(extractPostDate(html)).toISOString().slice(0, 10), '2026-06-19');
  assert.strictEqual(extractPostDate('<p>July 10, 2026</p>'), 0);
});

test('only official https hosts are trusted', () => {
  assert.ok(isOfficialUrl('https://www.davaolight.com/post/x'));
  assert.ok(isOfficialUrl('https://aboitizeyes.aboitiz.com/power/x/'));
  assert.ok(!isOfficialUrl('http://www.davaolight.com/post/x'));
  assert.ok(!isOfficialUrl('https://www.sunstar.com.ph/davao/x'));
  assert.ok(!isOfficialUrl('https://davaolight.com.evil.example/x'));
});

test('RSS parsing and bid filtering', () => {
  const xml = '<rss><channel><item><title><![CDATA[INVITATION TO BID: Poles]]></title>' +
    '<link>https://www.davaolight.com/post/a</link><pubDate>Mon, 28 Sep 2026 09:59:28 GMT</pubDate></item>' +
    '<item><title><![CDATA[Scheduled power interruption on September 30]]></title>' +
    '<link>https://www.davaolight.com/post/b</link><pubDate>Mon, 28 Sep 2026 07:23:14 GMT</pubDate>' +
    '<description><![CDATA[<p>Davao Light will conduct&#8230;</p>]]></description></item></channel></rss>';
  const items = parseRss(xml);
  assert.strictEqual(items.length, 2);
  assert.strictEqual(items[1].link, 'https://www.davaolight.com/post/b');
  assert.ok(items[1].pubDate > 0);
  assert.deepStrictEqual(items.map(isNewsworthy), [false, true]);
  assert.ok(Date.UTC(2026, 8, 28) - items[0].pubDate < DAY);
});
