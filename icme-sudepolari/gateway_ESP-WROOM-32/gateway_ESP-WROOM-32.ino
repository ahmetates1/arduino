#include <WiFi.h>
#include <HTTPClient.h>

// WiFi Bilgileri
const char* ssid = "İçme muhtarlık";
const char* password = "brtnhn23";

// Supabase Bilgileri
const char* supabaseUrl = "https://ngdozrhycaeiabubrywf.supabase.co/rest/v1/sensor_data";
const char* apiKey = "sb_publishable_DNrEyZFNk13VFNlfE2UhZg_FnVwiHcJ";

// Sistem Ayarları
const int NETWORK_ID = 77;
const char* tankNames[5] = {"YICME", "GEBAN", "TTOKI", "YTOKI", "AICME"};
// Bu depo icin LoRa'dan gecerli paket gelmezse, bu sure sonunda Supabase'e value=null yazilir (tek sefer, yeni paket gelene kadar).
const unsigned long STALE_SILENCE_MS = 5UL * 60UL * 1000UL;

// Pin Tanımlamaları
// Not: Bu proje için çalışan kombinasyon Serial2.begin(..., 27, 26) idi.
// begin(..., rxPin, txPin) formatında çalıştığı için RX=27, TX=26 kullanıyoruz.
#define LORA_RX 27
#define LORA_TX 26
HardwareSerial loraSerial(2);

// WiFi ve Kuyruk Durumu
bool wifiConnected = false;
#define QUEUE_SIZE 20
#define TANK_COUNT 5
struct PendingData {
  char name[12];
  int value;
  bool isNull;
  bool used;
};
PendingData sendQueue[QUEUE_SIZE];

struct TankAggState {
  int lastSentLevel;
  bool initialized;
};
TankAggState tankAgg[TANK_COUNT];

unsigned long lastLoraPacketMs[TANK_COUNT];
bool everReceivedLoRa[TANK_COUNT];
bool staleNullSent[TANK_COUNT];

bool parseLoRaPacket(const String& data, int& id, int& low, int& mid, int& high) {
  // Beklenen format: 77|id|low|mid|high
  // Kurallar:
  // - Tam olarak 4 adet '|'
  // - Ağ kimliği NETWORK_ID olmalı
  // - id 1..5 aralığında olmalı
  // - low/mid/high sadece 0 veya 1 olmalı
  if (data.length() < 9) return false;  // 77|1|0|0|0 minimum uzunluk

  int sepCount = 0;
  for (int i = 0; i < data.length(); i++) {
    char c = data.charAt(i);
    if (!isDigit(c) && c != '|') return false;
    if (c == '|') sepCount++;
  }
  if (sepCount != 4) return false;

  int p1 = data.indexOf('|');
  int p2 = data.indexOf('|', p1 + 1);
  int p3 = data.indexOf('|', p2 + 1);
  int p4 = data.indexOf('|', p3 + 1);
  if (p1 <= 0 || p2 <= p1 + 1 || p3 <= p2 + 1 || p4 <= p3 + 1 || p4 >= data.length() - 1) return false;

  int netId = data.substring(0, p1).toInt();
  if (netId != NETWORK_ID) return false;

  id = data.substring(p1 + 1, p2).toInt();
  low = data.substring(p2 + 1, p3).toInt();
  mid = data.substring(p3 + 1, p4).toInt();
  high = data.substring(p4 + 1).toInt();

  if (id < 1 || id > 5) return false;
  if ((low != 0 && low != 1) || (mid != 0 && mid != 1) || (high != 0 && high != 1)) return false;

  return true;
}

void setup() {
  Serial.begin(115200);
  delay(2000);
  
  Serial.println("\n--- GATEWAY BASLATILIYOR ---");

  // WiFi Başlatma
  WiFi.begin(ssid, password);
  Serial.println("WiFi baglantisi deneniyor...");

  // LoRa Başlatma (9600, rxPin=27 txPin=26)
  loraSerial.begin(9600, SERIAL_8N1, LORA_RX, LORA_TX);
  Serial.println("LoRa (GPIO RX:27 TX:26) Dinleme Aktif.");

  // Kuyruğu temizle
  for (int i = 0; i < QUEUE_SIZE; i++) {
    sendQueue[i].used = false;
    sendQueue[i].isNull = false;
  }
  for (int i = 0; i < TANK_COUNT; i++) {
    tankAgg[i].lastSentLevel = -1;
    tankAgg[i].initialized = false;
    lastLoraPacketMs[i] = 0;
    everReceivedLoRa[i] = false;
    staleNullSent[i] = false;
  }
  
  Serial.println("Sistem Hazir. Veri bekleniyor...\n");
}

void loop() {
  checkWiFi();
  checkStaleSensors();

  // LoRa'dan veri gelmiş mi bak
  if (loraSerial.available()) {
    String incoming = loraSerial.readStringUntil('\n');
    incoming.trim();
    Serial.print("\n[LORA RAW]: ");
    Serial.println(incoming);

    int id, low, mid, high;
    if (parseLoRaPacket(incoming, id, low, mid, high)) {
      Serial.println("[LORA] Gecerli paket.");
      processAndSendData(id, low, mid, high);
    } else {
      Serial.println("[LORA] Gecersiz paket, atlandi.");
    }
  }
}

// Parse edilmiş veriyi işler ve Supabase'e gönderir
void processAndSendData(int id, int low, int mid, int high) {
  const char* name = tankNames[id - 1];
  int tankIdx = id - 1;
  // Her gecerli pakette zaman damgasi (seviye ayni olsa bile) — "veri gelmiyor" icin sessizlik olcumu
  lastLoraPacketMs[tankIdx] = millis();
  everReceivedLoRa[tankIdx] = true;
  staleNullSent[tankIdx] = false;

  // Yüzde Hesaplama
  int levelPct = 0;
  if (high == 1) levelPct = 100;
  else if (mid == 1) levelPct = 66;
  else if (low == 1) levelPct = 33;
  else levelPct = 0;

  Serial.printf(">> %s: %%%d Doluluk (L:%d M:%d H:%d)\n", name, levelPct, low, mid, high);

  // Change-only agregasyon:
  // - Ilk veriyi gonder
  // - Sadece seviye degisirse gonder
  // - Ayni seviyedeki tekrar paketleri bastir
  bool shouldSend = false;
  if (!tankAgg[tankIdx].initialized) {
    shouldSend = true;
    Serial.println("[AGG] Ilk veri, gonderilecek.");
  } else if (tankAgg[tankIdx].lastSentLevel != levelPct) {
    shouldSend = true;
    Serial.println("[AGG] Seviye degisti, aninda gonderilecek.");
  } else {
    Serial.println("[AGG] Ayni seviye, gonderim yok.");
  }

  if (!shouldSend) return;

  if (WiFi.status() == WL_CONNECTED) {
    sendToSupabaseInt(name, levelPct);
  } else {
    queueForSupabaseInt(name, levelPct);
  }

  tankAgg[tankIdx].lastSentLevel = levelPct;
  tankAgg[tankIdx].initialized = true;
}

// --- Supabase ve WiFi Fonksiyonları ---

void sendToSupabaseInt(const char* name, int value) {
  HTTPClient http;
  http.begin(supabaseUrl);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("apikey", apiKey);
  http.addHeader("Authorization", String("Bearer ") + apiKey);

  String body = String("{\"name\":\"") + name + "\",\"value\":" + String(value) + "}";
  int httpCode = http.POST(body);

  if (httpCode > 0) {
    Serial.printf("[HTTP] Basarili, Kod: %d\n", httpCode);
  } else {
    Serial.printf("[HTTP] Hata: %s\n", http.errorToString(httpCode).c_str());
  }
  http.end();
}

// Supabase'de "son kayit veri gelmiyor" anlami icin JSON null (kolon nullable olmali)
void sendToSupabaseNull(const char* name) {
  HTTPClient http;
  http.begin(supabaseUrl);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("apikey", apiKey);
  http.addHeader("Authorization", String("Bearer ") + apiKey);

  String body = String("{\"name\":\"") + name + "\",\"value\":null}";
  int httpCode = http.POST(body);

  if (httpCode > 0) {
    Serial.printf("[HTTP] NULL heartbeat %s, Kod: %d\n", name, httpCode);
  } else {
    Serial.printf("[HTTP] NULL heartbeat hata: %s\n", http.errorToString(httpCode).c_str());
  }
  http.end();
}

void checkStaleSensors() {
  const unsigned long now = millis();
  for (int i = 0; i < TANK_COUNT; i++) {
    if (!everReceivedLoRa[i]) continue;
    if (staleNullSent[i]) continue;
    const unsigned long last = lastLoraPacketMs[i];
    if (last == 0) continue;
    if ((unsigned long)(now - last) < STALE_SILENCE_MS) continue;

    const char* name = tankNames[i];
    Serial.printf("[STALE] 5dk paket yok: %s -> Supabase value=null\n", name);

    if (WiFi.status() == WL_CONNECTED) {
      sendToSupabaseNull(name);
    } else {
      queueForSupabaseNull(name);
    }
    staleNullSent[i] = true;
  }
}

void checkWiFi() {
  if (WiFi.status() == WL_CONNECTED) {
    if (!wifiConnected) {
      wifiConnected = true;
      Serial.println("\n[WIFI] Baglandi! Bekleyen veriler gonderiliyor...");
      flushQueue();
    }
  } else {
    wifiConnected = false;
    static unsigned long lastRetry = 0;
    if (millis() - lastRetry > 10000) { // 10 saniyede bir nokta koy
      Serial.print("x"); 
      lastRetry = millis();
    }
  }
}

void queueForSupabaseInt(const char* name, int value) {
  for (int i = 0; i < QUEUE_SIZE; i++) {
    if (!sendQueue[i].used) {
      strncpy(sendQueue[i].name, name, 11);
      sendQueue[i].name[11] = '\0';
      sendQueue[i].value = value;
      sendQueue[i].isNull = false;
      sendQueue[i].used = true;
      Serial.println("[WIFI YOK] Veri kuyruga alindi.");
      return;
    }
  }
}

void queueForSupabaseNull(const char* name) {
  for (int i = 0; i < QUEUE_SIZE; i++) {
    if (!sendQueue[i].used) {
      strncpy(sendQueue[i].name, name, 11);
      sendQueue[i].name[11] = '\0';
      sendQueue[i].isNull = true;
      sendQueue[i].used = true;
      Serial.println("[WIFI YOK] NULL heartbeat kuyruga alindi.");
      return;
    }
  }
}

void flushQueue() {
  for (int i = 0; i < QUEUE_SIZE; i++) {
    if (sendQueue[i].used) {
      if (sendQueue[i].isNull) {
        sendToSupabaseNull(sendQueue[i].name);
      } else {
        sendToSupabaseInt(sendQueue[i].name, sendQueue[i].value);
      }
      sendQueue[i].used = false;
      sendQueue[i].isNull = false;
      delay(200); // Sunucuyu yormayalım
    }
  }
}