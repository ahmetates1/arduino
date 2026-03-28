#include <WiFi.h>
#include <HTTPClient.h>
#include <SPI.h>
#include <LoRa.h>
#include <esp_random.h>

// WiFi
const char* ssid = "SUPERONLINE_Wi-Fi_7FUF";
const char* password = "bbad6831db71_7fdr215swdar35";

// Supabase — Dashboard: Project Settings > API > Project URL
// Dogru ornek: https://abcdefghijklmnop.supabase.co/rest/v1/sensor_data
// "iot.supabase.co" gibi bir sey proje URL'in degildir; HTML (192.168.1.1) modem captive portal da olabilir.
const char* supabaseUrl = "https://ngdozrhycaeiabubrywf.supabase.co/rest/v1/sensor_data";
// anon (public) veya RLS'e uygun service_role — Supabase > Project Settings > API
const char* apiKey = "sb_publishable_DNrEyZFNk13VFNlfE2UhZg_FnVwiHcJ";

// tanks.ino / gateway_Atmega328P ile aynı: net|id|low|mid|high
const int NETWORK_ID = 77;

const char* tankNames[5] = {
  "YICME",
  "GEBAN",
  "TEPETOKI",
  "TOKI",
  "AICME"
};

// LoRa yokken / test: gercek paket formatinda saniyede bir Supabase'e gider
#define SIMULATE_LORA 1
// 1: sadece LoRa basarisizken sim et (modul takilinca cift kayit olmaz)
#define SIMULATE_ONLY_WITHOUT_LORA 1
#define SIMULATE_INTERVAL_MS 5000

// LoRa pinleri (Sandeep Mistry LoRa.h: CS, RST, DIO0)
// Heltec WiFi LoRa 32 / TTGO LoRa32: CS=18, RST=14, DIO0=26 (SPI: SCK=5, MISO=19, MOSI=27)
// Ham ESP32 + RFM95 kablolamada cogu ornek: CS=5, RST=14, DIO0=26 — kartina gore birini sec
#define LORA_CS   18
#define LORA_RST  14
#define LORA_DIO0 26

bool loraReady = false;

void setup() {
  Serial.begin(115200);

  // WiFi bağlan
  WiFi.begin(ssid, password);
  Serial.print("WiFi baglaniyor");
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.println("\nWiFi OK");

  // LoRa (Turkiye: 433 MHz modul -> 433E6, 868 MHz -> 868E6)
  LoRa.setPins(LORA_CS, LORA_RST, LORA_DIO0);
  if (LoRa.begin(433E6)) {
    loraReady = true;
    Serial.println("LoRa OK");
  } else {
    loraReady = false;
    Serial.println("LoRa basarisiz (modul yok / pin veya MHz yanlis). Diger kod calisiyor.");
    Serial.println("Heltec/TTGO: CS=18. Ham modul: CS=5. 868 modul: LoRa.begin(868E6).");
  }

  randomSeed(esp_random());
}

/** gateway_Atmega328P.parsePacket ile aynı mantık */
bool parseTankPacket(const String& raw, int& tankId, int& levelPct) {
  String packet = raw;
  packet.trim();

  int p1 = packet.indexOf('|');
  int p2 = packet.indexOf('|', p1 + 1);
  int p3 = packet.indexOf('|', p2 + 1);
  int p4 = packet.indexOf('|', p3 + 1);

  if (p1 < 0 || p2 < 0 || p3 < 0 || p4 < 0) return false;

  int net  = packet.substring(0, p1).toInt();
  int id   = packet.substring(p1 + 1, p2).toInt();
  int low  = packet.substring(p2 + 1, p3).toInt();
  int mid  = packet.substring(p3 + 1, p4).toInt();
  int high = packet.substring(p4 + 1).toInt();

  if (net != NETWORK_ID) return false;
  if (id < 1 || id > 5) return false;

  tankId = id;
  if (high) levelPct = 100;
  else if (mid) levelPct = 66;
  else if (low) levelPct = 33;
  else levelPct = 0;

  return true;
}

void handleTankLine(const String& incoming, const char* logPrefix) {
  Serial.print(logPrefix);
  Serial.println(incoming);

  int tankId;
  int levelPct;
  if (parseTankPacket(incoming, tankId, levelPct)) {
    sendToSupabase(tankNames[tankId - 1], levelPct);
  }
}

#if SIMULATE_LORA
void tickSimulatedLora() {
  bool allow = true;
#if SIMULATE_ONLY_WITHOUT_LORA
  allow = !loraReady;
#endif
  if (!allow) return;

  static unsigned long lastMs = 0;
  static int simTankId = 1;

  unsigned long now = millis();
  if (now - lastMs < SIMULATE_INTERVAL_MS) return;
  lastMs = now;

  // Gercek LoRa parse'i sadece 0/33/66/100 uretir; simde value 0-100 arasi rastgele
  int levelPct = random(0, 101);

  Serial.print("(sim LoRa) ");
  Serial.print(tankNames[simTankId - 1]);
  Serial.print(" -> ");
  Serial.println(levelPct);

  sendToSupabase(tankNames[simTankId - 1], levelPct);

  simTankId++;
  if (simTankId > 5) simTankId = 1;
}
#endif

void loop() {
#if SIMULATE_LORA
  tickSimulatedLora();
#endif

  if (!loraReady) {
    delay(50);
    return;
  }

  int packetSize = LoRa.parsePacket();

  if (packetSize) {
    String incoming = "";

    while (LoRa.available()) {
      incoming += (char)LoRa.read();
    }

    handleTankLine(incoming, "Gelen: ");
  }
}

void sendToSupabase(const char* name, int value) {
  if (WiFi.status() == WL_CONNECTED) {
    HTTPClient http;

    http.begin(supabaseUrl);
    http.addHeader("Content-Type", "application/json");
    http.addHeader("Accept", "application/json");
    http.addHeader("Prefer", "return=representation");
    http.addHeader("apikey", apiKey);
    http.addHeader("Authorization", String("Bearer ") + apiKey);

    String body = "{\"name\":\"" + String(name) + "\",\"value\":\"" + String(value) + "\"}";

    int httpResponseCode = http.POST(body);
    String responseBody = http.getString();

    Serial.print("HTTP Response: ");
    Serial.println(httpResponseCode);
    Serial.print("HTTP Body: ");
    Serial.println(responseBody);

    http.end();
  }
}