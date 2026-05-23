/*
  SmartPowerSwitch ESP32 Firmware (ID-only registration flow)

  What this sketch does:
  1) Connects to WiFi
  2) Reads PZEM-004T V4.0 values (voltage/current/power/energy)
  3) Polls Firebase relay command from: /devices/<DEVICE_ID>/relay
  4) Controls an SSR output pin
  5) Pushes telemetry to: /devices/<DEVICE_ID>

  Required Arduino libraries:
  - ArduinoJson (by Benoit Blanchon)
  - PZEM004Tv30 (PZEM-004T V4.0 library used in the video)

  Board:
  - ESP32 Dev Module (or compatible ESP32)

  Wiring (example):
  - SSR IN  -> GPIO 26
  - PZEM TX -> ESP32 RX2 (GPIO 16)
  - PZEM RX -> ESP32 TX2 (GPIO 17)
  - Common GND

  IMPORTANT:
  - Register DEVICE_ID first in app Settings -> IoT Device Inventory.
  - This firmware assumes your Firebase rules allow ID-registered unauthenticated
    read/write under /devices/<DEVICE_ID>.
*/

#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <HardwareSerial.h>
#include <PZEM004Tv30.h>
#include <time.h>

// ===================== USER CONFIG =====================
static const char* WIFI_SSID = "Rose";
static const char* WIFI_PASSWORD = "Roseslowly";

static const char* FIREBASE_DB_URL =
    "https://smartpowerswitch-e90d0-default-rtdb.asia-southeast1.firebasedatabase.app";

// Must match ID registered in app (master_devices/<ID>)
static const char* DEVICE_ID = "ESP32-ROOM101-001";

// Hardware pins
static const uint8_t SSR_PIN = 26;
static const uint8_t PZEM_RX_PIN = 16;  // ESP32 RX2
static const uint8_t PZEM_TX_PIN = 17;  // ESP32 TX2

// Set to false if your SSR module is active LOW
static const bool SSR_ACTIVE_HIGH = true;

// Intervals
static const uint32_t RELAY_POLL_MS = 1000;
static const uint32_t TELEMETRY_PUSH_MS = 3000;
static const uint32_t WIFI_RETRY_MS = 5000;
static const uint32_t AUTOMATION_POLL_MS = 15000;
static const uint32_t TIMEZONE_REFRESH_MS = 300000;
static const uint32_t PZEM_UART_BAUD = 9600;
static const uint32_t PZEM_PROBE_RETRY_MS = 15000;

// =======================================================

PZEM004Tv30 pzem(Serial2, PZEM_RX_PIN, PZEM_TX_PIN);

uint8_t pzemAddress = 0xF8;  // Factory default address for v4.0 modules

bool relayState = false;
bool pzemReady = false;
// Track last seen energy reading so we can write per-interval history deltas
float lastReportedEnergyKwh = -1.0f;

uint32_t lastRelayPollMs = 0;
uint32_t lastTelemetryPushMs = 0;
uint32_t lastWifiRetryMs = 0;
uint32_t lastAutomationPollMs = 0;
uint32_t lastTimezoneRefreshMs = 0;
uint32_t lastPzemProbeMs = 0;
wl_status_t lastWifiStatus = WL_DISCONNECTED;  // Track WiFi status changes

uint64_t bootEpochMs = 0;
uint32_t bootMillisAtSync = 0;
int32_t scheduleTimezoneOffsetMinutes = 480;

struct ScheduleClock {
  String day;
  int minutes;
};

static inline float roundTo(float value, int places) {
  float scale = 1.0f;
  for (int i = 0; i < places; i++) {
    scale *= 10.0f;
  }
  return roundf(value * scale) / scale;
}

static inline bool isFiniteReading(float value) {
  return !isnan(value) && !isinf(value);
}

static inline String voltageWarningLabel(float voltage) {
  if (!isFiniteReading(voltage)) {
    return "unknown";
  }
  if (voltage < 207.0f) {
    return "under_voltage_brownout";
  }
  if (voltage > 253.0f) {
    return "over_voltage_surge";
  }
  return "normal";
}

static inline bool isPlausiblePzemReading(float voltage,
                                          float current,
                                          float power,
                                          float energyKwh,
                                          float frequency,
                                          float powerFactor) {
  return isFiniteReading(voltage) && voltage >= 80.0f && voltage <= 260.0f &&
         isFiniteReading(current) && current >= 0.0f && current <= 100.0f &&
         isFiniteReading(power) && power >= 0.0f && power <= 25000.0f &&
         isFiniteReading(energyKwh) && energyKwh >= 0.0f && energyKwh <= 1000000.0f &&
         isFiniteReading(frequency) && frequency >= 45.0f && frequency <= 65.0f &&
         isFiniteReading(powerFactor) && powerFactor >= 0.0f && powerFactor <= 1.0f;
}

static inline String compactText(String value) {
  value.toLowerCase();
  String out;
  out.reserve(value.length());
  for (size_t i = 0; i < value.length(); i++) {
    const char c = value[i];
    if (isalnum(static_cast<unsigned char>(c))) {
      out += static_cast<char>(tolower(static_cast<unsigned char>(c)));
    }
  }
  return out;
}

static inline String canonicalUtility(String value) {
  value = compactText(value);
  if (value == "light" || value == "lights") return "lights";
  if (value == "outlet" || value == "outlets") return "outlets";
  if (value == "ac" || value == "aircon" || value == "airconditioner" ||
      value == "airconditioners" || value == "airconditioning") {
    return "ac";
  }
  if (value == "all" || value.isEmpty()) return "all";
  return value;
}

static inline bool utilityMatches(const String& expected, const String& actual) {
  const String normalizedExpected = canonicalUtility(String(expected));
  if (normalizedExpected == "all") return true;
  return normalizedExpected == canonicalUtility(String(actual));
}

static inline bool buildingMatches(const String& expected, const String& actual) {
  return compactText(String(expected)) == compactText(String(actual));
}

static inline String dayLabelFromWeekday(int weekday) {
  switch (weekday) {
    case 0: return "Sun";
    case 1: return "Mon";
    case 2: return "Tue";
    case 3: return "Wed";
    case 4: return "Thu";
    case 5: return "Fri";
    case 6: return "Sat";
    default: return "Mon";
  }
}

static inline String previousDayLabel(const String& day) {
  if (day == "Mon") return "Sun";
  if (day == "Tue") return "Mon";
  if (day == "Wed") return "Tue";
  if (day == "Thu") return "Wed";
  if (day == "Fri") return "Thu";
  if (day == "Sat") return "Fri";
  if (day == "Sun") return "Sat";
  return "Sun";
}

static inline int parseMinutes(const String& value) {
  const int colon = value.indexOf(':');
  if (colon < 0) return -1;

  const int hour = value.substring(0, colon).toInt();
  const int minute = value.substring(colon + 1).toInt();
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return -1;
  return hour * 60 + minute;
}

static inline int32_t parseTimezoneOffsetMinutes(String value) {
  value.trim();
  value.replace("\"", "");
  const String lowered = compactText(value);

  if (lowered.isEmpty() || lowered.indexOf("asiamanila") >= 0 || lowered.indexOf("philippines") >= 0) {
    return 8 * 60;
  }

  if (lowered.indexOf("utc") >= 0 || lowered.indexOf("gmt") >= 0) {
    int signIndex = value.indexOf('+');
    int sign = 1;
    if (signIndex < 0) {
      signIndex = value.indexOf('-');
      sign = -1;
    }

    if (signIndex >= 0) {
      String hoursPart = value.substring(signIndex + 1);
      hoursPart.trim();
      hoursPart.replace("h", "");
      hoursPart.replace("H", "");
      const int hours = hoursPart.toInt();
      if (hours > 0 || hoursPart == "0") {
        return sign * hours * 60;
      }
    }

    return 0;
  }

  return 8 * 60;
}

static inline ScheduleClock getScheduleClock() {
  time_t now = time(nullptr);
  if (now <= 1700000000) {
    now = (time_t)(nowMs() / 1000ULL);
  }

  const time_t adjusted = now + (time_t)(scheduleTimezoneOffsetMinutes * 60L);
  struct tm tm;
  gmtime_r(&adjusted, &tm);

  ScheduleClock clock;
  clock.day = dayLabelFromWeekday(tm.tm_wday);
  clock.minutes = tm.tm_hour * 60 + tm.tm_min;
  return clock;
}

static inline bool scheduleHasDay(JsonVariant daysValue, const String& day) {
  const String target = compactText(String(day));

  if (daysValue.is<JsonArray>()) {
    JsonArray daysArray = daysValue.as<JsonArray>();
    for (JsonVariant value : daysArray) {
      const char* raw = value.as<const char*>();
      if (raw != nullptr && compactText(String(raw)) == target) {
        return true;
      }
    }
    return false;
  }

  if (daysValue.is<JsonObject>()) {
    JsonObject daysObject = daysValue.as<JsonObject>();
    for (JsonPair pair : daysObject) {
      const char* raw = pair.value().as<const char*>();
      if (raw != nullptr && compactText(String(raw)) == target) {
        return true;
      }
    }
    return false;
  }

  const char* raw = daysValue.as<const char*>();
  return raw != nullptr && compactText(String(raw)) == target;
}

static inline String automationActionFor(JsonObject schedule, const ScheduleClock& clock) {
  const String onTime = String(schedule["onTime"] | "08:00");
  const String offTime = String(schedule["offTime"] | "18:00");
  const int onMinutes = parseMinutes(onTime);
  const int offMinutes = parseMinutes(offTime);
  if (onMinutes < 0 || offMinutes < 0) return "";

  const JsonVariant daysValue = schedule["days"];
  const bool activeDay = scheduleHasDay(daysValue, clock.day);
  const bool previousDay = scheduleHasDay(daysValue, previousDayLabel(clock.day));

  if (activeDay && clock.minutes == onMinutes) {
    return "on";
  }

  if (clock.minutes != offMinutes) {
    return "";
  }

  if (onMinutes > offMinutes) {
    return previousDay ? "off" : "";
  }

  return activeDay ? "off" : "";
}

static inline bool scheduleTargetsThisDevice(JsonObject schedule,
                                            const String& deviceId,
                                            const String& building,
                                            const String& utility) {
  const String scope = String(schedule["scope"] | "global");
  const String target = String(schedule["target"] | "all");
  const String scheduleUtility = String(schedule["utility"] | "All");

  if (scope == "global") {
    return utilityMatches(scheduleUtility, utility);
  }
  if (scope == "building") {
    return buildingMatches(target, building) && utilityMatches(scheduleUtility, utility);
  }
  if (scope == "utility") {
    return utilityMatches(target, utility);
  }
  if (scope == "device") {
    return compactText(target) == compactText(deviceId);
  }
  return false;
}

static inline bool parseBoolean(JsonVariant value) {
  if (value.is<bool>()) {
    return value.as<bool>();
  }

  if (value.is<int>() || value.is<long>() || value.is<float>() || value.is<double>()) {
    return value.as<double>() != 0.0;
  }

  const char* raw = value.as<const char*>();
  if (raw == nullptr) {
    return false;
  }

  String normalized(raw);
  normalized.trim();
  normalized.toLowerCase();
  return normalized == "true" || normalized == "1" || normalized == "yes" || normalized == "on";
}

static inline void mirrorRelayToBuilding(const String& building,
                                         const String& floor,
                                         bool relay) {
  if (building.isEmpty() || floor.isEmpty()) return;

  DynamicJsonDocument mirrorDoc(64);
  mirrorDoc["relay"] = relay;

  String payload;
  serializeJson(mirrorDoc, payload);

  int code = 0;
  firebasePatch(String("/buildings/") + building + "/floorData/" + floor + "/devices/" + DEVICE_ID + ".json",
                payload,
                code);
}

static inline void refreshScheduleTimezone(bool force = false) {
  const uint32_t now = millis();
  if (!force && lastTimezoneRefreshMs != 0 && (now - lastTimezoneRefreshMs) < TIMEZONE_REFRESH_MS) {
    return;
  }

  lastTimezoneRefreshMs = now;

  String body;
  int code = 0;
  if (!firebaseGet(String("/settings/timezone.json"), body, code) || code != 200 || body == "null") {
    return;
  }

  scheduleTimezoneOffsetMinutes = parseTimezoneOffsetMinutes(body);
}

static inline bool applyAutomationIfNeeded(const String& deviceId,
                                          const String& building,
                                          const String& utility,
                                          bool currentRelay,
                                          bool& desiredRelay) {
  const uint32_t now = millis();
  if (lastAutomationPollMs != 0 && (now - lastAutomationPollMs) < AUTOMATION_POLL_MS) {
    return false;
  }
  lastAutomationPollMs = now;

  refreshScheduleTimezone(false);

  String body;
  int code = 0;
  if (!firebaseGet(String("/automations.json"), body, code) || code != 200 || body == "null") {
    return false;
  }

  DynamicJsonDocument doc(8192);
  const DeserializationError err = deserializeJson(doc, body);
  if (err) {
    Serial.print("[Automation] JSON parse error: ");
    Serial.println(err.c_str());
    return false;
  }

  const ScheduleClock clock = getScheduleClock();
  bool matched = false;
  desiredRelay = currentRelay;

  JsonObject root = doc.as<JsonObject>();
  for (JsonPair pair : root) {
    JsonObject schedule = pair.value().as<JsonObject>();
    if (schedule.isNull()) continue;
    const bool enabled = schedule.containsKey("enabled")
        ? parseBoolean(schedule["enabled"])
        : true;
    if (!enabled) continue;
    if (!scheduleTargetsThisDevice(schedule, deviceId, building, utility)) continue;

    const String action = automationActionFor(schedule, clock);
    if (action.isEmpty()) continue;

    matched = true;
    desiredRelay = action == "on";
  }

  return matched;
}

static inline uint8_t relayPinLevel(bool on) {
  if (SSR_ACTIVE_HIGH) {
    return on ? HIGH : LOW;
  }
  return on ? LOW : HIGH;
}

void setRelay(bool on) {
  relayState = on;
  digitalWrite(SSR_PIN, relayPinLevel(relayState));
}

void initPzemUart() {
#if defined(ESP32)
  Serial2.begin(PZEM_UART_BAUD, SERIAL_8N1, PZEM_RX_PIN, PZEM_TX_PIN);
#else
  Serial2.begin(PZEM_UART_BAUD);
#endif
  delay(150);
}

void probePzemLink(bool force) {
  const uint32_t now = millis();
  if (!force && (now - lastPzemProbeMs) < PZEM_PROBE_RETRY_MS) {
    return;
  }

  lastPzemProbeMs = now;

  Serial.println("[PZEM] Probing PZEM link...");
  const float voltage = pzem.voltage();
  const float current = pzem.current();
  const float power = pzem.power();
  const float energyKwh = pzem.energy();
  const float frequency = pzem.frequency();
  const float powerFactor = pzem.pf();
  const String voltageWarning = voltageWarningLabel(voltage);

  pzemReady = isPlausiblePzemReading(
      voltage, current, power, energyKwh, frequency, powerFactor);
  
  if (pzemReady) {
    pzemAddress = pzem.readAddress();
    Serial.print("[PZEM] Link ready on 0x");
    if (pzemAddress < 0x10) {
      Serial.print('0');
    }
    Serial.println(pzemAddress, HEX);
    Serial.print("[PZEM] Initial reading - V=");
    Serial.print(voltage, 1);
    Serial.print(" I=");
    Serial.print(current, 2);
    Serial.print(" P=");
    Serial.print(power, 1);
    Serial.print(" kWh=");
    Serial.print(energyKwh, 4);
    Serial.print(" Hz=");
    Serial.print(frequency, 1);
    Serial.print(" PF=");
    Serial.println(powerFactor, 2);
    if (voltageWarning == "under_voltage_brownout") {
      Serial.println("[PZEM] Voltage warning: Under-voltage (Brownout) Below 207V");
    } else if (voltageWarning == "over_voltage_surge") {
      Serial.println("[PZEM] Voltage warning: Over-voltage (Surge) Above 253V");
    }
    Serial.println();
  } else {
    Serial.println("[PZEM] Probe failed (readings are missing or out of range)");
  }
}

void connectWiFi() {
  if (WiFi.status() == WL_CONNECTED) return;

  Serial.print("[WiFi] Connecting to ");
  Serial.println(WIFI_SSID);

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  const uint32_t start = millis();
  while (WiFi.status() != WL_CONNECTED && (millis() - start) < 20000) {
    delay(400);
    Serial.print('.');
  }

  if (WiFi.status() == WL_CONNECTED) {
    Serial.println();
    Serial.print("[WiFi] Connected. IP: ");
    Serial.println(WiFi.localIP());
  } else {
    Serial.println();
    Serial.println("[WiFi] Connection timeout.");
  }
}

void syncTimeIfPossible() {
  configTime(0, 0, "pool.ntp.org", "time.google.com", "time.windows.com");

  for (int i = 0; i < 20; i++) {
    time_t now = time(nullptr);
    if (now > 1700000000) {
      bootEpochMs = (uint64_t)now * 1000ULL;
      bootMillisAtSync = millis();
      Serial.println("[NTP] Time synced.");
      return;
    }
    delay(250);
  }

  Serial.println("[NTP] Time not synced. Falling back to millis().");
}

uint64_t nowMs() {
  time_t now = time(nullptr);
  if (now > 1700000000) {
    return (uint64_t)now * 1000ULL;
  }

  if (bootEpochMs > 0) {
    return bootEpochMs + (uint64_t)(millis() - bootMillisAtSync);
  }

  return (uint64_t)millis();
}

bool firebaseGet(const String& path, String& responseBody, int& statusCode) {
  if (WiFi.status() != WL_CONNECTED) return false;

  WiFiClientSecure client;
  client.setInsecure();
  client.setConnectionTimeout(5000);  // 5 sec timeout

  HTTPClient https;
  https.setConnectTimeout(5000);
  https.setTimeout(5000);
  const String url = String(FIREBASE_DB_URL) + path;

  if (!https.begin(client, url)) {
    return false;
  }

  statusCode = https.GET();
  responseBody = https.getString();
  https.end();
  return statusCode > 0;
}

bool firebasePatch(const String& path, const String& json, int& statusCode) {
  if (WiFi.status() != WL_CONNECTED) {
    return false;
  }

  WiFiClientSecure client;
  client.setInsecure();
  client.setConnectionTimeout(5000);  // 5 sec timeout

  HTTPClient https;
  https.setConnectTimeout(5000);
  https.setTimeout(5000);
  const String url = String(FIREBASE_DB_URL) + path;

  if (!https.begin(client, url)) {
    return false;
  }

  https.addHeader("Content-Type", "application/json");
  statusCode = https.sendRequest("PATCH", json);
  https.getString();
  https.end();
  return statusCode > 0;
}

void pollRelayAndAssignment() {
  String body;
  int code = 0;

  const String path = String("/devices/") + DEVICE_ID + ".json";
  if (!firebaseGet(path, body, code)) {
    return;
  }

  if (code != 200 || body == "null") {
    return;
  }

  DynamicJsonDocument doc(1024);
  const DeserializationError err = deserializeJson(doc, body);
  if (err) {
    Serial.print("[Firebase] JSON parse error: ");
    Serial.println(err.c_str());
    return;
  }

  bool cloudRelay = relayState;
  if (doc.containsKey("relay")) {
    cloudRelay = doc["relay"].as<bool>();
  }

  const String building = doc.containsKey("building") ? String(doc["building"].as<const char*>()) : "";
  const String floor = doc.containsKey("floor") ? String(doc["floor"].as<const char*>()) : "";
  const String utility = doc.containsKey("utility") ? String(doc["utility"].as<const char*>()) : "";

  bool desiredRelay = cloudRelay;
  const bool automationMatched = applyAutomationIfNeeded(
      String(DEVICE_ID), building, utility, cloudRelay, desiredRelay);

  if (desiredRelay != relayState) {
    setRelay(desiredRelay);
    if (automationMatched) {
      Serial.print("[Automation] Set from schedule: ");
      Serial.println(desiredRelay ? "ON" : "OFF");
    } else {
      Serial.print("[Relay] Set from cloud: ");
      Serial.println(desiredRelay ? "ON" : "OFF");
    }

    mirrorRelayToBuilding(building, floor, desiredRelay);

    // Push telemetry immediately so the cloud reflects the updated relay
    // state and (when meter is after the relay) we get readings faster.
    lastTelemetryPushMs = millis();
    pushTelemetry();
  }
}

void pushTelemetry() {
  // Check WiFi before doing any work
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[Telemetry] Skipping push: WiFi not connected");
    return;
  }

  if (!pzemReady) {
    probePzemLink(false);
  }

  const float voltage = pzem.voltage();
  const float current = pzem.current();
  const float power = pzem.power();
  const float energyKwh = pzem.energy();
  const float frequency = pzem.frequency();
  const float powerFactor = pzem.pf();
  const String voltageWarning = voltageWarningLabel(voltage);
  const bool pzemOk = isPlausiblePzemReading(
      voltage, current, power, energyKwh, frequency, powerFactor);

  if (pzemOk) {
    pzemAddress = pzem.readAddress();
  }

  const uint64_t t = nowMs();
  const String status = pzemOk ? "online" : "offline";

  Serial.print("[PZEM] V=");
  Serial.print(pzemOk ? String(roundTo(voltage, 1)) : String("nan"));
  Serial.print(" I=");
  Serial.print(pzemOk ? String(roundTo(current, 2)) : String("nan"));
  Serial.print(" P=");
  Serial.print(pzemOk ? String(roundTo(power, 1)) : String("nan"));
  Serial.print(" kWh=");
  Serial.print(pzemOk ? String(roundTo(energyKwh, 4)) : String("nan"));
  Serial.print(" Hz=");
  Serial.print(pzemOk ? String(roundTo(frequency, 1)) : String("nan"));
  Serial.print(" PF=");
  Serial.print(pzemOk ? String(roundTo(powerFactor, 2)) : String("nan"));
  Serial.print(" relay=");
  Serial.println(relayState ? "ON" : "OFF");
  if (voltageWarning == "under_voltage_brownout") {
    Serial.println("[PZEM] Voltage warning: Under-voltage (Brownout) Below 207V");
  } else if (voltageWarning == "over_voltage_surge") {
    Serial.println("[PZEM] Voltage warning: Over-voltage (Surge) Above 253V");
  }

  if (!pzemOk) {
    pzemReady = false;
  }

  DynamicJsonDocument doc(512);
  doc["status"] = status;
  doc["relay"] = relayState;
  doc["voltage_warning"] = voltageWarning;
  doc["last_updated"] = t;
  doc["last_seen"] = pzemOk ? t : (t > 300000 ? t - 300000 : 0);

  if (pzemOk) {
    doc["voltage"] = roundTo(voltage, 1);
    doc["current"] = roundTo(current, 2);
    doc["power"] = roundTo(power, 1);
    doc["kwh"] = roundTo(energyKwh, 4);
    doc["powerFactor"] = roundTo(powerFactor, 2);
    doc["frequency"] = roundTo(frequency, 1);
  } else {
    doc["voltage"] = nullptr;
    doc["current"] = nullptr;
    doc["power"] = nullptr;
    doc["powerFactor"] = nullptr;
    doc["frequency"] = nullptr;
  }

  String payload;
  serializeJson(doc, payload);

  int code = 0;
  const bool ok = firebasePatch(String("/devices/") + DEVICE_ID + ".json", payload, code);
  
  if (!ok) {
    return;
  }
  
  if (code != 200 && code != 204) {
    return;
  }
  
  // Compute delta from PZEM energy meter and write raw history entry (includes cost)
  if (pzemOk) {
    float delta = 0.0f;
    if (lastReportedEnergyKwh < 0.0f) {
      lastReportedEnergyKwh = energyKwh; // initialize on first valid reading
    } else {
      delta = energyKwh - lastReportedEnergyKwh;
      if (delta < 0.0f) {
        // meter may have reset — use current reading as delta
        delta = energyKwh;
      }
    }

    // Only write if delta is meaningful (avoid noise)
    if (delta >= 0.000001f) {
      // Fetch rate (best-effort)
      String rateBody;
      int rateCode = 0;
      double rate = 11.5;
      if (firebaseGet(String("/settings/electricityRate.json"), rateBody, rateCode) && rateCode == 200 && rateBody != "null") {
        rate = atof(rateBody.c_str());
      }

      // Write a single daily raw summary (overwrite, do not append incremental entries)
      DynamicJsonDocument hdoc(384);
      hdoc["deviceId"] = DEVICE_ID;
      // cumulative total from the meter (not delta)
      hdoc["kwh_total"] = roundTo(energyKwh, 4);
      hdoc["cost_total"] = roundTo((float)(energyKwh * rate), 4);
      hdoc["ts"] = (uint64_t)t; // epoch ms

      // Build daily key YYYY-MM-DD
      time_t secs = (time_t)(t / 1000ULL);
      struct tm tm;
      localtime_r(&secs, &tm);
      char daybuf[16];
      snprintf(daybuf, sizeof(daybuf), "%04d-%02d-%02d", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday);

      String hpayload;
      serializeJson(hdoc, hpayload);

      int hcode = 0;
      // Overwrite daily raw summary: history/raw/<YYYY-MM-DD>_<deviceId>.json
      String hpath = String("/history/raw/") + String(daybuf) + "_" + DEVICE_ID + ".json";
      const bool hok = firebasePatch(hpath, hpayload, hcode);
      if (!hok) {
        Serial.print("[History] Failed to write daily raw summary (HTTP ");
        Serial.print(hcode);
        Serial.println(")");
      } else {
        Serial.print("[History] Daily raw summary written (HTTP ");
        Serial.print(hcode);
        Serial.println(")");
      }

      lastReportedEnergyKwh = energyKwh;
    }
  }
}

void setup() {
  Serial.begin(115200);
  delay(200);
  Serial.println("[System] Booting...");

  pinMode(SSR_PIN, OUTPUT);
  setRelay(false);  // Safe default: OFF at boot

  initPzemUart();
  probePzemLink(true);

  connectWiFi();
  if (WiFi.status() == WL_CONNECTED) {
    syncTimeIfPossible();
    refreshScheduleTimezone(true);
  }

  Serial.println("[System] SmartPowerSwitch firmware started.");
}

void loop() {
  const uint32_t now = millis();

  // Track WiFi status changes
  wl_status_t currentWifiStatus = WiFi.status();
  if (currentWifiStatus != lastWifiStatus) {
    lastWifiStatus = currentWifiStatus;
    Serial.print("[WiFi] Status changed to: ");
    switch (currentWifiStatus) {
      case WL_DISCONNECTED:
        Serial.println("DISCONNECTED");
        break;
      case WL_CONNECTED:
        Serial.print("CONNECTED (IP: ");
        Serial.print(WiFi.localIP());
        Serial.println(")");
        syncTimeIfPossible();
        refreshScheduleTimezone(true);
        // Force telemetry push on reconnect
        lastTelemetryPushMs = millis();
        break;
      case WL_NO_SSID_AVAIL:
        Serial.println("NO_SSID_AVAILABLE");
        break;
      case WL_CONNECT_FAILED:
        Serial.println("CONNECT_FAILED");
        break;
      case WL_IDLE_STATUS:
        Serial.println("IDLE");
        break;
      default:
        Serial.println(currentWifiStatus);
        break;
    }
  }

  if (WiFi.status() != WL_CONNECTED) {
    if (now - lastWifiRetryMs >= WIFI_RETRY_MS) {
      lastWifiRetryMs = now;
      connectWiFi();
      if (WiFi.status() == WL_CONNECTED) {
        syncTimeIfPossible();
        refreshScheduleTimezone(true);
      }
    }
    delay(20);
    return;
  }

  // Probe PZEM more frequently if not ready
  if (!pzemReady) {
    probePzemLink(false);  // Will retry every PZEM_PROBE_RETRY_MS if not ready
  }

  if (now - lastRelayPollMs >= RELAY_POLL_MS) {
    lastRelayPollMs = now;
    pollRelayAndAssignment();
  }

  if (now - lastTelemetryPushMs >= TELEMETRY_PUSH_MS) {
    lastTelemetryPushMs = now;
    pushTelemetry();
  }

  delay(10);
}
