# Cloud Function: fetchDavaoLightRates

## Overview

The `fetchDavaoLightRates` Cloud Function is a scheduled Cloud Function that runs every 6 hours (via Firebase Cloud Scheduler) to automatically fetch the latest electricity rates from Davao Light and detect rate changes.

## File Structure

- **`functions/fetch_davao_light_rates.js`** - Main Cloud Function implementation
- **`functions/index.js`** - Updated to import and expose the function

## Functionality

### 1. Schedule
- Triggered via Cloud Scheduler with cron expression: `0 */6 * * *`
- Runs at 00:00, 06:00, 12:00, and 18:00 UTC (every 6 hours)
- Adjustments needed based on your Firebase project's timezone configuration

### 2. Rate Fetching
The function fetches the latest electricity rate from Davao Light's FAQ page using the same scraping logic as the Dart service:

**URL:** `https://www.davaolight.com/customer-services/faq`

**Parsing Strategies (in order of priority):**
1. Pattern: `PHP X.XXXX` - Looks for explicitly marked PHP rates
2. Pattern: `$X.XXXX` - Looks for dollar sign patterns
3. Pattern: `rate X.XXXX` - Looks for "rate" followed by a number
4. Pattern: `kWh X.XXXX` - Looks for kWh rates

### 3. Rate Comparison
- Compares fetched rate with current `settings/electricityRate` in Firebase
- Considers a rate change if the difference is > 0.0001
- This threshold prevents false positives from rounding differences

### 4. Notification Creation
When a rate change is detected, the function creates a notification entry at:

**Path:** `notifications/{id}`

**Document Structure:**
```javascript
{
  "title": "Electricity Rate Updated",
  "message": "Rate changed from $X.XXXX to $Y.YYYY PHP/kWh",
  "type": "rate_change",
  "timestamp": 1234567890123,  // milliseconds since epoch
  "oldRate": 9.5210,            // numeric value
  "newRate": 9.8765,            // numeric value
  "source": "davao_light_announcement"
}
```

### 5. Audit Entry Creation
An audit entry is created at:

**Path:** `rate_changes/{timestamp}`

**Document Structure:**
```javascript
{
  "timestamp": 1234567890123,
  "isoTimestamp": "2024-01-15T12:34:56.789Z",
  "oldRate": 9.5210,
  "newRate": 9.8765,
  "source": "davao_light_announcement",
  "fetchUrl": "https://www.davaolight.com/customer-services/faq"
}
```

### 6. Last Fetch Timestamp Update
Regardless of whether a rate change is detected, the function updates:

**Path:** `settings/rateLastFetched`

**Value:** Milliseconds since epoch (timestamp when fetch occurred)

This timestamp is updated even if:
- The fetch fails
- No rate change is detected
- The rate parsing fails

### 7. Rate Update
If a rate change is detected, the function updates:

**Path:** `settings/electricityRate`

**Value:** The newly fetched rate (as a number)

## Error Handling

The function includes comprehensive error handling:

- **Network Errors:** Logs the error but continues (doesn't crash)
- **Parsing Errors:** Attempts multiple parsing strategies before giving up
- **Timeout:** 15-second timeout for HTTP requests to Davao Light
- **Firebase Write Errors:** All database writes are awaited and errors are logged
- **Fatal Errors:** Re-throws to Cloud Functions logging for monitoring

## Logging

All operations are logged to Firebase Cloud Functions logs with the prefix `[fetchDavaoLightRates]`:

```
[fetchDavaoLightRates] Fetching from: https://www.davaolight.com/customer-services/faq
[fetchDavaoLightRates] Successfully fetched page (45821 bytes)
[fetchDavaoLightRates] Found rate via PHP pattern: $9.8765
[fetchDavaoLightRates] Current rate in Firebase: $9.5210/kWh
[fetchDavaoLightRates] Rate comparison: old=$9.5210, new=$9.8765, hasChanged=true
[fetchDavaoLightRates] Rate change detected and recorded: $9.5210 -> $9.8765
[fetchDavaoLightRates] Notification ID: rate_change_1234567890123
[fetchDavaoLightRates] Cycle completed in 1234ms (rateChanged=true)
```

## Firebase Database Structure

The function interacts with the following Firebase Realtime Database paths:

```
├── settings/
│   ├── electricityRate          (number: current rate in PHP/kWh)
│   └── rateLastFetched          (number: timestamp in ms)
├── notifications/
│   └── {rate_change_timestamp}  (notification entry)
└── rate_changes/
    └── {timestamp}              (audit entry)
```

## Deployment

The function is automatically deployed when you deploy your Cloud Functions:

```bash
cd functions
npm install  # Install dependencies if needed
firebase deploy --only functions
```

## Monitoring

Monitor the function's execution:

```bash
firebase functions:log --follow
```

Watch for messages starting with `[fetchDavaoLightRates]`.

## Configuration

### Changing the Schedule

To modify the run frequency, edit `functions/fetch_davao_light_rates.js`:

```javascript
// Current: every 6 hours at 00, 06, 12, 18 UTC
exports.fetchDavaoLightRates = onSchedule('0 */6 * * *', fetchDavaoLightRates);

// Examples:
// Every hour:           '0 * * * *'
// Every 3 hours:        '0 */3 * * *'
// Every 12 hours:       '0 */12 * * *'
// Daily at 6 AM UTC:    '0 6 * * *'
// Every Monday at 6 AM: '0 6 * * 1'
```

### Changing the Timeout

Adjust the HTTP request timeout in `functions/fetch_davao_light_rates.js`:

```javascript
const REQUEST_TIMEOUT = 15000; // milliseconds (currently 15 seconds)
```

### Changing the Rate Threshold

The rate change threshold (default: 0.0001) can be adjusted:

```javascript
const rateChanged = Math.abs(fetchedRate - currentRate) > 0.0001;
// Change 0.0001 to a different value (e.g., 0.01 for 0.01 PHP difference)
```

## Testing

### Local Emulation

To test locally using Firebase Emulator:

```bash
cd functions
npm run serve
```

Then trigger the function via the emulator interface or by making a POST request.

### Manual Testing

You can manually invoke the function:

1. Deploy to Firebase
2. Run: `firebase functions:call fetchDavaoLightRates`

### Expected Output

On successful execution, check:
1. Firebase Cloud Functions logs for `[fetchDavaoLightRates]` messages
2. `settings/rateLastFetched` should be updated
3. If rate changed: `notifications/` and `rate_changes/` should have new entries
4. If rate changed: `settings/electricityRate` should be updated

## Integration with Dart App

The Dart app listens to changes in Firebase:

- **Rate Changes:** App receives notifications when `settings/electricityRate` changes
- **Audit Trail:** `rate_changes/` entries provide historical data for auditing

The Dart service `DavaoLightRateMonitor` can still run independently for real-time monitoring in the app, while this Cloud Function provides periodic updates at a scheduled interval.

## Cost Considerations

- **Cloud Scheduler:** ~$0.10 per job per month
- **Cloud Function Execution:** Charged based on invocations and compute time (~1-2 seconds per execution)
- **Realtime Database Reads/Writes:** Minimal impact (1 read, 3-5 writes per execution)

At 4 executions per day (every 6 hours), the monthly cost is negligible.

## Troubleshooting

### Function not running
- Check Cloud Scheduler is enabled in your Firebase project
- Verify the function was deployed: `firebase deploy --only functions`
- Check function logs: `firebase functions:log --follow`

### No rate detected
- Check Davao Light's website structure hasn't changed
- The HTML parsing may need updating if the website redesigns
- Verify the HTTP request succeeds in logs

### No notifications created
- Verify `settings/electricityRate` path exists and has a value
- Check if rate difference is > 0.0001 PHP
- Verify Firebase write permissions

### Database write errors
- Ensure Firebase Realtime Database security rules allow Cloud Function writes
- Typical rule: `{".read": true, ".write": "root.child('auth').val() != null || request.auth != null"}`

## Future Enhancements

1. **API Integration:** Replace HTML parsing with an official Davao Light API
2. **Rate Prediction:** Trend analysis for rate predictions
3. **Email Notifications:** Send emails to users when rates change
4. **Historical Charts:** Store and visualize rate history
5. **Webhook Integration:** Notify external systems of rate changes
