const admin = require('firebase-admin');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const https = require('https');
const http = require('http');

const LOG_PREFIX = '[fetchDavaoLightRates]';
const DAVAO_LIGHT_FAQ_URL = 'https://www.davaolight.com/customer-services/faq';
const REQUEST_TIMEOUT = 15000; // 15 seconds
const FIREBASE_RATE_PATH = 'settings/electricityRate';

/**
 * Fetches the latest electricity rate from Davao Light's FAQ page using HTTP.
 * Uses the same parsing strategies as the Dart service.
 *
 * @returns {Promise<number|null>} The fetched rate as a number, or null if not found
 */
async function fetchLatestRate() {
  console.log(`${LOG_PREFIX} Fetching from: ${DAVAO_LIGHT_FAQ_URL}`);

  return new Promise((resolve, reject) => {
    const makeRequest = (url) => {
      const protocol = url.startsWith('https') ? https : http;

      const req = protocol.get(url, { timeout: REQUEST_TIMEOUT }, (res) => {
        let data = '';

        res.on('data', (chunk) => {
          data += chunk;
        });

        res.on('end', () => {
          if (res.statusCode !== 200) {
            reject(
              new Error(
                `Failed to fetch Davao Light FAQ (HTTP ${res.statusCode})`
              )
            );
            return;
          }

          console.log(
            `${LOG_PREFIX} Successfully fetched page (${data.length} bytes)`
          );
          const rate = parseRateFromHtml(data);
          resolve(rate);
        });
      });

      req.on('error', (err) => {
        reject(err);
      });

      req.on('timeout', () => {
        req.destroy();
        reject(
          new Error(
            `Request to Davao Light FAQ timed out after ${REQUEST_TIMEOUT / 1000}s`
          )
        );
      });
    };

    makeRequest(DAVAO_LIGHT_FAQ_URL);
  });
}

/**
 * Parses rate information from HTML content using multiple strategies.
 * Mirrors the logic from the Dart DavaoLightRateMonitor service.
 *
 * @param {string} htmlContent - The HTML content to parse
 * @returns {number|null} The extracted rate as a number, or null if not found
 */
function parseRateFromHtml(htmlContent) {
  // Strategy 1: Look for "PHP X.XXXX" pattern
  const phpPattern = /PHP\s*([\d.]+)/i;
  let match = phpPattern.exec(htmlContent);
  if (match && match[1]) {
    const rate = parseFloat(match[1]);
    if (rate > 0 && rate < 100) {
      console.log(`${LOG_PREFIX} Found rate via PHP pattern: $${rate}`);
      return rate;
    }
  }

  // Strategy 2: Look for "$X.XXXX" pattern (standalone dollar amounts)
  const dollarPattern = /\$\s*([\d.]+)/g;
  match = dollarPattern.exec(htmlContent);
  while (match) {
    if (match[1]) {
      const rate = parseFloat(match[1]);
      if (rate > 0 && rate < 100) {
        console.log(`${LOG_PREFIX} Found rate via dollar pattern: $${rate}`);
        return rate;
      }
    }
    match = dollarPattern.exec(htmlContent);
  }

  // Strategy 3: Look for "rate" followed by a number
  const ratePattern = /rate\s*[:\=]?\s*(?:php\s*)?([\d.]+)/i;
  match = ratePattern.exec(htmlContent);
  if (match && match[1]) {
    const rate = parseFloat(match[1]);
    if (rate > 0 && rate < 100) {
      console.log(`${LOG_PREFIX} Found rate via rate pattern: $${rate}`);
      return rate;
    }
  }

  // Strategy 4: Look for "kwh" or "kWh" followed by currency info
  const kwhPattern = /(?:kwh|kWh|kw\/h)\s*(?:rate|=|:)?\s*(?:php\s*)?([\d.]+)/i;
  match = kwhPattern.exec(htmlContent);
  if (match && match[1]) {
    const rate = parseFloat(match[1]);
    if (rate > 0 && rate < 100) {
      console.log(`${LOG_PREFIX} Found rate via kWh pattern: $${rate}`);
      return rate;
    }
  }

  console.log(`${LOG_PREFIX} No valid rate pattern found in HTML content`);
  return null;
}

/**
 * Main Cloud Function triggered by Cloud Scheduler every 6 hours.
 * Fetches Davao Light rates, compares with current rate, and creates
 * notifications/audit entries if a change is detected.
 */
async function fetchDavaoLightRates() {
  console.log(`${LOG_PREFIX} Starting rate fetch cycle`);
  const startTime = Date.now();

  try {
    // 1. Fetch current rate from Firebase
    const db = admin.database();
    const currentRateSnap = await db.ref(FIREBASE_RATE_PATH).get();
    const currentRate = currentRateSnap.val() || 9.0;

    console.log(
      `${LOG_PREFIX} Current rate in Firebase: $${currentRate.toFixed(4)}/kWh`
    );

    // 2. Fetch latest rate from Davao Light
    let fetchedRate = null;
    let fetchError = null;

    try {
      fetchedRate = await fetchLatestRate();
    } catch (error) {
      fetchError = error.message;
      console.error(`${LOG_PREFIX} Error fetching rate: ${fetchError}`);
    }

    // 3. Update last fetched timestamp regardless of success/failure
    const now = Date.now();
    await db.ref('settings/rateLastFetched').set(now);
    console.log(`${LOG_PREFIX} Updated rateLastFetched: ${new Date(now).toISOString()}`);

    // 4. If fetch failed, log and return early
    if (fetchedRate === null) {
      console.warn(
        `${LOG_PREFIX} Could not extract rate from Davao Light website`
      );
      const duration = Date.now() - startTime;
      console.log(`${LOG_PREFIX} Cycle completed in ${duration}ms (no rate change)`);
      return;
    }

    // 5. Compare rates (consider a change if difference > 0.0001)
    const rateChanged = Math.abs(fetchedRate - currentRate) > 0.0001;

    console.log(
      `${LOG_PREFIX} Rate comparison: old=$${currentRate.toFixed(4)}, new=$${fetchedRate.toFixed(4)}, hasChanged=${rateChanged}`
    );

    // 6. If rate changed, create notification and audit entries
    if (rateChanged) {
      const timestamp = now;
      const isoTimestamp = new Date(timestamp).toISOString();

      // Create notification entry
      const notificationId = `rate_change_${timestamp}`;
      const notificationData = {
        title: 'Electricity Rate Updated',
        message: `Rate changed from $${currentRate.toFixed(4)} to $${fetchedRate.toFixed(4)} PHP/kWh`,
        type: 'rate_change',
        timestamp: timestamp,
        oldRate: parseFloat(currentRate.toFixed(4)),
        newRate: parseFloat(fetchedRate.toFixed(4)),
        source: 'davao_light_announcement',
      };

      // Create audit entry
      const auditData = {
        timestamp: timestamp,
        isoTimestamp: isoTimestamp,
        oldRate: parseFloat(currentRate.toFixed(4)),
        newRate: parseFloat(fetchedRate.toFixed(4)),
        source: 'davao_light_announcement',
        fetchUrl: DAVAO_LIGHT_FAQ_URL,
      };

      // Perform all writes in parallel
      await Promise.all([
        db.ref(`notifications/${notificationId}`).set(notificationData),
        db.ref(`rate_changes/${timestamp}`).set(auditData),
        db.ref(FIREBASE_RATE_PATH).set(parseFloat(fetchedRate.toFixed(4))),
      ]);

      console.log(
        `${LOG_PREFIX} Rate change detected and recorded: $${currentRate.toFixed(4)} -> $${fetchedRate.toFixed(4)}`
      );
      console.log(`${LOG_PREFIX} Notification ID: ${notificationId}`);
    } else {
      console.log(`${LOG_PREFIX} No rate change detected`);
    }

    const duration = Date.now() - startTime;
    console.log(
      `${LOG_PREFIX} Cycle completed in ${duration}ms (rateChanged=${rateChanged})`
    );
  } catch (error) {
    console.error(`${LOG_PREFIX} Fatal error: ${error.message}`);
    console.error(`${LOG_PREFIX} Stack trace: ${error.stack}`);
    throw error;
  }
}

// Export as a scheduled Cloud Function (every 6 hours: 0 */6 * * *)
exports.fetchDavaoLightRates = onSchedule('0 */6 * * *', fetchDavaoLightRates);
