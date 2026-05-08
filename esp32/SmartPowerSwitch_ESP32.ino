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

// PZEM Modbus addresses to probe. Factory default is often 0xF8.
static const uint8_t PZEM_MODBUS_ADDR_CANDIDATES[] = {0xF8, 0x01, 0x02, 0x03};

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
static const uint32_t PZEM_UART_BAUD = 9600;
static const uint32_t PZEM_PROBE_RETRY_MS = 15000;
static const uint32_t PZEM_RAW_TIMEOUT_MS = 350;
static const bool PZEM_RAW_DEBUG_ON_BOOT = true;
static const bool PZEM_RAW_DEBUG_ON_PROBE_FAIL = true;

// =======================================================

PZEM004Tv30 pzem(Serial2, PZEM_RX_PIN, PZEM_TX_PIN);

uint8_t pzemAddress = 0xF8;  // Factory default address for v4.0 modules

bool relayState = false;
bool pzemReady = false;
uint32_t pzemLastOnlineMs = 0;  // Track when PZEM was last online
// Track last seen energy reading so we can write per-interval history deltas
float lastReportedEnergyKwh = -1.0f;

uint32_t lastRelayPollMs = 0;
uint32_t lastTelemetryPushMs = 0;
uint32_t lastWifiRetryMs = 0;
uint32_t lastPzemProbeMs = 0;
wl_status_t lastWifiStatus = WL_DISCONNECTED;  // Track WiFi status changes

uint64_t bootEpochMs = 0;
uint32_t bootMillisAtSync = 0;

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

uint8_t pzemLegacyChecksum(const uint8_t* data, size_t len) {
  uint16_t sum = 0;
  for (size_t i = 0; i < len; i++) {
    sum += data[i];
  }
  return (uint8_t)(sum & 0xFF);
}

void printHexFrame(const uint8_t* frame, size_t len) {
  for (size_t i = 0; i < len; i++) {
    if (frame[i] < 0x10) {
      Serial.print('0');
    }
    Serial.print(frame[i], HEX);
    if (i + 1 < len) {
      Serial.print(' ');
    }
  }
}

void printIpAddress(const IPAddress& ip) {
  Serial.print(ip[0]);
  Serial.print('.');
  Serial.print(ip[1]);
  Serial.print('.');
  Serial.print(ip[2]);
  Serial.print('.');
  Serial.print(ip[3]);
}

bool pzemLegacyRawExchange(uint8_t cmd,
                           uint8_t dataByte,
                           uint8_t expectedResp,
                           const IPAddress& addr,
                           uint8_t txFrame[7],
                           uint8_t rxFrame[7]) {
  txFrame[0] = cmd;
  txFrame[1] = addr[0];
  txFrame[2] = addr[1];
  txFrame[3] = addr[2];
  txFrame[4] = addr[3];
  txFrame[5] = dataByte;
  txFrame[6] = pzemLegacyChecksum(txFrame, 6);

  while (Serial2.available()) {
    Serial2.read();
  }

  Serial2.write(txFrame, 7);
  Serial2.flush();

  const uint32_t start = millis();
  uint8_t got = 0;
  while (got < 7 && (millis() - start) < PZEM_RAW_TIMEOUT_MS) {
    if (Serial2.available()) {
      rxFrame[got++] = (uint8_t)Serial2.read();
    } else {
      delay(1);
    }
  }

  if (got != 7) {
    return false;
  }

  if (rxFrame[0] != expectedResp) {
    return false;
  }

  if (rxFrame[6] != pzemLegacyChecksum(rxFrame, 6)) {
    return false;
  }

  return true;
}

uint16_t pzemModbusCrc16(const uint8_t* data, size_t len) {
  uint16_t crc = 0xFFFF;
  for (size_t i = 0; i < len; i++) {
    crc ^= data[i];
    for (uint8_t bit = 0; bit < 8; bit++) {
      if (crc & 0x0001) {
        crc = (crc >> 1) ^ 0xA001;
      } else {
        crc = crc >> 1;
      }
    }
  }
  return crc;
}

bool pzemModbusRawReadInputRegs(uint8_t slaveAddr,
                                uint16_t startReg,
                                uint16_t regCount,
                                uint8_t txFrame[8],
                                uint8_t rxFrame[25]) {
  txFrame[0] = slaveAddr;
  txFrame[1] = 0x04;  // Read Input Registers
  txFrame[2] = (uint8_t)(startReg >> 8);
  txFrame[3] = (uint8_t)(startReg & 0xFF);
  txFrame[4] = (uint8_t)(regCount >> 8);
  txFrame[5] = (uint8_t)(regCount & 0xFF);

  const uint16_t crc = pzemModbusCrc16(txFrame, 6);
  txFrame[6] = (uint8_t)(crc & 0xFF);        // CRC low byte first
  txFrame[7] = (uint8_t)((crc >> 8) & 0xFF); // CRC high byte

  while (Serial2.available()) {
    Serial2.read();
  }

  Serial2.write(txFrame, 8);
  Serial2.flush();

  const uint32_t start = millis();
  uint8_t got = 0;
  while (got < 25 && (millis() - start) < PZEM_RAW_TIMEOUT_MS) {
    if (Serial2.available()) {
      rxFrame[got++] = (uint8_t)Serial2.read();
    } else {
      delay(1);
    }
  }

  if (got != 25) {
    return false;
  }

  if (rxFrame[0] != slaveAddr || rxFrame[1] != 0x04 || rxFrame[2] != 20) {
    return false;
  }

  const uint16_t rxCrc = (uint16_t)rxFrame[23] | ((uint16_t)rxFrame[24] << 8);
  return rxCrc == pzemModbusCrc16(rxFrame, 23);
}

void runPzemModbusRawDiagnostics() {
  Serial.println("[PZEM MODBUS RAW] Trying v4.0 Modbus read-register probes...");

  bool anyOk = false;
  uint8_t tx[8];
  uint8_t rx[25];

  for (size_t i = 0; i < (sizeof(PZEM_MODBUS_ADDR_CANDIDATES) / sizeof(PZEM_MODBUS_ADDR_CANDIDATES[0])); i++) {
    const uint8_t slave = PZEM_MODBUS_ADDR_CANDIDATES[i];

    if (pzemModbusRawReadInputRegs(slave, 0x0000, 0x000A, tx, rx)) {
      anyOk = true;

      const float voltage = ((uint16_t)rx[3] << 8 | rx[4]) / 10.0f;
      const uint32_t currentRaw = ((uint32_t)rx[5] << 8) | (uint32_t)rx[6] |
                                  ((uint32_t)rx[7] << 24) | ((uint32_t)rx[8] << 16);
      const float current = currentRaw / 1000.0f;

      Serial.print("[PZEM MODBUS RAW] addr=0x");
      if (slave < 0x10) {
        Serial.print('0');
      }
      Serial.print(slave, HEX);
      Serial.print(" TX=");
      printHexFrame(tx, 8);
      Serial.print(" RX=");
      printHexFrame(rx, 25);
      Serial.print(" -> V=");
      Serial.print(voltage, 1);
      Serial.print(" I=");
      Serial.print(current, 3);
      Serial.println(" (valid Modbus frame)");
      break;
    }

    Serial.print("[PZEM MODBUS RAW] addr=0x");
    if (slave < 0x10) {
      Serial.print('0');
    }
    Serial.print(slave, HEX);
    Serial.print(" TX=");
    printHexFrame(tx, 8);
    Serial.println(" RX=<invalid/no response>");
  }

  if (anyOk) {
    Serial.println("[PZEM MODBUS RAW] Module replied to Modbus v4.0. Use PZEM004Tv30 firmware path.");
  } else {
    Serial.println("[PZEM MODBUS RAW] No valid Modbus replies either. This points to wiring/power-level issues.");
  }
}

bool runPzemRawDiagnostics() {
  Serial.println("[PZEM RAW] Legacy raw diagnostics are disabled for the PZEM004Tv30 path.");
  return false;
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
    if (PZEM_RAW_DEBUG_ON_PROBE_FAIL) {
      Serial.println("[PZEM] Running diagnostics...");
      const bool legacyRawOk = runPzemRawDiagnostics();
      if (!legacyRawOk) {
        runPzemModbusRawDiagnostics();
      }
    }
    Serial.println(
        "[PZEM] CHECK: TX/RX swap, common GND, level shift on ESP32 RX, AC power on measurement side");
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
    Serial.println("[Firebase] PATCH failed: WiFi disconnected");
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
    Serial.println("[Firebase] PATCH failed: Could not begin HTTP connection");
    return false;
  }

  https.addHeader("Content-Type", "application/json");
  statusCode = https.sendRequest("PATCH", json);
  String resp = https.getString();
  if (statusCode <= 0) {
    Serial.print("[Firebase] PATCH request error: ");
    Serial.println(https.errorToString(statusCode));
    Serial.print("[Firebase] PATCH response: ");
    Serial.println(resp);
  } else {
    Serial.print("[Firebase] PATCH response code: ");
    Serial.println(statusCode);
    Serial.print("[Firebase] PATCH body: ");
    Serial.println(resp);
  }
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
  if (cloudRelay != relayState) {
    setRelay(cloudRelay);
    Serial.print("[Relay] Set from cloud: ");
    Serial.println(cloudRelay ? "ON" : "OFF");
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

  // Track when PZEM was last online
  if (pzemOk) {
    pzemLastOnlineMs = millis();
  }

  // DISABLED: Don't auto-shutoff relay just because PZEM is offline.
  // PZEM may take time to initialize. Only shutoff for actual error conditions.
  // const uint32_t pzemOfflineDurationMs = millis() - pzemLastOnlineMs;
  // if (!pzemOk && relayState && pzemOfflineDurationMs > 5000) {
  //   setRelay(false);
  //   Serial.println("[PZEM] Auto-shutoff: PZEM offline for 5+ seconds");
  // }

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
  doc["relay"] = relayState;
  doc["status"] = status;
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
  Serial.print("[Telemetry] Pushing to Firebase... ");
  const bool ok = firebasePatch(String("/devices/") + DEVICE_ID + ".json", payload, code);
  
  if (!ok) {
    Serial.println("FAILED (no connection)");
    return;
  }
  
  if (code != 200 && code != 204) {
    Serial.print("FAILED (HTTP ");
    Serial.print(code);
    Serial.println(")");
    return;
  }
  
  Serial.println("OK (HTTP 200/204)");

  // Verify by fetching the device node we just patched
  String verifyBody;
  int verifyCode = 0;
  const String devicePath = String("/devices/") + DEVICE_ID + ".json";
  if (firebaseGet(devicePath, verifyBody, verifyCode)) {
    Serial.print("[Verify GET] code: ");
    Serial.println(verifyCode);
    Serial.print("[Verify GET] body: ");
    Serial.println(verifyBody);
  } else {
    Serial.println("[Verify GET] failed to GET device node");
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

      const double cost = (double)delta * rate;

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

  pzemLastOnlineMs = millis();  // Initialize so timeout doesn't trigger immediately
  initPzemUart();
  if (PZEM_RAW_DEBUG_ON_BOOT) {
    const bool legacyRawOk = runPzemRawDiagnostics();
    if (!legacyRawOk) {
      runPzemModbusRawDiagnostics();
    }
  }
  probePzemLink(true);

  connectWiFi();
  if (WiFi.status() == WL_CONNECTED) {
    syncTimeIfPossible();
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
