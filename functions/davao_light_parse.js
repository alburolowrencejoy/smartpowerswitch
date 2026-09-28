/**
 * Pure helpers for the Davao Light watcher (no network, no Firebase), so
 * the parsing and the "is this legit?" checks can be unit-tested against
 * real advisory text. See davao_light_watch.js for how they're used.
 */

/** Davao Light's own newsroom and its parent company's (Aboitiz Eyes). */
const OFFICIAL_HOSTS = ['www.davaolight.com', 'davaolight.com', 'aboitizeyes.aboitiz.com'];

/**
 * Established Davao news outlets that report Davao Light's monthly rate
 * advisories (Davao Light itself announces them on Facebook, which can't
 * be read without a login). A figure from one of these is labelled as
 * news; two of them agreeing makes it "confirmed".
 */
const NEWS_HOSTS = [
  'www.mindanaotimes.com.ph', 'mindanaotimes.com.ph',
  'www.sunstar.com.ph',
  'edgedavao.net', 'www.edgedavao.net',
  'davaocity.gov.ph', 'www.davaocity.gov.ph', // City Government newsroom
];

const MONTHS = [
  'january', 'february', 'march', 'april', 'may', 'june',
  'july', 'august', 'september', 'october', 'november', 'december',
];
const MONTH_NAMES = MONTHS.map((m) => m[0].toUpperCase() + m.slice(1));

/** Plausible residential rate range (PHP/kWh). */
/** 12.9 -> "12.90", 10.6407 -> "10.6407" (peso amounts as Davao Light writes them). */
function peso(n) {
  return Number.isInteger(Math.round(n * 10000) / 100) ? n.toFixed(2) : String(n);
}

const MIN_RATE = 5;
const MAX_RATE = 30;

function hostOf(url) {
  try {
    const u = new URL(url);
    return u.protocol === 'https:' ? u.hostname : null;
  } catch (_) {
    return null;
  }
}

function isOfficialUrl(url) {
  return OFFICIAL_HOSTS.includes(hostOf(url));
}

/** Official or an allowed news outlet (https only). */
function isTrustedUrl(url) {
  const h = hostOf(url);
  return OFFICIAL_HOSTS.includes(h) || NEWS_HOSTS.includes(h);
}

/** 'official' | 'news' | null for a source URL. */
function trustOf(url) {
  const h = hostOf(url);
  if (OFFICIAL_HOSTS.includes(h)) return 'official';
  if (NEWS_HOSTS.includes(h)) return 'news';
  return null;
}

/** Minimal HTML entity decoding for the entities these sites emit. */
function decodeEntities(s) {
  return s
    .replace(/&nbsp;|&#160;/g, ' ')
    .replace(/&amp;|&#38;/g, '&')
    .replace(/&#8217;|&#8216;|&rsquo;|&lsquo;/g, "'")
    .replace(/&#8220;|&#8221;|&ldquo;|&rdquo;|&quot;/g, '"')
    .replace(/&#8211;|&#8212;|&ndash;|&mdash;/g, '-')
    .replace(/&#8369;/g, '₱')
    .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(Number(n)));
}

/** Page/article HTML -> plain text (scripts and styles dropped). */
function htmlToText(html) {
  return decodeEntities(
    html
      .replace(/<script[\s\S]*?<\/script>/gi, ' ')
      .replace(/<style[\s\S]*?<\/style>/gi, ' ')
      .replace(/<[^>]+>/g, ' ')
  ).replace(/\s+/g, ' ').trim();
}

/** RSS 2.0 -> [{title, link, pubDate(ms), description, content}]. */
function parseRss(xml) {
  const tag = (item, name) => {
    const open = `<${name}>`;
    const a = item.indexOf(open);
    if (a < 0) return '';
    const b = item.indexOf(`</${name}>`, a);
    if (b < 0) return '';
    let v = item.slice(a + open.length, b);
    v = v.replace(/^\s*<!\[CDATA\[/, '').replace(/\]\]>\s*$/, '');
    return v;
  };
  return xml.split('<item>').slice(1).map((item) => {
    const pub = Date.parse(tag(item, 'pubDate'));
    return {
      title: htmlToText(tag(item, 'title')),
      link: htmlToText(tag(item, 'link')),
      pubDate: Number.isFinite(pub) ? pub : 0,
      description: htmlToText(tag(item, 'description')),
      content: htmlToText(tag(item, 'content:encoded')),
    };
  });
}

/** "August", "Aug", "Aug.", "Sept" -> 0-11, else -1. */
function monthIndex(name) {
  const n = String(name).toLowerCase().replace(/\.$/, '');
  if (n.length < 3) return -1;
  return MONTHS.findIndex((m) => m === n || m.startsWith(n));
}

/** Date in Manila (UTC+8) at 00:00 local, as epoch ms. */
function phDate(year, month0, day) {
  return Date.UTC(year, month0, day) - 8 * 3600 * 1000;
}

const PESO = String.raw`(?:PHP|Php|P|₱)\s?`;
const NUM = String.raw`(\d{1,2}\.\d{2,4})`;
const PER_KWH = String.raw`\s*(?:\/\s*kwh|per\s+kilowatt|per\s+kwh)`;

/**
 * Finds and verifies a Davao Light residential-rate advisory in [text].
 *
 * Returns null when the text isn't a rate advisory at all, otherwise
 * { verified, rate, previousRate, delta, periodStart, periodEnd,
 *   periodLabel, sentence, checks: [{name, pass, detail}] }.
 * `verified` is true only when every check that could run passed.
 */
function parseRateAdvisory(text, { now = Date.now(), publishedAt = 0 } = {}) {
  const t = text.replace(/\s+/g, ' ');
  const findRate = (win) =>
    win.match(new RegExp(String.raw`(?:bringing|brings|bring|brought)\s+(?:the\s+|its\s+|it\s+)?(?:new\s+)?(?:overall\s+)?(?:residential\s+)?(?:electricity\s+)?rate\s+(?:up\s+|down\s+)?to\s*${PESO}${NUM}${PER_KWH}`, 'i')) ||
    win.match(new RegExp(String.raw`rate[^.]{0,80}?\b(?:is|at|now)\s+(?:at\s+)?${PESO}${NUM}${PER_KWH}`, 'i')) ||
    win.match(new RegExp(String.raw`\bto\s+${PESO}${NUM}${PER_KWH}`, 'i'));

  // The advisory sentence(s) around a mention of the residential rate: a
  // little before (for "Davao Light's …") and enough after to reach
  // "bringing the rate to … from …" and the billing period. A page can
  // mention it first in its title or navigation, so each mention is tried
  // until one has a rate next to it.
  let window = '';
  let rateMatch = null;
  for (const m of t.matchAll(/(?:overall )?residential (?:electricity )?rate/gi)) {
    window = t.slice(Math.max(0, m.index - 160), m.index + 760);
    rateMatch = findRate(window);
    if (rateMatch) break;
  }
  if (!rateMatch) return null;
  const rate = parseFloat(rateMatch[1]);

  const prevMatch = window.match(new RegExp(String.raw`from\s+(?:(?:last|the previous)\s+month['’]s\s+rate\s+of\s+|the previous\s+rate\s+of\s+)?${PESO}${NUM}`, 'i'));
  const previousRate = prevMatch ? parseFloat(prevMatch[1]) : null;

  const deltaMatch =
    window.match(new RegExp(String.raw`\b(increased|decreased|rose|dropped|declined|went up|went down|up|down|lower(?:ed)?|higher)\s+(?:by\s+)?${PESO}${NUM}`, 'i')) ||
    window.match(new RegExp(String.raw`\b(cut|trimmed|reduced|lowered|raised|hiked|increased|decreased)\b[^.]{0,80}?\bby\s+${PESO}${NUM}`, 'i')) ||
    window.match(new RegExp(String.raw`${PESO}${NUM}(?:\/kwh)?\s+(increase|decrease|reduction|hike)`, 'i')) ||
    window.match(new RegExp(String.raw`\b(increase|decrease|reduction|hike)\s+of\s+${PESO}${NUM}`, 'i')) ||
    window.match(new RegExp(String.raw`${PESO}${NUM}(?:-?per-?kilowatt-?hour|\s*\/\s*kwh|\s+per\s+kwh)?\s*(?:\(kwh\)\s*)?(adjustment|increase|decrease|reduction|hike)`, 'i'));
  let delta = null;
  if (deltaMatch) {
    const [word, num] = /\d/.test(deltaMatch[1])
      ? [deltaMatch[2], deltaMatch[1]]
      : [deltaMatch[1], deltaMatch[2]];
    // A neutral "adjustment" takes its direction from the rate phrase
    // ("brought the rate up to") or from the previous rate.
    const down = /adjustment/i.test(word)
      ? (/\bdown\b/i.test(rateMatch[0]) ||
        (!/\bup\b/i.test(rateMatch[0]) && previousRate != null && rate < previousRate))
      : /decreas|drop|declin|down|lower|reduc|cut|trim/i.test(word);
    delta = (down ? -1 : 1) * parseFloat(num);
  }

  // Billing period: "billing period of July 11 to August 10, 2026", else
  // "this September 2025" / "this June 2026" (Davao Light bills 11th-10th).
  let periodStart = null;
  let periodEnd = null;
  let periodLabel = '';
  // "billing period of Aug. 11 to Sept. 10, 2026" or "for the September 11
  // to October 10, 2026 billing period".
  const range =
    window.match(/billing period of ([A-Z][a-z]+)\.? (\d{1,2})(?:, (\d{4}))? to ([A-Z][a-z]+)\.? (\d{1,2}),? (\d{4})/) ||
    window.match(/\b([A-Z][a-z]+)\.? (\d{1,2})(?:, (\d{4}))? to ([A-Z][a-z]+)\.? (\d{1,2}),? (\d{4}) billing/);
  if (range && monthIndex(range[1]) >= 0 && monthIndex(range[4]) >= 0) {
    const endYear = Number(range[6]);
    const m1 = monthIndex(range[1]);
    const m2 = monthIndex(range[4]);
    const startYear = range[3] ? Number(range[3]) : (m1 > m2 ? endYear - 1 : endYear);
    periodStart = phDate(startYear, m1, Number(range[2]));
    periodEnd = phDate(endYear, m2, Number(range[5]));
    periodLabel = `${MONTH_NAMES[m1]} ${range[2]} – ${MONTH_NAMES[m2]} ${range[5]}, ${endYear}`;
  } else {
    // "this June 2026" / "for August" (year taken from the post date).
    const month = window.match(/\b(?:this|for)\s+([A-Z][a-z]+)\b(?:\s+(\d{4}))?/);
    if (month && monthIndex(month[1]) >= 0 && (month[2] || publishedAt > 0)) {
      const m = monthIndex(month[1]);
      let y = Number(month[2]);
      if (!month[2]) {
        const pub = new Date(publishedAt);
        y = pub.getUTCFullYear();
        if (m > pub.getUTCMonth() + 1) y -= 1; // e.g. "for December" posted in January
      }
      periodStart = phDate(y, m, 11);
      periodEnd = phDate(m === 11 ? y + 1 : y, (m + 1) % 12, 10);
      periodLabel = `${MONTH_NAMES[m]} ${y} billing`;
    }
  }

  const checks = [];
  checks.push({
    name: 'Names Davao Light',
    pass: /davao light/i.test(window),
    detail: 'The rate sentence is about Davao Light, not another utility.',
  });
  checks.push({
    name: 'Realistic rate',
    pass: rate >= MIN_RATE && rate <= MAX_RATE,
    detail: `₱${peso(rate)} is within ₱${MIN_RATE}–₱${MAX_RATE}/kWh.`,
  });
  if (previousRate != null && delta != null) {
    const expected = Math.round((previousRate + delta) * 10000) / 10000;
    checks.push({
      name: 'Numbers add up',
      pass: Math.abs(expected - rate) <= 0.011,
      detail: `₱${peso(previousRate)} ${delta >= 0 ? '+' : '−'} ₱${peso(Math.abs(delta))} = ₱${peso(expected)}.`,
    });
  }
  const DAY = 24 * 3600 * 1000;
  if (periodEnd != null) {
    checks.push({
      name: 'Current billing period',
      pass: periodEnd >= now - 3 * DAY && periodStart <= now + 40 * DAY,
      detail: `Covers ${periodLabel}.`,
    });
  } else {
    checks.push({
      name: 'Recent advisory',
      pass: publishedAt > 0 && now - publishedAt <= 40 * DAY,
      detail: 'No billing period stated; published in the last 40 days.',
    });
  }

  return {
    verified: checks.every((c) => c.pass),
    rate,
    previousRate,
    delta,
    periodStart,
    periodEnd,
    periodLabel,
    sentence: window.slice(Math.max(0, window.search(/residential/i) - 120), 420).trim(),
    checks,
  };
}

/**
 * A post page's publish time from its metadata (`article:published_time`
 * or JSON-LD `datePublished`, which Wix and WordPress both emit), as epoch
 * ms, else 0. Deliberately not scraped from the body text, where the first
 * date is often the billing period, not the publish date.
 */
function extractPostDate(html) {
  const m = html.match(/article:published_time"\s+content="([^"]+)"/) ||
    html.match(/"datePublished"\s*:\s*"([^"]+)"/);
  const ms = m ? Date.parse(m[1]) : NaN;
  return Number.isFinite(ms) ? ms : 0;
}

/** Davao Light newsroom posts worth a notification (bid invites aren't). */
function isNewsworthy(item) {
  return !/^\s*invitation to bid/i.test(item.title);
}

/** Looks like a rate advisory headline/summary (worth opening the article). */
function looksLikeRatePost(item) {
  const s = `${item.title} ${item.description} ${item.content}`;
  return /davao light|\bdlpc\b/i.test(s) &&
    /(residential rate|electricity rate|power rate|per kwh|\/kwh|kwh)/i.test(item.title + ' ' + item.description);
}

module.exports = {
  peso,
  extractPostDate,
  OFFICIAL_HOSTS,
  NEWS_HOSTS,
  isOfficialUrl,
  isTrustedUrl,
  trustOf,
  htmlToText,
  parseRss,
  parseRateAdvisory,
  isNewsworthy,
  looksLikeRatePost,
};
