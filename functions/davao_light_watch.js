/**
 * Davao Light watcher: finds the latest official rate advisory and news,
 * verifies them, and notifies admins. Replaces fetch_davao_light_rates.js,
 * which scraped the first peso amount off the FAQ page (it could pick up a
 * fixed charge like "P0.0025 per kilowatt hour") and silently overwrote the
 * electricity rate.
 *
 * Sources (https only, allow-listed in davao_light_parse):
 *  - official: Davao Light's newsroom feed and Aboitiz Eyes (its parent
 *    company's newsroom), searched for rate advisories;
 *  - news: Mindanao Times and SunStar, which report every monthly advisory
 *    (Davao Light posts those on Facebook, which can't be read here).
 * Each advisory must pass parseRateAdvisory's checks (names Davao Light,
 * realistic rate, the stated change adds up, current billing period). The
 * result is labelled 'official', 'confirmed' (two news outlets agree) or
 * 'news' (one outlet) so the admin sees how much to trust it.
 *
 * A rate is never applied automatically. A verified advisory whose rate
 * differs from settings/electricityRate is saved as settings/rateProposal
 * and announced with a `rate_proposal` notification; an admin applies or
 * dismisses it in Settings. New newsroom posts (bid invitations excluded)
 * become `davao_light_news` notifications.
 *
 * Runs every 6 hours, and on demand from Settings > Fetch Latest Rate via
 * the `checkDavaoLightNow` callable.
 */
const crypto = require('crypto');
const admin = require('firebase-admin');
const functions = require('firebase-functions/v1');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const {
  isTrustedUrl, trustOf, htmlToText, parseRss, parseRateAdvisory,
  isNewsworthy, looksLikeRatePost, peso, extractPostDate,
} = require('./davao_light_parse');

const LOG = '[DavaoLightWatch]';
const DL_FEED = 'https://www.davaolight.com/blog-feed.xml';
const AE_FEED =
  'https://aboitizeyes.aboitiz.com/?s=davao+light+overall+residential+rate&feed=rss2';
// Davao Light's own site search for rate posts: its newsroom feed only
// holds the latest ~20 posts, which bid invitations push the monthly rate
// posts out of within days.
const DL_RATE_SEARCH =
  'https://www.davaolight.com/search?q=residential%20rate&type=blog';
const MAX_SEARCH_POSTS = 12;

const NEWS_FEEDS = {
  mindanaotimes:
    'https://www.mindanaotimes.com.ph/?s=davao+light+residential+rate&feed=rss2',
  sunstar: 'https://www.sunstar.com.ph/feed',
  edgedavao: 'https://edgedavao.net/?s=davao+light+rate&feed=rss2',
  davaocity: 'https://davaocity.gov.ph/?s=dlpc+rate&feed=rss2',
};
const TIMEOUT_MS = 20000;
const MAX_ARTICLES = 8; // rate-post candidates opened per run
const MAX_NEWS_NOTIFICATIONS = 5; // per run, so a backlog can't flood
// The electricity rate is campus-wide, so only campus admins (not institute
// admins) may run the check -- same rule as the app's Settings screen.
const ADMIN_ROLES = ['admin', 'main_admin', 'super_admin'];

async function getText(url) {
  if (!isTrustedUrl(url)) throw new Error(`Not an allowed source: ${url}`);
  const res = await fetch(url, {
    headers: { 'User-Agent': 'SmartSwitch-DNSC/1.0 (rate watcher)' },
    signal: AbortSignal.timeout(TIMEOUT_MS),
    redirect: 'follow',
  });
  if (!res.ok) throw new Error(`HTTP ${res.status} for ${url}`);
  if (res.url && !isTrustedUrl(res.url)) {
    throw new Error(`Redirected to a site that isn't allowed: ${res.url}`);
  }
  return res.text();
}

/** Stable key for a URL (RTDB keys can't contain . / # $ [ ]). */
function keyFor(url) {
  return crypto.createHash('sha1').update(url).digest('hex');
}

async function readFeed(name, url, sources) {
  try {
    const items = parseRss(await getText(url)).filter((i) => isTrustedUrl(i.link));
    sources[name] = { ok: true, items: items.length };
    return items;
  } catch (e) {
    console.warn(`${LOG} ${name} feed failed: ${e.message}`);
    sources[name] = { ok: false, error: e.message };
    return [];
  }
}

/** Rate posts listed by davaolight.com's search, as feed-like items. */
async function readSiteSearch(sources) {
  try {
    const html = await getText(DL_RATE_SEARCH);
    const links = [...new Set(html.match(/https:\/\/www\.davaolight\.com\/post\/[a-z0-9-]+/g) || [])]
      .filter((l) => /rate|kwh|billing/.test(l.split('/post/')[1]))
      .slice(0, MAX_SEARCH_POSTS);
    sources.davaolightSearch = { ok: true, items: links.length };
    return links.map((link) => ({
      title: link.split('/post/')[1].replace(/-/g, ' '),
      link, pubDate: 0, description: '', content: '', fromSearch: true,
    }));
  } catch (e) {
    console.warn(`${LOG} davaolight search failed: ${e.message}`);
    sources.davaolightSearch = { ok: false, error: e.message };
    return [];
  }
}

/** Newest verified advisory across all sources, with its trust level. */
async function findRateAdvisory(items, now) {
  const fromFeeds = items
    .filter((i) => !i.fromSearch && looksLikeRatePost(i))
    .sort((a, b) => b.pubDate - a.pubDate)
    .slice(0, MAX_ARTICLES);
  const seen = new Set(fromFeeds.map((i) => i.link));
  const candidates = [
    ...fromFeeds,
    ...items.filter((i) => i.fromSearch && !seen.has(i.link)),
  ];

  const found = [];
  for (const item of candidates) {
    let text = item.content;
    let pageDate = 0;
    if (!/residential/i.test(text)) {
      try {
        const html = await getText(item.link);
        text = htmlToText(html);
        pageDate = extractPostDate(html);
      } catch (e) {
        console.warn(`${LOG} could not open ${item.link}: ${e.message}`);
        continue;
      }
    }
    const publishedAt = item.pubDate || pageDate;
    const parsed = parseRateAdvisory(text, { now, publishedAt });
    if (parsed) found.push({ ...parsed, url: item.link, title: item.title, publishedAt });
  }

  // A post dated after 'now' can't be current (only happens in simulations).
  const verified = found.filter((f) => f.verified && !(f.publishedAt > now + 24 * 3600 * 1000))
    .sort((a, b) => (b.periodStart || b.publishedAt) - (a.periodStart || a.publishedAt));
  if (!verified.length) return { best: null, rejected: found.length };
  const best = verified[0];
  const agreeing = verified.filter((f) => Math.abs(f.rate - best.rate) < 0.0001 &&
    f.periodStart === best.periodStart);
  const hosts = [...new Set(agreeing.map((f) => new URL(f.url).hostname.replace(/^www\./, '')))];
  const official = agreeing.find((f) => trustOf(f.url) === 'official');
  const trust = official ? 'official' : hosts.length >= 2 ? 'confirmed' : 'news';
  // Link the most trustworthy agreeing source.
  const shown = official || best;
  return {
    best: { ...best, url: shown.url, title: shown.title, trust, sources: hosts },
    rejected: found.length - verified.length,
  };
}

/** Notifies once about each new (unseen) newsroom post. */
async function announceNews(db, dlItems) {
  const seenRef = db.ref('davao_light/seenNews');
  const seen = (await seenRef.get()).val() || {};
  const firstRun = Object.keys(seen).length === 0;
  const fresh = dlItems.filter((i) => isNewsworthy(i) && !seen[keyFor(i.link)])
    .sort((a, b) => b.pubDate - a.pubDate);

  const updates = {};
  let notified = 0;
  for (const item of fresh) {
    updates[`davao_light/seenNews/${keyFor(item.link)}`] = item.pubDate || Date.now();
    // First run only records what's already there, so installing this
    // doesn't dump the whole feed into notifications.
    if (firstRun || notified >= MAX_NEWS_NOTIFICATIONS) continue;
    const id = db.ref('notifications').push().key;
    updates[`notifications/${id}`] = {
      type: 'davao_light_news',
      title: item.title,
      message: item.description ? item.description.slice(0, 180) : 'New post from Davao Light.',
      link: item.link,
      source: new URL(item.link).hostname,
      publishedAt: item.pubDate || null,
      timestamp: Date.now(),
    };
    notified++;
  }
  if (Object.keys(updates).length) await db.ref().update(updates);
  return { newPosts: fresh.length, notified };
}

/** One full check. Returns a summary (also stored at davao_light/lastCheck). */
async function checkDavaoLight() {
  const db = admin.database();
  const now = Date.now();
  const sources = {};
  const [dlItems, searchItems, aeItems, ...newsFeeds] = await Promise.all([
    readFeed('davaolight', DL_FEED, sources),
    readSiteSearch(sources),
    readFeed('aboitizeyes', AE_FEED, sources),
    ...Object.entries(NEWS_FEEDS).map(([name, url]) => readFeed(name, url, sources)),
  ]);

  const news = await announceNews(db, dlItems);
  const { best, rejected } = await findRateAdvisory(
    [...dlItems, ...searchItems, ...aeItems, ...newsFeeds.flat()], now);

  const currentRate = Number((await db.ref('settings/electricityRate').get()).val()) || null;
  let rateStatus = 'no_advisory';
  let proposal = null;

  if (best) {
    const same = currentRate != null && Math.abs(best.rate - currentRate) < 0.0001;
    rateStatus = same ? 'up_to_date' : 'new_rate';
    proposal = {
      rate: best.rate,
      previousRate: best.previousRate,
      delta: best.delta,
      periodStart: best.periodStart,
      periodEnd: best.periodEnd,
      periodLabel: best.periodLabel,
      sourceUrl: best.url,
      sourceTitle: best.title,
      publishedAt: best.publishedAt || null,
      trust: best.trust,
      sources: best.sources,
      checks: best.checks,
      excerpt: best.sentence.slice(0, 400),
      detectedAt: now,
    };
    if (!same) {
      const existing = (await db.ref('settings/rateProposal').get()).val();
      const isRepeat = existing && Math.abs(existing.rate - best.rate) < 0.0001 &&
        existing.periodStart === best.periodStart;
      if (!isRepeat) {
        const id = db.ref('notifications').push().key;
        await db.ref().update({
          'settings/rateProposal': { ...proposal, status: 'pending' },
          [`notifications/${id}`]: {
            type: 'rate_proposal',
            title: 'Davao Light announced a new rate',
            message: `₱${peso(best.rate)}/kWh${best.periodLabel ? ` for ${best.periodLabel}` : ''} ` +
              `(now ₱${currentRate == null ? '—' : peso(currentRate)}). Source: ${best.sources.join(', ')} ` +
              `(${best.trust}). Review it in Settings.`,
            newRate: best.rate,
            oldRate: currentRate,
            link: best.url,
            timestamp: now,
          },
        });
      }
    }
  }

  const summary = {
    at: now,
    rateStatus,
    currentRate,
    proposal,
    rejectedAdvisories: rejected,
    news,
    sources,
  };
  await db.ref('davao_light/lastCheck').set(summary);
  console.log(`${LOG} ${rateStatus}; news ${news.newPosts} new / ${news.notified} notified; rejected ${rejected}`);
  return summary;
}

exports.watchDavaoLight = onSchedule(
  { schedule: '0 */6 * * *', timeZone: 'Asia/Manila' },
  async () => { await checkDavaoLight(); });

/** Settings > Fetch Latest Rate. Admin tiers only; cached for 60 s. */
exports.checkDavaoLightNow = functions.https.onCall(async (_data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'You must be logged in.');
  }
  const role = (await admin.database().ref(`users/${context.auth.uid}/role`).get()).val();
  if (!ADMIN_ROLES.includes(role)) {
    throw new functions.https.HttpsError('permission-denied', 'Only admins can check for rate updates.');
  }
  const last = (await admin.database().ref('davao_light/lastCheck').get()).val();
  if (last && Date.now() - last.at < 60 * 1000) return last;
  try {
    return await checkDavaoLight();
  } catch (e) {
    console.error(`${LOG} check failed: ${e.stack}`);
    throw new functions.https.HttpsError('unavailable', `Could not reach Davao Light: ${e.message}`);
  }
});

/**
 * Settings > Paste advisory. Davao Light often posts the monthly rate only
 * on Facebook (unreadable without a login) days before any news site
 * reports it, so an admin can paste the post's text. It goes through the
 * same checks as fetched advisories; if they pass and the rate differs,
 * it becomes the pending proposal labelled 'pasted'.
 */
exports.verifyAdvisoryText = functions.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'You must be logged in.');
  }
  const db = admin.database();
  const role = (await db.ref(`users/${context.auth.uid}/role`).get()).val();
  if (!ADMIN_ROLES.includes(role)) {
    throw new functions.https.HttpsError('permission-denied', 'Only campus admins can update the rate.');
  }
  const text = String((data && data.text) || '').slice(0, 4000);
  const link = String((data && data.link) || '').trim().slice(0, 500);
  if (text.trim().length < 30) {
    throw new functions.https.HttpsError('invalid-argument', 'Paste the full advisory text.');
  }
  const now = Date.now();
  const parsed = parseRateAdvisory(text, { now });
  if (!parsed) {
    return { status: 'not_an_advisory' };
  }
  const summary = {
    rate: parsed.rate,
    periodLabel: parsed.periodLabel,
    checks: parsed.checks,
  };
  if (!parsed.verified) return { status: 'failed_checks', ...summary };

  const currentRate = Number((await db.ref('settings/electricityRate').get()).val()) || null;
  if (currentRate != null && Math.abs(parsed.rate - currentRate) < 0.0001) {
    return { status: 'up_to_date', ...summary };
  }
  const email = context.auth.token.email || 'an admin';
  await db.ref('settings/rateProposal').set({
    rate: parsed.rate,
    previousRate: parsed.previousRate,
    delta: parsed.delta,
    periodStart: parsed.periodStart,
    periodEnd: parsed.periodEnd,
    periodLabel: parsed.periodLabel,
    sourceUrl: /^https:\/\//i.test(link) ? link : '',
    sourceTitle: 'Pasted advisory',
    publishedAt: null,
    trust: 'pasted',
    sources: [email],
    checks: parsed.checks,
    excerpt: parsed.sentence.slice(0, 400),
    detectedAt: now,
    status: 'pending',
  });
  return { status: 'proposed', ...summary };
});

// For local runs / tests.
exports._internal = { checkDavaoLight, readFeed, readSiteSearch, findRateAdvisory };
