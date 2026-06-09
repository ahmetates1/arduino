/*
 * ESP32-S3 N16R8 + E220-400T30D — alici (esp2)
 * Eslesen verici: nano/nano_e220_sender (NETWORK_ID=7, 5 sn aralik)
 *
 * WiFi + Supabase: wifi_secrets.h, sensor_data_test tablosu
 * Tablo SQL: esp32/supabase/sensor_data_test.sql (Dashboard > SQL Editor)
 *
 * Arduino IDE -> Tools (ESP32-S3):
 *   Board: ESP32S3 Dev Module
 *   USB CDC On Boot: Enabled
 *   USB Mode: Hardware CDC and JTAG
 *
 * LoRa: TX->GPIO17, RX<-GPIO18, 9600, M0/M1 GND
 * Role modulu IN -> GPIO4 (RELAY_PIN), cogu modul LOW=acik
 * Seri monitör 115200
 *
 * Role komutu (Nano'dan): 7|2|0|0|1 ac  /  7|2|0|0|0 kapa  /  high=2 toggle
 * Normal telemetri node_id=1 role'e dokunmaz.
 */

#if CONFIG_IDF_TARGET_ESP32S3
#include "USB.h"
#endif

#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include "wifi_secrets.h"

HardwareSerial loraSerial(2);

#define LORA_RX             17
#define LORA_TX             18
#define LORA_BAUD           9600
#define EXPECTED_NETWORK_ID 7

#define DEBUG_EACH_BYTE     0
#define USE_SERIAL0         0   // S3 USB CDC kullaniyorsaniz 0 birakin (43/44 takilir)
#define SHOW_ALIVE          1
#define ENABLE_SUPABASE     1
#define ENABLE_RELAY        1

#define RELAY_PIN           4
#define RELAY_ACTIVE_LOW    1    // 1: cogu "LOW level trigger" modul
#define RELAY_NODE_ID       2    // sadece bu node_id role komutu

#define PACKET_IDLE_MS      120
#define HEARTBEAT_MS        3000
#define MAX_PACKET_LEN      80
#define WIFI_RETRY_MS       15000
#define PENDING_MAX         8

const char* supabaseUrl =
    "https://ngdozrhycaeiabubrywf.supabase.co/rest/v1/sensor_data_test";
const char* apiKey = "sb_publishable_DNrEyZFNk13VFNlfE2UhZg_FnVwiHcJ";

#ifdef LED_BUILTIN
#define LED_PIN LED_BUILTIN
#else
#define LED_PIN 2
#endif

String rxBuffer;
unsigned long lastLoraByteMs = 0;
unsigned long lastHeartbeatMs = 0;
unsigned long lastPacketMs = 0;
unsigned long lastWifiRetryMs = 0;
unsigned long ledOffMs = 0;
bool ledOn = false;
bool wifiConnected = false;
bool relayState = false;
String lastPacket;

struct PendingRow {
  String packet;
  bool valid;
  int networkId;
  int nodeId;
  int seq;
  int uptimeSec;
  int high;
  bool used;
};
PendingRow pending[PENDING_MAX];
bool wifiInitDone = false;

void logMsg(const char* msg) {
  Serial.println(msg);
}

void logMsg(const __FlashStringHelper* msg) {
  Serial.println(msg);
}

bool parsePacket(const String& raw, int& networkId, int& nodeId,
                 int& low, int& mid, int& high) {
  int p1 = raw.indexOf('|');
  int p2 = raw.indexOf('|', p1 + 1);
  int p3 = raw.indexOf('|', p2 + 1);
  int p4 = raw.indexOf('|', p3 + 1);

  if (p1 < 0 || p2 < 0 || p3 < 0 || p4 < 0) {
    return false;
  }

  networkId = raw.substring(0, p1).toInt();
  nodeId = raw.substring(p1 + 1, p2).toInt();
  low = raw.substring(p2 + 1, p3).toInt();
  mid = raw.substring(p3 + 1, p4).toInt();
  high = raw.substring(p4 + 1).toInt();
  return true;
}

void blinkRxLed() {
  digitalWrite(LED_PIN, HIGH);
  ledOn = true;
  ledOffMs = millis() + 80;
}

#if ENABLE_RELAY
void applyRelayPin(bool on) {
  relayState = on;
#if RELAY_ACTIVE_LOW
  digitalWrite(RELAY_PIN, on ? LOW : HIGH);
#else
  digitalWrite(RELAY_PIN, on ? HIGH : LOW);
#endif
}

void setRelay(bool on) {
  applyRelayPin(on);
  Serial.print(F("[Role] "));
  Serial.println(on ? F("ACIK") : F("KAPALI"));
  Serial.flush();
}

void toggleRelay() {
  setRelay(!relayState);
}

// high: 0=kapa, 1=ac, 2=toggle
void handleRelayCommand(int high) {
  if (high == 1) {
    setRelay(true);
  } else if (high == 0) {
    setRelay(false);
  } else if (high == 2) {
    toggleRelay();
  } else {
    Serial.print(F("[Role] Gecersiz high="));
    Serial.println(high);
  }
}
#endif

void startWiFiOnce() {
  if (wifiInitDone) {
    return;
  }
  wifiInitDone = true;
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  lastWifiRetryMs = millis();
  Serial.print(F("[WiFi] baslatildi: "));
  Serial.println(WIFI_SSID);
}

void flushPendingSupabase();

void maintainWiFi() {
  if (WiFi.status() == WL_CONNECTED) {
    if (!wifiConnected) {
      wifiConnected = true;
      Serial.print(F("[WiFi] Baglandi, IP: "));
      Serial.println(WiFi.localIP());
      flushPendingSupabase();
    }
    return;
  }

  wifiConnected = false;
  unsigned long now = millis();
  if (now - lastWifiRetryMs >= WIFI_RETRY_MS) {
    Serial.println(F("[WiFi] Tekrar deneniyor..."));
    WiFi.disconnect();
    WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
    lastWifiRetryMs = now;
  }
}

#if ENABLE_SUPABASE
String jsonEscape(const String& s) {
  String out;
  out.reserve(s.length() + 8);
  for (unsigned int i = 0; i < s.length(); i++) {
    const char c = s[i];
    if (c == '\\' || c == '"') {
      out += '\\';
    }
    out += c;
  }
  return out;
}

String buildSupabaseJson(const String& packet, bool valid, int networkId,
                         int nodeId, int seq, int uptimeSec, int high) {
  const String esc = jsonEscape(packet);
  String j;
  j.reserve(esc.length() + 120);
  j += F("{\"raw\":\"");
  j += esc;
  j += F("\"");
  if (valid) {
    j += F(",\"raw_unparsed\":null,\"is_valid\":true");
    j += F(",\"network_id\":");
    j += networkId;
    j += F(",\"node_id\":");
    j += nodeId;
    j += F(",\"seq\":");
    j += seq;
    j += F(",\"uptime_sec\":");
    j += uptimeSec;
    j += F(",\"high\":");
    j += high;
  } else {
    j += F(",\"raw_unparsed\":\"");
    j += esc;
    j += F("\",\"is_valid\":false");
    j += F(",\"network_id\":null,\"node_id\":null,\"seq\":null");
    j += F(",\"uptime_sec\":null,\"high\":null");
  }
  j += '}';
  return j;
}

bool enqueuePending(const String& packet, bool valid, int networkId, int nodeId,
                    int seq, int uptimeSec, int high) {
  for (int i = 0; i < PENDING_MAX; i++) {
    if (!pending[i].used) {
      pending[i].packet = packet;
      pending[i].valid = valid;
      pending[i].networkId = networkId;
      pending[i].nodeId = nodeId;
      pending[i].seq = seq;
      pending[i].uptimeSec = uptimeSec;
      pending[i].high = high;
      pending[i].used = true;
      Serial.println(F("[Supabase] Kuyruga alindi (WiFi yok veya hata)"));
      return true;
    }
  }
  Serial.println(F("[Supabase] Kuyruk dolu, kayit atildi"));
  return false;
}

bool sendToSupabaseNow(const String& packet, bool valid, int networkId,
                       int nodeId, int seq, int uptimeSec, int high) {
  if (WiFi.status() != WL_CONNECTED) {
    return false;
  }

  const String body =
      buildSupabaseJson(packet, valid, networkId, nodeId, seq, uptimeSec, high);

  Serial.print(F("[Supabase] "));
  Serial.print(valid ? F("gecerli") : F("GECERSIZ"));
  Serial.print(F(" -> "));
  Serial.println(body);

  WiFiClientSecure client;
  client.setInsecure();

  HTTPClient http;
  http.begin(client, supabaseUrl);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("apikey", apiKey);
  http.addHeader("Authorization", String("Bearer ") + apiKey);
  http.addHeader("Prefer", "return=minimal");
  http.setTimeout(15000);

  const int httpCode = http.POST(body);
  if (httpCode >= 200 && httpCode < 300) {
    Serial.print(F("[Supabase] OK "));
    Serial.println(httpCode);
    http.end();
    return true;
  }

  Serial.print(F("[Supabase] Hata kod="));
  Serial.print(httpCode);
  Serial.print(F(" "));
  Serial.println(http.errorToString(httpCode));
  if (httpCode > 0) {
    const String resp = http.getString();
    if (resp.length() > 0) {
      Serial.println(resp);
    }
    if (resp.indexOf(F("raw_unparsed")) >= 0 ||
        resp.indexOf(F("is_valid")) >= 0) {
      Serial.println(
          F(">>> esp32/supabase/sensor_data_test_alter.sql calistirin"));
    }
  }
  http.end();
  return false;
}

bool sendToSupabase(const String& packet, bool valid, int networkId, int nodeId,
                    int seq, int uptimeSec, int high) {
  if (WiFi.status() != WL_CONNECTED) {
    Serial.println(F("[Supabase] WiFi yok"));
    return enqueuePending(packet, valid, networkId, nodeId, seq, uptimeSec,
                          high);
  }

  if (sendToSupabaseNow(packet, valid, networkId, nodeId, seq, uptimeSec,
                        high)) {
    return true;
  }

  return enqueuePending(packet, valid, networkId, nodeId, seq, uptimeSec, high);
}

void flushPendingSupabase() {
  for (int i = 0; i < PENDING_MAX; i++) {
    if (!pending[i].used) {
      continue;
    }
    if (sendToSupabaseNow(pending[i].packet, pending[i].valid,
                          pending[i].networkId, pending[i].nodeId,
                          pending[i].seq, pending[i].uptimeSec,
                          pending[i].high)) {
      pending[i].used = false;
    }
    delay(100);
  }
}
#endif

void printLoRaLine(const __FlashStringHelper* tag, const String& packet) {
  Serial.print(tag);
  Serial.println(packet);
  Serial.flush();
  Serial0.print(tag);
  Serial0.println(packet);
}

void handlePacket(const String& packet) {
  lastPacket = packet;
  lastPacketMs = millis();
  blinkRxLed();

  int networkId, nodeId, low, mid, high;
  if (!parsePacket(packet, networkId, nodeId, low, mid, high)) {
    printLoRaLine(F("[LoRa?] "), packet);
#if ENABLE_SUPABASE
    sendToSupabase(packet, false, 0, 0, 0, 0, 0);
#endif
    return;
  }

  if (networkId != EXPECTED_NETWORK_ID) {
    Serial.print(F("[LoRa?] "));
    Serial.print(packet);
    Serial.print(F("  (network "));
    Serial.print(networkId);
    Serial.print(F(" != "));
    Serial.print(EXPECTED_NETWORK_ID);
    Serial.println(')');
    Serial.flush();
#if ENABLE_SUPABASE
    sendToSupabase(packet, false, 0, 0, 0, 0, 0);
#endif
    return;
  }

  printLoRaLine(F("[LoRa] "), packet);

#if ENABLE_RELAY
  if (nodeId == RELAY_NODE_ID) {
    handleRelayCommand(high);
  }
#endif

#if ENABLE_SUPABASE
  sendToSupabase(packet, true, networkId, nodeId, low, mid, high);
#endif
}

void flushRxBuffer() {
  while (rxBuffer.length() > 0) {
    int nl = rxBuffer.indexOf('\n');
    String packet;
    if (nl >= 0) {
      packet = rxBuffer.substring(0, nl);
      rxBuffer = rxBuffer.substring(nl + 1);
    } else {
      packet = rxBuffer;
      rxBuffer = "";
    }
    packet.trim();
    if (packet.length() == 0) {
      continue;
    }
    handlePacket(packet);
    if (nl < 0) {
      break;
    }
  }
}

void setup() {
  pinMode(LED_PIN, OUTPUT);
  digitalWrite(LED_PIN, LOW);

#if ENABLE_RELAY
  pinMode(RELAY_PIN, OUTPUT);
  applyRelayPin(false);
#endif

#if CONFIG_IDF_TARGET_ESP32S3 && ARDUINO_USB_CDC_ON_BOOT
  USB.begin();
#endif

  Serial.begin(115200);
  delay(2000);
#if USE_SERIAL0
  Serial0.begin(115200, SERIAL_8N1, 44, 43);
#endif

  Serial.println();
  logMsg(F("=== ESP32-S3 E220 + WiFi + Supabase ==="));
  logMsg(F("[1/4] LoRa UART baslatiliyor..."));

  loraSerial.setRxBufferSize(1024);
  loraSerial.begin(LORA_BAUD, SERIAL_8N1, LORA_RX, LORA_TX);
  delay(100);

  while (loraSerial.available()) {
    (void)loraSerial.read();
  }

  for (int i = 0; i < PENDING_MAX; i++) {
    pending[i].used = false;
  }

  logMsg(F("[2/4] LoRa RX=GPIO17 TX=GPIO18 baud=9600"));
  logMsg(F("[3/4] Role pin GPIO4 | komut: on/off (Nano)"));
  logMsg(F("     Gecerli paket: 7|1|...  Role: 7|2|0|0|1"));
  logMsg(F("[4/4] WiFi loop icinde baslayacak"));
  Serial.print(F("Supabase: "));
  Serial.println(supabaseUrl);
  logMsg(F(">>> Setup tamam — 3 sn icinde [alive] gelmeli <<<"));
  Serial.println();

  lastHeartbeatMs = millis() - HEARTBEAT_MS;
}

void loop() {
  unsigned long now = millis();

  startWiFiOnce();
  maintainWiFi();
#if ENABLE_SUPABASE
  static unsigned long lastFlushMs = 0;
  if (WiFi.status() == WL_CONNECTED && now - lastFlushMs >= 5000) {
    lastFlushMs = now;
    flushPendingSupabase();
  }
#endif

  while (loraSerial.available()) {
    uint8_t b = static_cast<uint8_t>(loraSerial.read());
    char c = static_cast<char>(b);
    lastLoraByteMs = now;

#if DEBUG_EACH_BYTE
    Serial.print(F("[BYTE] 0x"));
    if (b < 0x10) {
      Serial.print('0');
    }
    Serial.print(b, HEX);
    Serial.println();
#endif

    if (c == '\n') {
      flushRxBuffer();
      continue;
    }
    if (c != '\r') {
      if (rxBuffer.length() >= MAX_PACKET_LEN) {
        logMsg(F("[LoRa] rxBuffer tasmasi, sifirlaniyor"));
        rxBuffer = "";
      }
      rxBuffer += c;
    }
  }

  if (ledOn && now >= ledOffMs) {
    digitalWrite(LED_PIN, LOW);
    ledOn = false;
  }

  if (rxBuffer.length() > 0 && lastLoraByteMs > 0 &&
      now - lastLoraByteMs >= PACKET_IDLE_MS) {
    flushRxBuffer();
    lastLoraByteMs = 0;
  }

#if SHOW_ALIVE
  if (now - lastHeartbeatMs >= HEARTBEAT_MS) {
    lastHeartbeatMs = now;

    if (!ledOn) {
      digitalWrite(LED_PIN, HIGH);
      ledOn = true;
      ledOffMs = now + 30;
    }

    Serial.print(F("[alive] "));
    Serial.print(now / 1000UL);
    Serial.print(F("s  WiFi="));
    Serial.print(WiFi.status() == WL_CONNECTED ? F("OK") : F("yok"));
    Serial.print(F("  LoRaRX=GPIO"));
    Serial.print(LORA_RX);
    if (lastPacket.length() > 0) {
      Serial.print(F("  son="));
      Serial.print(lastPacket);
    } else {
      Serial.print(F("  (paket yok)"));
    }
    Serial.println();
  }
#endif
}
