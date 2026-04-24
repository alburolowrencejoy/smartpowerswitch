/*
  SmartPowerSwitch ESP32 Firmware (ID-only registration flow)

  What this sketch does:
  1) Connects to WiFi
  2) Reads PZEM-004T values (voltage/current/power/energy)
  3) Polls Firebase relay command from: /devices/<DEVICE_ID>/relay
  4) Controls an SSR output pin
  5) Pushes telemetry to: /devices/<DEVICE_ID>

  Required Arduino libraries:
  - ArduinoJson (by Benoit Blanchon)
  - PZEM004T (legacy PZEM-004T library by Oleg Sokolov)

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
#include <PZEM004T.h>
#include <time.h>

// ===================== USER CONFIG =====================
static const char* WIFI_SSID = "xxxRAGExxx";
static const char* WIFI_PASSWORD = "Lowelbaby12";

static const char* FIREBASE_DB_URL =
    "https://smartpowerswitch-e90d0-default-rtdb.asia-southeast1.firebasedatabase.app";

// Must match the address programmed into the PZEM module.
static const IPAddress PZEM_ADDRESS(192, 168, 1, 1);

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

// =======================================================

#if defined(ESP32)
PZEM004T pzem(&Serial2, PZEM_RX_PIN, PZEM_TX_PIN);
#else
PZEM004T pzem(&Serial2);
#endif

bool relayState = false;
bool pzemReady = false;

uint32_t lastRelayPollMs = 0;
uint32_t lastTelemetryPushMs = 0;
uint32_t lastWifiRetryMs = 0;

uint64_t bootEpochMs = 0;
uint32_t bootMillisAtSync = 0;

static inline float roundTo(float value, int places) {
  float scale = 1.0f;
  for (int i = 0; i < places; i++) {
    scale *= 10.0f;
  }
  return roundf(value * scale) / scale;
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

  HTTPClient https;
  const String url = String(FIREBASE_DB_URL) + path;

  if (!https.begin(client, url)) {
    return false;
  }

  statusCode = https.GET();
  responseBody = https.getString();
  https.end();
  return true;
}

bool firebasePatch(const String& path, const String& json, int& statusCode) {
  if (WiFi.status() != WL_CONNECTED) return false;

  WiFiClientSecure client;
  client.setInsecure();

  HTTPClient https;
  const String url = String(FIREBASE_DB_URL) + path;

  if (!https.begin(client, url)) {
    return false;
  }

  https.addHeader("Content-Type", "application/json");
  statusCode = https.sendRequest("PATCH", json);
  https.end();
  return true;
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

  const bool cloudRelay = doc["relay"] | relayState;
  if (cloudRelay != relayState) {
    setRelay(cloudRelay);
    Serial.print("[Relay] Set from cloud: ");
    Serial.println(relayState ? "ON" : "OFF");
  }
}

void pushTelemetry() {
  if (!pzemReady) {
    pzemReady = pzem.setAddress(PZEM_ADDRESS);
    if (!pzemReady) {
      Serial.println("[PZEM] Address setup failed. Check wiring and AC side.");
    }
  }

  const float voltage = pzem.voltage(PZEM_ADDRESS);
  const float current = pzem.current(PZEM_ADDRESS);
  const float power = pzem.power(PZEM_ADDRESS);
  const float energyWh = pzem.energy(PZEM_ADDRESS);

  const bool pzemOk = voltage >= 0.0f && current >= 0.0f && power >= 0.0f &&
                      energyWh >= 0.0f;

  const uint64_t t = nowMs();
  const String status = pzemOk ? "online" : "offline";

  Serial.print("[PZEM] V=");
  Serial.print(pzemOk ? String(roundTo(voltage, 1)) : String("nan"));
  Serial.print(" I=");
  Serial.print(pzemOk ? String(roundTo(current, 2)) : String("nan"));
  Serial.print(" P=");
  Serial.print(pzemOk ? String(roundTo(power, 1)) : String("nan"));
  Serial.print(" kWh=");
  Serial.print(pzemOk ? String(roundTo(energyWh / 1000.0f, 4)) : String("nan"));
  Serial.print(" relay=");
  Serial.println(relayState ? "ON" : "OFF");

  DynamicJsonDocument doc(512);
  doc["relay"] = relayState;
  doc["status"] = status;
  doc["last_updated"] = t;
  doc["last_seen"] = pzemOk ? t : (t > 300000 ? t - 300000 : 0);

  if (pzemOk) {
    doc["voltage"] = roundTo(voltage, 1);
    doc["current"] = roundTo(current, 2);
    doc["power"] = roundTo(power, 1);
    doc["kwh"] = roundTo(energyWh / 1000.0f, 4);
    doc["powerFactor"] = 0;
    doc["frequency"] = 0;
  }

  String payload;
  serializeJson(doc, payload);

  int code = 0;
  const bool ok = firebasePatch(String("/devices/") + DEVICE_ID + ".json", payload, code);
  if (!ok || (code != 200 && code != 204)) {
    Serial.print("[Firebase] Telemetry push failed. HTTP ");
    Serial.println(code);
    return;
  }
}

void setup() {
  Serial.begin(115200);
  delay(200);

  pinMode(SSR_PIN, OUTPUT);
  setRelay(false);  // Safe default: OFF at boot

  pzem.setReadTimeout(1000);
  pzemReady = pzem.setAddress(PZEM_ADDRESS);
  if (pzemReady) {
    Serial.println("[PZEM] Address set.");
  } else {
    Serial.println("[PZEM] Address set failed. Check wiring and AC side.");
  }

  connectWiFi();
  if (WiFi.status() == WL_CONNECTED) {
    syncTimeIfPossible();
  }

  Serial.println("[System] SmartPowerSwitch firmware started.");
}

void loop() {
  const uint32_t now = millis();

  if (WiFi.status() != WL_CONNECTED) {
    if (now - lastWifiRetryMs >= WIFI_RETRY_MS) {
      lastWifiRetryMs = now;
      connectWiFi();
      if (WiFi.status() == WL_CONNECTED) {
        syncTimeIfPossible();
      }
    }
    delay(20);
    return;
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
