/*
  SmartPowerSwitch ESP32 Firmware (ID-only registration flow)
  VERSION: 2.0.0  (2026-10-11)

  CHANGELOG
  2.0.0  Commands and live readings are separate (master plan Phase 5):
         reads commands from /device_commands/<ID> (desiredRelay, commandId,
         wifiReset) and reports to /device_live/<ID> (telemetry,
         connectivity, state.reportedRelay + state.lastCommandId as the
         acknowledgement). No longer reads or writes /devices/<ID>, runs
         schedules itself (the server does) or mirrors the relay under
         /buildings. Needs the Phase 5 database rules.
         Also removed: the history/raw write and electricity-rate read after
         each push (the server computes history and cost).
  1.3.3  Reports the connected WiFi network (wifi_ssid, wifi_rssi) so the app
         can show it on the device page and disconnect it from there.
  1.3.2  Setup page moved to portal_html.h (fixes page not responding to taps:
         the IDE was inserting code into the page). Needs portal_html.h
         in the same folder as this sketch.
  1.3.1  Fixed setup page stuck on "Scanning": scan runs before the hotspot
         starts; rescans are shorter; page requests time out instead of hanging.
  1.3.0  Setup hotspot only on first setup or when the system sends
         /devices/<ID>/wifiReset = true. Network outages no longer reopen it.
  1.2.0  Setup hotspot is open (no password). Fixed network scan.
  1.1.1  Compile fix (forward declarations).
  1.1.0  WiFi setup page; WiFi saved in flash instead of hardcoded;
         hold BOOT 5 s to erase WiFi.
  1.0.0  Original firmware (hardcoded WiFi).

  What this sketch does:
  1) Connects to WiFi saved in flash (no hardcoded SSID/password).
     - First boot / no saved WiFi: opens setup hotspot "SmartSwitch-XXXX".
       Join it with a phone or laptop -> setup page opens -> pick network.
     - Saved WiFi down for 2 min: setup hotspot opens again while it keeps
       retrying the saved network in the background.
     - Hold BOOT (GPIO 0) for 5 s: erases saved WiFi and reboots into setup.
  2) Reads PZEM-004T V4.0 values (voltage/current/power/energy)
  3) Polls its commands from: /device_commands/<DEVICE_ID>
  4) Controls an SSR output pin
  5) Pushes readings to: /device_live/<DEVICE_ID>
     (telemetry, connectivity, state incl. the last command it carried out)

  Required Arduino libraries:
  - ArduinoJson (by Benoit Blanchon)
  - PZEM004Tv30 (PZEM-004T V4.0 library used in the video)
  - WebServer, DNSServer, Preferences (built into the ESP32 Arduino core)

  Board:
  - ESP32 Dev Module (or compatible ESP32)

  Wiring (example):
  - SSR IN  -> GPIO 26
  - PZEM TX -> ESP32 RX2 (GPIO 16)
  - PZEM RX -> ESP32 TX2 (GPIO 17)
  - Common GND

  IMPORTANT:
  - Register DEVICE_ID first in app Settings -> IoT Device Inventory.
  - This firmware assumes your Firebase rules allow an ID-registered,
    unauthenticated board to read /device_commands/<DEVICE_ID> (and clear its
    wifiReset) and to write /device_live/<DEVICE_ID>.
*/

#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <HardwareSerial.h>
#include <PZEM004Tv30.h>
#include <time.h>
#include <WebServer.h>
#include <DNSServer.h>
#include <Preferences.h>
#include <esp_wifi.h>
#include <vector>
#include <algorithm>
#include "portal_html.h"  // setup page (must be in the same folder)

// ===================== USER CONFIG =====================
// WiFi is NOT set here anymore — it is entered on the setup page and saved
// in flash (Preferences namespace "wifi").

// Setup hotspot is OPEN (no password). It only exists while the device has no
// working WiFi, and turns off as soon as it connects.
static const char* SETUP_AP_PASSWORD = nullptr;
static const uint8_t RESET_BTN_PIN = 0;                  // BOOT button
static const uint32_t RESET_HOLD_MS = 5000;              // hold to erase WiFi
static const uint32_t WIFI_CONNECT_TIMEOUT_MS = 20000;   // per connect attempt
// Setup hotspot only opens on first setup (nothing saved), when the system sends
// a disconnect (/device_commands/<DEVICE_ID>/wifiReset = true), or BOOT held 5 s.
// A network outage never reopens it — the device just keeps retrying.
static const uint32_t OFFLINE_PORTAL_AFTER_MS = 0;       // 0 = never reopen when offline
static const uint32_t SAVED_WIFI_RETRY_MS = 30000;       // retry saved WiFi while hotspot is open
static const uint32_t PORTAL_CLOSE_DELAY_MS = 10000;     // keep hotspot up after success so the page can show it

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
static const uint32_t WIFI_RETRY_MS = 10000;
static const uint32_t PZEM_UART_BAUD = 9600;
static const uint32_t PZEM_PROBE_RETRY_MS = 15000;

// =======================================================

PZEM004Tv30 pzem(Serial2, PZEM_RX_PIN, PZEM_TX_PIN);

uint8_t pzemAddress = 0xF8;  // Factory default address for v4.0 modules

bool relayState = false;
// Last command carried out (acknowledged in device_live/<ID>/state).
String lastCommandId = "";
uint64_t lastCommandAtMs = 0;
bool pzemReady = false;
// Track last seen energy reading so we can write per-interval history deltas

uint32_t lastRelayPollMs = 0;
uint32_t lastTelemetryPushMs = 0;
uint32_t lastWifiRetryMs = 0;
uint32_t lastPzemProbeMs = 0;
wl_status_t lastWifiStatus = WL_DISCONNECTED;  // Track WiFi status changes

uint64_t bootEpochMs = 0;
uint32_t bootMillisAtSync = 0;

// ===================== FORWARD DECLARATIONS =====================
// Functions used before they are defined. Declared by hand because the
// big setup-page string below stops the Arduino IDE from generating these.
uint64_t nowMs();
void syncTimeIfPossible();
bool firebaseGet(const String& path, String& responseBody, int& statusCode);
bool firebasePatch(const String& path, const String& json, int& statusCode);
void pushTelemetry();
void clearWifiCredentials();

// ===================== WIFI SETUP PORTAL STATE =====================
WebServer server(80);
DNSServer dnsServer;
Preferences prefs;
const IPAddress PORTAL_IP(192, 168, 4, 1);

String savedSsid;
String savedPass;
String apName;
String scanCache;
bool portalActive = false;

enum ConnectState : uint8_t { CONNECT_IDLE, CONNECT_RUNNING, CONNECT_OK, CONNECT_FAILED };
ConnectState connectState = CONNECT_IDLE;
String pendingSsid;
String pendingPass;
String connectFailReason;
uint32_t connectStartMs = 0;
uint32_t portalCloseAtMs = 0;
uint32_t offlineSinceMs = 0;
uint32_t lastSavedRetryMs = 0;
volatile uint8_t lastDisconnectReason = 0;
bool scanInProgress = false;
uint8_t scanFailCount = 0;
uint32_t lastScanMs = 0;

// Setup page HTML lives in portal_html.h (see note there).

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

// The app/system asked this device to leave its WiFi:
// clear the flag in Firebase first (so it doesn't loop), then erase the saved
// WiFi and reboot. With nothing saved, the open setup hotspot comes up.
void handleRemoteWifiReset() {
  Serial.println("[WiFi] Disconnect requested by the system");

  // Clear the command first so it doesn't loop (null removes the key).
  int code = 0;
  const bool ok = firebasePatch(String("/device_commands/") + DEVICE_ID + ".json",
                                "{\"wifiReset\":null}", code);
  if (!ok || (code != 200 && code != 204)) {
    Serial.println("[WiFi] Could not clear wifiReset command, will retry");
    return;
  }

  // Report going offline with the relay OFF (it is OFF after the reboot).
  DynamicJsonDocument doc(256);
  doc["connectivity"]["status"] = "offline";
  doc["connectivity"]["wifiSsid"] = nullptr;
  doc["connectivity"]["wifiRssi"] = nullptr;
  doc["state"]["reportedRelay"] = false;
  String payload;
  serializeJson(doc, payload);
  firebasePatch(String("/device_live/") + DEVICE_ID + ".json", payload, code);

  clearWifiCredentials();
  WiFi.disconnect(true, true);
  delay(300);
  ESP.restart();
}

// Reads /device_commands/<ID>: { desiredRelay, commandId, issuedAt, wifiReset }.
// Applies the desired relay state and acknowledges the command ID in the
// next device_live push. Schedules are run by the server, not the board.
void pollCommands() {
  String body;
  int code = 0;

  const String path = String("/device_commands/") + DEVICE_ID + ".json";
  if (!firebaseGet(path, body, code)) {
    return;
  }

  if (code != 200 || body == "null") {
    return;  // no command yet: keep the current relay state
  }

  DynamicJsonDocument doc(512);
  const DeserializationError err = deserializeJson(doc, body);
  if (err) {
    Serial.print("[Firebase] JSON parse error: ");
    Serial.println(err.c_str());
    return;
  }

  if (doc.containsKey("wifiReset") && parseBoolean(doc["wifiReset"])) {
    handleRemoteWifiReset();
    return;
  }

  if (!doc.containsKey("desiredRelay")) {
    return;
  }
  const bool desiredRelay = parseBoolean(doc["desiredRelay"]);
  const String commandId = doc.containsKey("commandId")
      ? String(doc["commandId"].as<const char*>())
      : String("");
  const bool newCommand = commandId != lastCommandId;

  if (desiredRelay != relayState) {
    setRelay(desiredRelay);
    Serial.print("[Relay] Set from command ");
    Serial.print(commandId);
    Serial.print(": ");
    Serial.println(desiredRelay ? "ON" : "OFF");
  }

  if (newCommand) {
    lastCommandId = commandId;
    lastCommandAtMs = nowMs();
    // Acknowledge right away (and report the relay) instead of waiting for
    // the next scheduled push.
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
  const bool pzemOk = isPlausiblePzemReading(
      voltage, current, power, energyKwh, frequency, powerFactor);
  // Only a valid reading can trigger a brownout / surge warning.
  const String voltageWarning =
      pzemOk ? voltageWarningLabel(voltage) : String("unknown");

  if (pzemOk) {
    pzemAddress = pzem.readAddress();
  }

  const uint64_t t = nowMs();
  // The board is up either way (it is reporting and taking commands); a
  // meter that isn't answering is reported as meter_error, not offline.
  const String status = pzemOk ? "online" : "meter_error";

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

  // /device_live/<ID>: { telemetry, connectivity, state }. Each group is
  // replaced as a whole by the PATCH.
  DynamicJsonDocument doc(768);
  JsonObject telemetry = doc.createNestedObject("telemetry");
  JsonObject connectivity = doc.createNestedObject("connectivity");
  JsonObject state = doc.createNestedObject("state");

  if (pzemOk) {
    telemetry["voltage"] = roundTo(voltage, 1);
    telemetry["current"] = roundTo(current, 2);
    telemetry["power"] = roundTo(power, 1);
    telemetry["cumulativeKwh"] = roundTo(energyKwh, 4);
    telemetry["powerFactor"] = roundTo(powerFactor, 2);
    telemetry["frequency"] = roundTo(frequency, 1);
  }
  telemetry["voltageWarning"] = voltageWarning;

  connectivity["status"] = status;
  connectivity["lastUpdatedAt"] = t;
  connectivity["lastSeenAt"] = t;
  // Network the device is on, shown on the app's device page.
  connectivity["wifiSsid"] = WiFi.SSID();
  connectivity["wifiRssi"] = WiFi.RSSI();

  state["reportedRelay"] = relayState;
  if (lastCommandId.length() > 0) {
    state["lastCommandId"] = lastCommandId;
    state["lastCommandAt"] = lastCommandAtMs;
  }

  String payload;
  serializeJson(doc, payload);

  int code = 0;
  const bool ok = firebasePatch(String("/device_live/") + DEVICE_ID + ".json", payload, code);
  
  if (!ok) {
    return;
  }
  
  if (code != 200 && code != 204) {
    return;
  }
  
}

// ===================== WIFI SETUP PORTAL =====================

void loadWifiCredentials() {
  prefs.begin("wifi", true);
  savedSsid = prefs.getString("ssid", "");
  savedPass = prefs.getString("pass", "");
  prefs.end();
}

void saveWifiCredentials(const String& ssid, const String& pass) {
  prefs.begin("wifi", false);
  prefs.putString("ssid", ssid);
  prefs.putString("pass", pass);
  prefs.end();
  savedSsid = ssid;
  savedPass = pass;
}

void clearWifiCredentials() {
  prefs.begin("wifi", false);
  prefs.clear();
  prefs.end();
  savedSsid = "";
  savedPass = "";
}

void beginStation(const String& ssid, const String& pass) {
  WiFi.begin(ssid.c_str(), pass.length() ? pass.c_str() : nullptr);
}

// Hold BOOT for RESET_HOLD_MS -> erase saved WiFi and reboot into setup mode.
void checkResetButton() {
  static uint32_t pressedSince = 0;
  if (digitalRead(RESET_BTN_PIN) == LOW) {
    if (pressedSince == 0) {
      pressedSince = millis();
      Serial.println("[Setup] BOOT pressed - hold 5 s to erase WiFi");
    } else if (millis() - pressedSince >= RESET_HOLD_MS) {
      Serial.println("[Setup] WiFi erased. Restarting into setup mode...");
      clearWifiCredentials();
      WiFi.disconnect(true, true);
      delay(300);
      ESP.restart();
    }
  } else {
    pressedSince = 0;
  }
}

// Runs whenever the device gets onto the network (boot, reconnect, after setup).
void onWifiUp() {
  Serial.print("[WiFi] Connected to ");
  Serial.print(WiFi.SSID());
  Serial.print(". IP: ");
  Serial.println(WiFi.localIP());
  syncTimeIfPossible();
  lastTelemetryPushMs = millis();
  lastWifiStatus = WiFi.status();
  offlineSinceMs = 0;
}

bool connectSavedWifi(uint32_t timeoutMs) {
  if (savedSsid.isEmpty()) return false;

  Serial.print("[WiFi] Connecting to saved network ");
  Serial.println(savedSsid);

  WiFi.mode(WIFI_STA);
  beginStation(savedSsid, savedPass);

  const uint32_t start = millis();
  while (WiFi.status() != WL_CONNECTED && (millis() - start) < timeoutMs) {
    delay(400);
    Serial.print('.');
    checkResetButton();
  }
  Serial.println();
  return WiFi.status() == WL_CONNECTED;
}

static bool isAuthFailure(uint8_t reason) {
  return reason == WIFI_REASON_AUTH_EXPIRE ||
         reason == WIFI_REASON_4WAY_HANDSHAKE_TIMEOUT ||
         reason == WIFI_REASON_AUTH_FAIL ||
         reason == WIFI_REASON_HANDSHAKE_TIMEOUT;
}

void sendJson(int code, const String& body) {
  server.sendHeader("Cache-Control", "no-store");
  server.send(code, "application/json", body);
}

// Any unknown URL (Android/iOS/Windows connectivity checks) -> setup page.
// This is what makes the phone pop up the "Sign in to network" page.
void redirectToPortal() {
  server.sendHeader("Location", String("http://") + PORTAL_IP.toString() + "/", true);
  server.send(302, "text/plain", "");
}

void handlePortalRoot() {
  if (server.hostHeader() != PORTAL_IP.toString()) {
    redirectToPortal();
    return;
  }
  String page = PORTAL_HTML;
  page.replace("{{ID}}", DEVICE_ID);
  page.replace("{{AP}}", apName);
  server.sendHeader("Cache-Control", "no-store");
  server.send(200, "text/html; charset=utf-8", page);
}

String scanResultsJson(int count) {
  std::vector<int> order;
  for (int i = 0; i < count; i++) order.push_back(i);
  std::sort(order.begin(), order.end(), [](int a, int b) { return WiFi.RSSI(a) > WiFi.RSSI(b); });

  DynamicJsonDocument doc(4096);
  JsonArray list = doc.createNestedArray("networks");
  std::vector<String> seen;

  for (int i : order) {
    const String ssid = WiFi.SSID(i);
    if (ssid.isEmpty()) continue;  // hidden networks -> "Enter a hidden network"
    if (std::find(seen.begin(), seen.end(), ssid) != seen.end()) continue;  // same SSID, weaker AP
    seen.push_back(ssid);
    if (list.size() >= 20) break;

    const wifi_auth_mode_t auth = WiFi.encryptionType(i);
    JsonObject net = list.createNestedObject();
    net["ssid"] = ssid;
    net["rssi"] = WiFi.RSSI(i);
    net["secure"] = auth != WIFI_AUTH_OPEN;
    net["ent"] = auth == WIFI_AUTH_WPA2_ENTERPRISE;  // needs username + password: not supported
  }

  String out;
  serializeJson(doc, out);
  return out;
}

// Blocking scan done BEFORE the hotspot starts. No phone is connected yet, so
// channel-hopping can't drop anyone, and the list is ready when the page opens.
void scanBeforeHotspot() {
  WiFi.mode(WIFI_STA);
  WiFi.disconnect(false);
  delay(100);

  Serial.println("[Setup] Scanning for networks...");
  const int16_t n = WiFi.scanNetworks(false, false, false, 300);  // blocking, ~4 s
  if (n >= 0) {
    scanCache = scanResultsJson(n);
    Serial.print("[Setup] Scan found ");
    Serial.print(n);
    Serial.println(" networks");
  } else {
    scanCache = "";
    Serial.println("[Setup] Scan failed (will retry from the page)");
  }
  WiFi.scanDelete();
  lastScanMs = millis();
}

// Async rescan while the hotspot is up. Short per-channel time (120 ms) so the
// hotspot is only off-channel briefly and the phone stays connected.
bool startScan() {
  if (connectState == CONNECT_RUNNING) return false;
  if (scanInProgress) return true;

  if (WiFi.status() != WL_CONNECTED) {
    WiFi.disconnect(false);  // station only; hotspot stays up
    delay(50);
  }
  WiFi.scanDelete();

  const int16_t r = WiFi.scanNetworks(true, false, false, 120);
  scanInProgress = (r == WIFI_SCAN_RUNNING) || (r >= 0);
  Serial.println(scanInProgress ? "[Setup] Rescanning..." : "[Setup] Scan could not start");
  return scanInProgress;
}

// Picks up the result of a finished async scan. Called from the loop and /scan.
void collectScanResult() {
  if (!scanInProgress) return;

  const int16_t n = WiFi.scanComplete();
  if (n == WIFI_SCAN_RUNNING) return;

  scanInProgress = false;
  lastScanMs = millis();

  if (n >= 0) {
    scanCache = scanResultsJson(n);
    scanFailCount = 0;
    Serial.print("[Setup] Scan found ");
    Serial.print(n);
    Serial.println(" networks");
  } else {
    Serial.println("[Setup] Scan failed");
    if (scanCache.isEmpty() && ++scanFailCount >= 3) {
      scanFailCount = 0;
      scanCache = "{\"networks\":[]}";  // page shows "No networks found" + Rescan
    }
  }
  WiFi.scanDelete();
}

// GET /scan            -> {"networks":[...]} or {"scanning":true} (page polls)
// GET /scan?refresh=1  -> starts a new scan
void handleScan() {
  collectScanResult();

  if (server.hasArg("refresh")) {
    scanCache = "";
    startScan();
    sendJson(200, "{\"scanning\":true}");
    return;
  }

  if (scanCache.isEmpty()) {
    if (!scanInProgress && !startScan() && ++scanFailCount >= 3) {
      scanFailCount = 0;
      scanCache = "{\"networks\":[]}";
      sendJson(200, scanCache);
      return;
    }
    sendJson(200, "{\"scanning\":true}");
    return;
  }

  sendJson(200, scanCache);
}

// POST /connect  ssid=...&pass=...
void handleConnect() {
  String ssid = server.arg("ssid");
  const String pass = server.arg("pass");
  ssid.trim();

  if (ssid.isEmpty() || ssid.length() > 32 || pass.length() > 63 ||
      (pass.length() > 0 && pass.length() < 8)) {
    sendJson(400, "{\"error\":\"invalid\"}");
    return;
  }

  pendingSsid = ssid;
  pendingPass = pass;
  connectFailReason = "";
  lastDisconnectReason = 0;
  connectState = CONNECT_RUNNING;
  connectStartMs = millis();

  sendJson(200, "{\"ok\":true}");

  Serial.print("[Setup] Trying ");
  Serial.println(pendingSsid);

  if (WiFi.scanComplete() == WIFI_SCAN_RUNNING) esp_wifi_scan_stop();
  WiFi.scanDelete();
  WiFi.disconnect(false);  // station only; setup hotspot stays up
  delay(100);
  beginStation(pendingSsid, pendingPass);
}

// GET /status -> {"state":"idle|connecting|connected|failed","ip":"...","reason":"auth|notfound|timeout"}
void handleStatus() {
  DynamicJsonDocument doc(256);
  const char* state = connectState == CONNECT_RUNNING ? "connecting"
                    : connectState == CONNECT_OK      ? "connected"
                    : connectState == CONNECT_FAILED  ? "failed"
                                                      : "idle";
  doc["state"] = state;
  doc["ssid"] = pendingSsid;
  if (connectState == CONNECT_OK) doc["ip"] = WiFi.localIP().toString();
  if (connectState == CONNECT_FAILED) doc["reason"] = connectFailReason;

  String out;
  serializeJson(doc, out);
  sendJson(200, out);
}

void setupPortalRoutes() {
  server.on("/", HTTP_GET, handlePortalRoot);
  server.on("/scan", HTTP_GET, handleScan);
  server.on("/connect", HTTP_POST, handleConnect);
  server.on("/status", HTTP_GET, handleStatus);
  server.onNotFound(redirectToPortal);
}

void startPortal() {
  if (portalActive) return;

  Serial.print("[Setup] Setup hotspot ON: ");
  Serial.print(apName);
  Serial.print("  ->  http://");
  Serial.println(PORTAL_IP);

  // Stop background reconnect attempts while in setup — they block scanning
  // and make the hotspot hop channels. Saved WiFi is retried on our own timer.
  WiFi.setAutoReconnect(false);
  scanInProgress = false;
  scanFailCount = 0;
  scanCache = "";
  if (WiFi.status() != WL_CONNECTED) scanBeforeHotspot();

  WiFi.mode(WIFI_AP_STA);
  WiFi.softAPConfig(PORTAL_IP, PORTAL_IP, IPAddress(255, 255, 255, 0));
  WiFi.softAP(apName.c_str(), SETUP_AP_PASSWORD);
  delay(100);

  dnsServer.setErrorReplyCode(DNSReplyCode::NoError);
  dnsServer.start(53, "*", PORTAL_IP);  // every domain -> the ESP32
  server.begin();

  connectState = CONNECT_IDLE;
  lastSavedRetryMs = millis();
  portalActive = true;
}

void stopPortal() {
  if (!portalActive) return;

  Serial.println("[Setup] Setup hotspot OFF");
  server.stop();
  dnsServer.stop();
  WiFi.softAPdisconnect(true);  // hotspot is gone once connected
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);

  portalActive = false;
  connectState = CONNECT_IDLE;
  scanCache = "";
}

void updateConnectAttempt() {
  if (connectState != CONNECT_RUNNING) return;

  const uint32_t elapsed = millis() - connectStartMs;

  if (WiFi.status() == WL_CONNECTED) {
    connectState = CONNECT_OK;
    saveWifiCredentials(pendingSsid, pendingPass);  // only saved once it actually works
    portalCloseAtMs = millis() + PORTAL_CLOSE_DELAY_MS;
    Serial.print("[Setup] Connected and saved. IP: ");
    Serial.println(WiFi.localIP());
    return;
  }

  const uint8_t reason = lastDisconnectReason;
  const bool authFailed = isAuthFailure(reason);
  if ((authFailed && elapsed > 8000) || elapsed > WIFI_CONNECT_TIMEOUT_MS) {
    connectState = CONNECT_FAILED;
    connectFailReason = authFailed ? "auth"
                      : reason == WIFI_REASON_NO_AP_FOUND ? "notfound"
                                                          : "timeout";
    WiFi.disconnect(false);
    Serial.print("[Setup] Connect failed: ");
    Serial.print(connectFailReason);
    Serial.print(" (reason ");
    Serial.print(reason);
    Serial.println(")");
  }
}

void portalLoop() {
  dnsServer.processNextRequest();
  server.handleClient();
  collectScanResult();
  updateConnectAttempt();

  // Success: leave the hotspot up briefly so the page can show "Connected".
  if (connectState == CONNECT_OK && (int32_t)(millis() - portalCloseAtMs) >= 0) {
    stopPortal();
    onWifiUp();
    return;
  }

  const bool userBusy = connectState == CONNECT_RUNNING || connectState == CONNECT_OK;
  const bool nobodyOnHotspot = WiFi.softAPgetStationNum() == 0;

  // Saved network came back by itself (e.g. router rebooted after a brownout).
  if (!userBusy && nobodyOnHotspot && WiFi.status() == WL_CONNECTED) {
    Serial.println("[Setup] Saved network is back");
    stopPortal();
    onWifiUp();
    return;
  }

  // Keep the list fresh while nobody is on the hotspot (no one to drop).
  if (!userBusy && nobodyOnHotspot && !scanInProgress && millis() - lastScanMs >= 60000) {
    startScan();
  }

  // Keep retrying the saved network, but not while someone is using the page
  // (retries make the hotspot hop channels and drop the phone).
  if (!userBusy && nobodyOnHotspot && !scanInProgress && !savedSsid.isEmpty() &&
      WiFi.status() != WL_CONNECTED &&
      millis() - lastSavedRetryMs >= SAVED_WIFI_RETRY_MS) {
    lastSavedRetryMs = millis();
    Serial.println("[Setup] Retrying saved network...");
    beginStation(savedSsid, savedPass);
  }
}

// ===================== SETUP / LOOP =====================

void setup() {
  Serial.begin(115200);
  delay(200);
  Serial.println("[System] Booting...");

  pinMode(SSR_PIN, OUTPUT);
  setRelay(false);  // Safe default: OFF at boot
  pinMode(RESET_BTN_PIN, INPUT_PULLUP);

  initPzemUart();
  probePzemLink(true);

  WiFi.persistent(false);  // we store credentials ourselves (Preferences)
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.onEvent([](WiFiEvent_t event, WiFiEventInfo_t info) {
    lastDisconnectReason = info.wifi_sta_disconnected.reason;
  }, ARDUINO_EVENT_WIFI_STA_DISCONNECTED);

  String mac = WiFi.macAddress();
  mac.replace(":", "");
  apName = String("SmartSwitch-") + mac.substring(8);  // e.g. SmartSwitch-A3F7

  setupPortalRoutes();
  loadWifiCredentials();

  if (savedSsid.isEmpty()) {
    Serial.println("[WiFi] No saved network.");
    startPortal();
  } else if (connectSavedWifi(WIFI_CONNECT_TIMEOUT_MS)) {
    onWifiUp();
  } else if (OFFLINE_PORTAL_AFTER_MS > 0) {
    Serial.println("[WiFi] Saved network not reachable.");
    startPortal();
  } else {
    // Router may still be booting after a power outage: keep retrying, no hotspot.
    Serial.println("[WiFi] Saved network not reachable yet - will keep retrying.");
  }

  Serial.println("[System] SmartPowerSwitch firmware started.");
}

void loop() {
  checkResetButton();

  if (portalActive) {
    portalLoop();
    delay(2);
    return;
  }

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
        Serial.println("CONNECTED");
        onWifiUp();
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
    if (offlineSinceMs == 0) offlineSinceMs = now;

    if (now - lastWifiRetryMs >= WIFI_RETRY_MS) {
      lastWifiRetryMs = now;
      Serial.println("[WiFi] Reconnecting...");
      WiFi.reconnect();
    }

    if (OFFLINE_PORTAL_AFTER_MS > 0 && now - offlineSinceMs >= OFFLINE_PORTAL_AFTER_MS) {
      Serial.println("[WiFi] Offline for 2 min - opening setup hotspot.");
      startPortal();
    }

    delay(20);
    return;
  }
  offlineSinceMs = 0;

  // Probe PZEM more frequently if not ready
  if (!pzemReady) {
    probePzemLink(false);  // Will retry every PZEM_PROBE_RETRY_MS if not ready
  }

  if (now - lastRelayPollMs >= RELAY_POLL_MS) {
    lastRelayPollMs = now;
    pollCommands();
  }

  if (now - lastTelemetryPushMs >= TELEMETRY_PUSH_MS) {
    lastTelemetryPushMs = now;
    pushTelemetry();
  }

  delay(10);
}
