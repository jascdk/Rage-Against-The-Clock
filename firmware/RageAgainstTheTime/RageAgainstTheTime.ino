// ============================================================
//  Rage Against The Time – gig-timer pedal (ESP32-C3)
//  Protokol v2.5
//
//  BLE service 6f8d0100-...
//    0101  COMMAND  (write)         "action:value", fx "start", "duration:1800", "time:20:15:30"
//    0102  STATUS   (read, notify)  hurtig: {"r":1,"t":1234,"d":0}
//                                   r = running, t = remaining (sek, kan være negativ), d = done
//    0103  CONFIG   (read, notify)  indstillinger, se buildConfig()
//
//  Nyt i 2.1:
//    endat:HH:MM[:SS]  Tæl ned til et klokkeslot (kræver at uret er sat). endat:off annullerer.
//    ledesc:on/off     LED skifter farve jo tættere på slut (grøn → gul → orange → rød blink)
//    startat:HH:MM[:SS]  Start timeren automatisk ved klokkeslættet (nyt i 2.2). startat:off annullerer.
//                        Kommer efter endat, så den samlede tid bliver slut minus start.
//
//  Nyt i 2.3: OTA-firmwareopdatering via BLE (se OTA-sektionen)
//    OTA_DATA   6f8d0104  write / write without response  (rå firmware-bytes)
//    OTA_STATUS 6f8d0105  read + notify                    (version, fremdrift, fejl)
//    Kommandoer: ota:begin:<bytes>, ota:end, ota:abort
//
//  Nyt i 2.4: standbyanim:on/off. I standby (skærmen slukket) glider en enkelt decimalprik stille frem og
//    tilbage over de slukkede displays, og lysstyrken sænkes. Config: "sb".
//
//  Nyt i 2.5: diagnostik. To read-only characteristics, som appen læser:
//    DIAG 6f8d0106  temperatur, oppetid, heap, nulstillingsårsag, kommandotællere
//    INFO 6f8d0107  MAC, chip, CPU, flash, partition, byggedato, firmwareversion
//    Config: "ea" (slut-klokkeslot aktivt), "esc" (LED-eskalering), "sa" (automatisk start venter).
//            "dur" er den effektive varighed.
//
//  Al logik kører i loop(). BLE-callbacks lægger kun kommandoer i en kø.
//  Kræver Arduino-ESP32 core 2.x eller 3.x (Bluedroid BLE).
// ============================================================

#include <TM1637Display.h>
#include <Adafruit_NeoPixel.h>
#include <Preferences.h>

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#include <Update.h>          // OTA-opdatering
#include "esp_ota_ops.h"
#include "esp_system.h"
#if __has_include("esp_mac.h")
#include "esp_mac.h"
#endif

#define FW_VERSION "2.8.0"   // hæv ved hver ny udgivelse
#define VERSION_SPLASH_MS 4000   // hvor længe versionsnummeret vises efter en opdatering
#define STANDBY_STEP_MS 650      // standby: tid pr. skridt for prikken der glider hen over displayet
#define STANDBY_BRIGHTNESS 2     // standby: højeste lysstyrke (0-7), så det er roligt at se på

#ifndef HAS_STATUS_LED
#define HAS_STATUS_LED 1
#endif
#ifndef STATUS_LED_PIN
#define STATUS_LED_PIN 7
#endif
#ifndef STATUS_LED_COUNT
#define STATUS_LED_COUNT 1
#endif

// ======= Hardware pins =======
#if CONFIG_IDF_TARGET_ESP32C3
#define CLK 4
#define DIO_DISPLAY_1 5
#define DIO_DISPLAY_2 6
#define FOOTSWITCH_PIN 10
#else
#define CLK 22
#define DIO_DISPLAY_1 21
#define DIO_DISPLAY_2 19
#define FOOTSWITCH_PIN 10
#endif

// ======= BLE UUIDs =======
static const char* SERVICE_UUID = "6f8d0100-2b44-4c1c-a7f9-7d9d2f734301";
static const char* CMD_UUID     = "6f8d0101-2b44-4c1c-a7f9-7d9d2f734301";
static const char* STATUS_UUID  = "6f8d0102-2b44-4c1c-a7f9-7d9d2f734301";
static const char* CONFIG_UUID  = "6f8d0103-2b44-4c1c-a7f9-7d9d2f734301";
static const char* OTA_DATA_UUID   = "6f8d0104-2b44-4c1c-a7f9-7d9d2f734301";
static const char* OTA_STATUS_UUID = "6f8d0105-2b44-4c1c-a7f9-7d9d2f734301";
static const char* DIAG_UUID       = "6f8d0106-2b44-4c1c-a7f9-7d9d2f734301";
static const char* INFO_UUID       = "6f8d0107-2b44-4c1c-a7f9-7d9d2f734301";

TM1637Display display1(CLK, DIO_DISPLAY_1);
TM1637Display display2(CLK, DIO_DISPLAY_2);

#if HAS_STATUS_LED
Adafruit_NeoPixel statusLed(STATUS_LED_COUNT, STATUS_LED_PIN, NEO_GRB + NEO_KHZ800);
bool statusLedInitialized = false;
uint32_t statusLedAppliedColor = 0xFFFFFFFFUL;
int statusLedAppliedBrightness = -1;
#endif

// ======= Segmenter =======
const uint8_t SEG_DASH = 0b01000000;
const uint8_t SEG_H    = 0b01110110;
const uint8_t DIGITS[10] = {
  0b00111111, 0b00000110, 0b01011011, 0b01001111, 0b01100110,
  0b01101101, 0b01111101, 0b00000111, 0b01111111, 0b01101111
};

// ======= Timer state =======
long countdownTime = 1800;
long remainingTimeSigned = 1800;
uint32_t lastUpdate = 0;
bool timerRunning = false;
bool countUp = false;
bool stopwatchMode = false;
bool timerDone = false;
bool underRun = false;
int maxUnderRunMinutes = 5;
int warningTime = 0;
uint32_t doneSinceMs = 0;

// ======= Slut-klokkeslot (endat) – ikke persisteret =======
bool endAtActive = false;
bool startAtActive = false;      // automatisk start venter
uint32_t startAtDeadlineMs = 0;  // millis() når timeren skal startes
uint32_t endAtDeadlineMs = 0;   // millis() når slut-tidspunktet nås
long endAtTotalSecs = 0;        // samlet længde ved indstilling (bruges til ring/LED)

// ======= Ur (sættes fra appen) =======
bool clockSet = false;
uint32_t clockBaseSecs = 0;   // sekunder siden midnat ved sync
uint32_t clockBaseMs = 0;     // millis() ved sync
int clockHours = 0, clockMinutes = 0, clockSeconds = 0;

// ======= Blink / LED =======
bool blinkState = false;
uint32_t lastBlink = 0;
uint32_t underrunBlinkStartMs = 0;
bool isUnderrunBlinking = false;

// ======= Footswitch =======
bool footswitchLastReading = HIGH;
bool footswitchStableState = HIGH;
uint32_t footswitchLastDebounceTime = 0;
const uint32_t FOOTSWITCH_DEBOUNCE_MS = 35UL;
int footswitchClickCount = 0;
uint32_t footswitchFirstClickTime = 0;
const uint32_t DOUBLE_CLICK_WINDOW_MS = 350UL;

// ======= Indstillinger =======
int brightness1 = 7;          // 0-7, uret
int brightness2 = 7;          // 0-7, timeren
int ledBrightness = 50;       // 0-100
bool ledEscalation = true;    // farve-eskalering på status-LED
bool standbyAnim = true;      // standby: prik der glider frem og tilbage i stedet for helt slukket display
bool screensaverEnabled = true;
int screenSaverMinutes = 2;
uint32_t lastInteractionTime = 0;
bool screensaverActive = false;
bool displayFlipped = false;
bool clockAlwaysOn = true;
bool swapDisplays = false;

Preferences prefs;
bool prefsDirty = false;
uint32_t prefsDirtyAt = 0;
bool configDirty = true;

// ======= Display-cache =======
struct PhysDisplay {
  TM1637Display* d;
  uint8_t last[4];
  bool lastColon;
};
PhysDisplay phys1 = { &display1, {0xFF, 0xFF, 0xFF, 0xFF}, false };
PhysDisplay phys2 = { &display2, {0xFF, 0xFF, 0xFF, 0xFF}, false };
bool displayNeedsForceUpdate = true;

uint8_t currentClockSegs[4] = {0, 0, 0, 0};
bool currentClockColon = false;
uint8_t currentTimerSegs[4] = {0, 0, 0, 0};
bool currentTimerColon = false;

bool identifyActive = false;
uint32_t identifyUntilMs = 0;

// ======= OTA (funktioner i OTA-sektionen længere nede) =======
volatile bool otaActive = false;   // en firmware-overførsel er i gang
bool otaShowPrep = false;          // viser "UP--" mens flash slettes
uint32_t otaTotal = 0;             // forventet filstørrelse
uint32_t otaReceived = 0;          // bytes skrevet til flash

// ======= Versionsvisning efter opdatering =======
bool versionSplashActive = false;
uint32_t versionSplashStartMs = 0;

// ======= Diagnostik =======
float diagTempC = 0.0f;
uint32_t diagHeap = 0, diagMinHeap = 0, diagLastMs = 0;
volatile uint32_t cmdReceived = 0, cmdDropped = 0, cmdRejected = 0;   // BLE-kommandoer: modtaget / tabt (kø fuld) / afvist

// ======= BLE state =======
BLEServer* bleServer = nullptr;
BLECharacteristic* bleStatusCharacteristic = nullptr;
BLECharacteristic* bleConfigCharacteristic = nullptr;
volatile bool bleClientConnected = false;
volatile bool needRestartAdvertising = false;
volatile uint32_t disconnectedAtMs = 0;

struct BleCmd { char text[64]; };
static QueueHandle_t cmdQueue = nullptr;

// ============================================================
//  Hjælpefunktioner
// ============================================================
const char* getTimerModeName() {
  return stopwatchMode ? "stopwatch" : (countUp ? "countup" : "countdown");
}

// Den varighed ringen og LED'en regner ud fra
long effectiveDuration() {
  return endAtActive ? endAtTotalSecs : countdownTime;
}

void markSettingsChanged() {
  prefsDirty = true;
  prefsDirtyAt = millis();
  configDirty = true;
}

static bool parseHms(const String& v, int& h, int& m, int& s) {
  h = 0; m = 0; s = 0;
  int n = sscanf(v.c_str(), "%d:%d:%d", &h, &m, &s);
  return n >= 2 && h >= 0 && h <= 23 && m >= 0 && m <= 59 && s >= 0 && s <= 59;
}

uint32_t clockSecsOfDay(uint32_t now) {
  return (clockBaseSecs + (now - clockBaseMs) / 1000UL) % 86400UL;
}

uint8_t rotateSegment180(uint8_t seg) {
  uint8_t raw = seg & 0x7F;
  uint8_t f = 0;
  if (raw & (1 << 0)) f |= (1 << 3);
  if (raw & (1 << 1)) f |= (1 << 4);
  if (raw & (1 << 2)) f |= (1 << 5);
  if (raw & (1 << 3)) f |= (1 << 0);
  if (raw & (1 << 4)) f |= (1 << 1);
  if (raw & (1 << 5)) f |= (1 << 2);
  if (raw & (1 << 6)) f |= (1 << 6);
  return f | (seg & 0x80);          // decimalpunktet følger cifferet (sidder fast på modulet)
}

void applyDisplayBrightness() {
  // brightness1 hører til uret, brightness2 til timeren, uanset hvilket fysisk display der bruges
  int bClock = brightness1, bTimer = brightness2;
  if (screensaverActive && standbyAnim) {                    // standby: dæmp de displays, der viser prikken
    bTimer = min(bTimer, STANDBY_BRIGHTNESS);
    if (!clockAlwaysOn) bClock = min(bClock, STANDBY_BRIGHTNESS);
  }
  display1.setBrightness(swapDisplays ? bTimer : bClock);
  display2.setBrightness(swapDisplays ? bClock : bTimer);
  displayNeedsForceUpdate = true;   // setBrightness virker først ved næste setSegments
}

void applyLedBrightness() {
#if HAS_STATUS_LED
  if (!statusLedInitialized) return;
  int target = constrain(map(ledBrightness, 0, 100, 0, 255), 0, 255);
  if (target != statusLedAppliedBrightness) {
    statusLed.setBrightness(target);
    statusLedAppliedBrightness = target;
    statusLedAppliedColor = 0xFFFFFFFFUL;
  }
#endif
}

// ============================================================
//  Display
// ============================================================
void writePhysicalDisplay(PhysDisplay& p, const uint8_t segs[4], bool colon) {
  uint8_t f[4];
  for (int i = 0; i < 4; i++) {
    f[i] = displayFlipped ? rotateSegment180(segs[3 - i]) : segs[i];   // bit 7 = decimalprik
  }
  if (colon) f[1] |= 0x80;

  bool changed = displayNeedsForceUpdate || (colon != p.lastColon);
  for (int i = 0; i < 4 && !changed; i++) {
    if (f[i] != p.last[i]) changed = true;
  }
  if (changed) {
    p.d->setSegments(f);
    memcpy(p.last, f, 4);
    p.lastColon = colon;
  }
}

void renderDisplays(const uint8_t clockSegs[4], bool clockColon, const uint8_t timerSegs[4], bool timerColon) {
  if (swapDisplays) {
    writePhysicalDisplay(phys1, timerSegs, timerColon);
    writePhysicalDisplay(phys2, clockSegs, clockColon);
  } else {
    writePhysicalDisplay(phys1, clockSegs, clockColon);
    writePhysicalDisplay(phys2, timerSegs, timerColon);
  }
  displayNeedsForceUpdate = false;   // ryd flaget, ellers virker cachen aldrig
}

// ============================================================
//  Versionsvisning: første gang et nyt versionsnummer starter (efter OTA eller USB), vises det et øjeblik.
//  "2.7.1" vises som cifre med decimalpunktum på timer-displayet, og ur-displayet viser "UEr".
//  Lange versioner (mere end 4 cifre) ruller hen over displayet.
// ============================================================
static int buildVersionSegments(uint8_t* out, int maxN) {
  int n = 0;
  for (const char* c = FW_VERSION; *c && n < maxN; c++) {
    if (*c >= '0' && *c <= '9') out[n++] = DIGITS[*c - '0'];
    else if (*c == '.' && n > 0) out[n - 1] |= 0x80;          // decimalpunktum efter foregående ciffer
  }
  return n;
}

static void versionSplashSegments(uint8_t seg[4]) {
  uint8_t v[16];
  int n = buildVersionSegments(v, 16);
  for (int i = 0; i < 4; i++) seg[i] = 0;
  if (n <= 4) {
    int off = 4 - n;                                          // højrejusteret: _ 2. 7. 1
    for (int i = 0; i < n; i++) seg[off + i] = v[i];
  } else {
    int start = (int)((millis() - versionSplashStartMs) / 500UL) % (n + 4) - 3;
    for (int i = 0; i < 4; i++) {
      int k = start + i;
      seg[i] = (k >= 0 && k < n) ? v[k] : 0;
    }
  }
}

static uint32_t versionSplashDurationMs() {
  uint8_t v[16];
  int n = buildVersionSegments(v, 16);
  return n <= 4 ? (uint32_t)VERSION_SPLASH_MS : (uint32_t)(n + 4) * 500UL;
}

// Husker hvilken version der sidst blev startet. Er den ny, startes versionsvisningen.
void checkVersionSplash() {
  prefs.end();                                                // sikrer at navnerummet ikke allerede er åbent
  prefs.begin("timer", false);
  String last = prefs.getString("fwVer", "");
  if (last != FW_VERSION) {
    prefs.putString("fwVer", FW_VERSION);
    versionSplashActive = true;
    versionSplashStartMs = millis();
  }
  prefs.end();
}

// Standby: én decimalprik (bit 7) glider stille 0,1,2,3,2,1,0... hen over displayet
static void standbySweep(uint8_t segs[4]) {
  static const uint8_t seq[6] = {0, 1, 2, 3, 2, 1};
  uint8_t pos = seq[(millis() / STANDBY_STEP_MS) % 6];
  for (int i = 0; i < 4; i++) segs[i] = (i == pos) ? 0x80 : 0;
}

void prepareClockData() {
  if (versionSplashActive) {                 // "UEr" ud for versionsnummeret
    currentClockSegs[0] = 0;
    currentClockSegs[1] = 0b00111110;        // U
    currentClockSegs[2] = 0b01111001;        // E
    currentClockSegs[3] = 0b01010000;        // r
    currentClockColon = false;
    return;
  }
  if (screensaverActive && !clockAlwaysOn) {
    for (int i = 0; i < 4; i++) currentClockSegs[i] = 0;
    if (standbyAnim) standbySweep(currentClockSegs);
    currentClockColon = false;
    return;
  }
  currentClockColon = (millis() / 500) % 2 == 0;
  if (!clockSet) {                       // vis --:-- indtil appen har sendt tiden
    for (int i = 0; i < 4; i++) currentClockSegs[i] = SEG_DASH;
    return;
  }
  currentClockSegs[0] = DIGITS[clockHours / 10];
  currentClockSegs[1] = DIGITS[clockHours % 10];
  currentClockSegs[2] = DIGITS[clockMinutes / 10];
  currentClockSegs[3] = DIGITS[clockMinutes % 10];
}

void prepareTimerData(long seconds) {
  if (versionSplashActive) {
    versionSplashSegments(currentTimerSegs);
    currentTimerColon = false;
    return;
  }
  if (screensaverActive) {
    for (int i = 0; i < 4; i++) currentTimerSegs[i] = 0;
    if (standbyAnim) standbySweep(currentTimerSegs);
    currentTimerColon = false;
    return;
  }
  if (timerDone) {
    currentTimerSegs[0] = 0b01011110;  // d (uden den øverste venstre bjælke)
    currentTimerSegs[1] = 0b00111111;  // O
    currentTimerSegs[2] = 0b00110111;  // n
    currentTimerSegs[3] = 0b01111001;  // E
    currentTimerColon = false;
    return;
  }

  bool neg = seconds < 0;
  long absSeconds = neg ? -seconds : seconds;
  currentTimerColon = timerRunning ? ((millis() / 500) % 2 == 0) : true;

  if (absSeconds >= 3600) {
    int h = (absSeconds / 3600) % 10;
    int m = (absSeconds % 3600) / 60;
    currentTimerSegs[0] = neg ? SEG_DASH : SEG_H;
    currentTimerSegs[1] = DIGITS[h];
    currentTimerSegs[2] = DIGITS[m / 10];
    currentTimerSegs[3] = DIGITS[m % 10];
  } else {
    int m = absSeconds / 60;
    int s = absSeconds % 60;
    // Minus vises kun ved under 10 min under-run. Ved 10+ min vises MM:SS uden minus (ingen plads).
    currentTimerSegs[0] = (neg && m < 10) ? SEG_DASH : DIGITS[m / 10];
    currentTimerSegs[1] = DIGITS[m % 10];
    currentTimerSegs[2] = DIGITS[s / 10];
    currentTimerSegs[3] = DIGITS[s % 10];
  }
}

void refreshAllDisplays() {
  if (otaActive || otaShowPrep) {
    const uint8_t blank[4] = {0, 0, 0, 0};
    uint8_t seg[4];
    seg[0] = 0b00111110;                       // U
    if (otaShowPrep) {
      seg[1] = 0b01110011;                     // P
      seg[2] = SEG_DASH;
      seg[3] = SEG_DASH;
    } else {
      int pct = otaTotal ? (int)(((uint64_t)otaReceived * 100ULL) / otaTotal) : 0;
      if (pct >= 100) { seg[1] = DIGITS[1]; seg[2] = DIGITS[0]; seg[3] = DIGITS[0]; }
      else            { seg[1] = 0;         seg[2] = DIGITS[pct / 10]; seg[3] = DIGITS[pct % 10]; }
    }
    renderDisplays(blank, false, seg, false);
    return;
  }
  if (identifyActive) {
    const uint8_t s1[4] = {0, 0, 0, DIGITS[1]};
    const uint8_t s2[4] = {0, 0, 0, DIGITS[2]};
    renderDisplays(s1, false, s2, false);   // 1 = ur, 2 = timer
    return;
  }
  prepareClockData();
  prepareTimerData(remainingTimeSigned);
  renderDisplays(currentClockSegs, currentClockColon, currentTimerSegs, currentTimerColon);
}

// ============================================================
//  Status-LED
// ============================================================
#if HAS_STATUS_LED

// Original opførsel (ledesc:off): blå = kører, blinkende rød i advarselszonen, grøn = ellers
uint32_t legacyLedColor(uint32_t now) {
  if (isUnderrunBlinking) {
    if (now - underrunBlinkStartMs < 3000) {
      return blinkState ? statusLed.Color(255, 0, 0) : statusLed.Color(0, 0, 0);
    }
    isUnderrunBlinking = false;
    return statusLed.Color(0, 255, 0);
  }
  if (screensaverActive && !clockAlwaysOn) return statusLed.Color(255, 0, 0);
  if (timerRunning) {
    bool warn = (!countUp && warningTime > 0 && remainingTimeSigned <= (long)warningTime * 60 && remainingTimeSigned > 0);
    if (warn) return blinkState ? statusLed.Color(255, 0, 0) : statusLed.Color(0, 0, 0);
    if (remainingTimeSigned < 0) return statusLed.Color(0, 255, 0);
    return statusLed.Color(0, 0, 255);
  }
  return statusLed.Color(0, 255, 0);
}

// Eskalerende farver: grøn → gul → orange → rød blink der bliver hurtigere mod slut
//   Ikke i gang: blå. Færdig: hurtigt rødt blink i 5 sek., derefter fast rød.
//   Vinduet E er advarselstiden (eller 5 min), dog højst 1/3 af den samlede tid.
uint32_t escalatingLedColor(uint32_t now) {
  const uint32_t OFF     = statusLed.Color(0, 0, 0);
  const uint32_t RED     = statusLed.Color(255, 0, 0);
  const uint32_t DIM_RED = statusLed.Color(60, 0, 0);

  if (isUnderrunBlinking) {
    if (now - underrunBlinkStartMs < 3000) return blinkState ? RED : OFF;
    isUnderrunBlinking = false;
  }
  if (screensaverActive && !clockAlwaysOn) return RED;
  if (timerDone) {
    if (now - doneSinceMs < 5000) return blinkState ? RED : OFF;
    return RED;
  }
  if (!timerRunning) return statusLed.Color(0, 0, 255);
  if (stopwatchMode) return statusLed.Color(0, 255, 0);

  long total = countUp ? countdownTime : effectiveDuration();
  long toEnd = countUp ? (countdownTime - remainingTimeSigned) : remainingTimeSigned;

  long E = (warningTime > 0) ? (long)warningTime * 60 : 300;
  if (E > total / 3) E = total / 3;
  if (E < 30) E = 30;
  long half = E / 2;

  if (toEnd < 0) {                                   // over tid: rød, langsom puls
    return ((now / 600) % 2 == 0) ? RED : DIM_RED;
  }
  if (toEnd > 2 * E) return statusLed.Color(0, 255, 0);      // grøn
  if (toEnd > E)     return statusLed.Color(255, 170, 0);    // gul
  if (toEnd > half)  return statusLed.Color(255, 60, 0);     // orange

  // Rød puls: halv periode går fra 1000 ms (ved E/2) ned til 125 ms (ved 0)
  uint32_t halfPeriod = 125 + (uint32_t)((875L * toEnd) / (half > 0 ? half : 1));
  return ((now / halfPeriod) % 2 == 0) ? RED : DIM_RED;
}

#endif

void updateStatusLed() {
#if HAS_STATUS_LED
  if (!statusLedInitialized) return;
  uint32_t now = millis();
  uint32_t target;
  if (otaActive || otaShowPrep) {                       // lilla puls under firmwareopdatering
    target = ((now / 300) % 2 == 0) ? statusLed.Color(170, 0, 255) : statusLed.Color(40, 0, 70);
  } else {
    target = ledEscalation ? escalatingLedColor(now) : legacyLedColor(now);
  }

  applyLedBrightness();
  if (target != statusLedAppliedColor) {
    for (int i = 0; i < STATUS_LED_COUNT; ++i) statusLed.setPixelColor(i, target);
    statusLed.show();
    statusLedAppliedColor = target;
  }
#endif
}

// ============================================================
//  Timer-kontrol
// ============================================================
void registerInteraction() {
  lastInteractionTime = millis();
  if (screensaverActive) {
    screensaverActive = false;
    displayNeedsForceUpdate = true;
  }
}

// Tilbage til normal timer (afbryder også et slut-klokkeslot)
void resetValues() {
  endAtActive = false;
  startAtActive = false;
  remainingTimeSigned = countUp ? 0 : countdownTime;
  timerDone = false;
  isUnderrunBlinking = false;
  configDirty = true;
}

void startTimerControl() {
  registerInteraction();
  if (startAtActive) { startAtActive = false; configDirty = true; }   // manuel start annullerer auto-start
  if (timerDone) resetValues();          // start efter DONE = nyt sæt
  timerRunning = true;
  lastUpdate = millis();
  isUnderrunBlinking = false;
  displayNeedsForceUpdate = true;
}

void stopTimerControl() {
  registerInteraction();
  timerRunning = false;
  isUnderrunBlinking = false;
  displayNeedsForceUpdate = true;
}

void resetTimerControl() {
  registerInteraction();
  timerRunning = false;
  resetValues();
  displayNeedsForceUpdate = true;
}

void toggleTimerControl() {
  if (timerRunning) stopTimerControl();
  else startTimerControl();
}

void tickTimer() {
  if (countUp) {
    remainingTimeSigned++;
    if (!stopwatchMode && remainingTimeSigned >= countdownTime) {
      timerRunning = false;
      timerDone = true;
    }
  } else {
    remainingTimeSigned--;
    if (underRun) {
      if (remainingTimeSigned == 0) {          // blink 3 sek. præcis ved nul
        isUnderrunBlinking = true;
        underrunBlinkStartMs = millis();
      }
      if (remainingTimeSigned <= -((long)maxUnderRunMinutes * 60)) {
        timerRunning = false;
        timerDone = true;
      }
    } else if (remainingTimeSigned <= 0) {
      remainingTimeSigned = 0;
      timerRunning = false;
      timerDone = true;
    }
  }
}

// Slut-klokkeslot: resttiden regnes ud fra en fast deadline, så et sent start
// automatisk giver kortere tid. Opdateres også, mens timeren er pauset (live visning).
void updateEndAt(uint32_t now) {
  int32_t diff = (int32_t)(endAtDeadlineMs - now);
  long rem = (diff >= 0) ? (diff + 999L) / 1000L : -((-(long)diff) / 1000L);
  if (rem == remainingTimeSigned) return;

  long prev = remainingTimeSigned;

  if (!timerRunning && rem <= 0) {         // udløbet uden at være startet: tilbage til normal timer
    resetValues();
    displayNeedsForceUpdate = true;
    return;
  }

  remainingTimeSigned = rem;
  if (!timerRunning) return;

  if (underRun) {
    if (prev > 0 && rem <= 0) {            // blink 3 sek. ved nulgennemgang
      isUnderrunBlinking = true;
      underrunBlinkStartMs = now;
    }
    if (rem <= -((long)maxUnderRunMinutes * 60)) {
      timerRunning = false;
      timerDone = true;
    }
  } else if (rem <= 0) {
    remainingTimeSigned = 0;
    timerRunning = false;
    timerDone = true;
  }
}

// ============================================================
//  Preferences (NVS)
// ============================================================
void savePrefs() {
  prefs.begin("timer", false);
  prefs.putLong("countdown", countdownTime);
  prefs.putBool("countUp", countUp);
  prefs.putBool("stopwatch", stopwatchMode);
  prefs.putInt("warning", warningTime);
  prefs.putBool("underRun", underRun);
  prefs.putInt("maxURMins", maxUnderRunMinutes);
  prefs.putInt("bright1", brightness1);
  prefs.putInt("bright2", brightness2);
  prefs.putInt("ledBright", ledBrightness);
  prefs.putBool("ledEsc", ledEscalation);
  prefs.putBool("standbyAnim", standbyAnim);
  prefs.putBool("scrEnabled", screensaverEnabled);
  prefs.putInt("scrMins", screenSaverMinutes);
  prefs.putBool("flipped", displayFlipped);
  prefs.putBool("clockAlways", clockAlwaysOn);
  prefs.putBool("swapDisp", swapDisplays);
  prefs.end();
}

void loadPrefs() {
  prefs.begin("timer", true);
  countdownTime = constrain(prefs.getLong("countdown", 1800), 1L, 35999L);
  countUp = prefs.getBool("countUp", false);
  stopwatchMode = prefs.getBool("stopwatch", false);
  warningTime = constrain(prefs.getInt("warning", 0), 0, 60);
  underRun = prefs.getBool("underRun", false);
  maxUnderRunMinutes = constrain(prefs.getInt("maxURMins", 5), 0, 60);
  brightness1 = constrain(prefs.getInt("bright1", 7), 0, 7);
  brightness2 = constrain(prefs.getInt("bright2", 7), 0, 7);
  ledBrightness = constrain(prefs.getInt("ledBright", 50), 0, 100);
  ledEscalation = prefs.getBool("ledEsc", true);
  standbyAnim = prefs.getBool("standbyAnim", true);
  screensaverEnabled = prefs.getBool("scrEnabled", true);
  screenSaverMinutes = constrain(prefs.getInt("scrMins", 2), 1, 60);
  displayFlipped = prefs.getBool("flipped", false);
  clockAlwaysOn = prefs.getBool("clockAlways", true);
  swapDisplays = prefs.getBool("swapDisp", false);
  prefs.end();
  remainingTimeSigned = countUp ? 0 : countdownTime;
}

// ============================================================
//  BLE: status og config
// ============================================================
static void publishValue(BLECharacteristic* ch, const char* buf) {
  ch->setValue((uint8_t*)buf, strlen(buf));
  if (bleClientConnected) ch->notify();
}

void buildConfig(char* out, size_t n) {
  snprintf(out, n,
    "{\"mode\":\"%s\",\"dur\":%ld,\"b1\":%d,\"b2\":%d,\"led\":%d,\"warn\":%d,\"ur\":%d,"
    "\"mur\":%d,\"flip\":%d,\"clk\":%d,\"swap\":%d,\"scr\":%d,\"scrm\":%d,\"ts\":%d,"
    "\"ea\":%d,\"esc\":%d,\"sa\":%d,\"sb\":%d}",
    getTimerModeName(), effectiveDuration(), brightness1, brightness2, ledBrightness, warningTime,
    underRun ? 1 : 0, maxUnderRunMinutes, displayFlipped ? 1 : 0, clockAlwaysOn ? 1 : 0,
    swapDisplays ? 1 : 0, screensaverEnabled ? 1 : 0, screenSaverMinutes, clockSet ? 1 : 0,
    endAtActive ? 1 : 0, ledEscalation ? 1 : 0, startAtActive ? 1 : 0, standbyAnim ? 1 : 0);
}

void updateBleStatus() {
  if (!bleStatusCharacteristic) return;
  static int lastRun = -1, lastDone = -1;
  static long lastRemaining = 0x7FFFFFFF;
  int run = timerRunning ? 1 : 0;
  int done = timerDone ? 1 : 0;
  if (run == lastRun && done == lastDone && remainingTimeSigned == lastRemaining) return;

  char buf[48];
  snprintf(buf, sizeof(buf), "{\"r\":%d,\"t\":%ld,\"d\":%d}", run, remainingTimeSigned, done);
  publishValue(bleStatusCharacteristic, buf);
  lastRun = run; lastDone = done; lastRemaining = remainingTimeSigned;
}

void updateBleConfig() {
  if (!bleConfigCharacteristic || !configDirty) return;
  char buf[192];
  buildConfig(buf, sizeof(buf));
  publishValue(bleConfigCharacteristic, buf);
  configDirty = false;
}

// ============================================================
//  OTA-firmwareopdatering via BLE
//
//    App    → COMMAND     "ota:begin:<bytes>"   klargør (sletter flash, op til ~15 sek.)
//    Pedal  → OTA_STATUS  {"s":"ready"}
//    App    → OTA_DATA    rå firmware-bytes i pakker (write without response)
//    Pedal  → OTA_STATUS  {"s":"p","o":<bytes skrevet>}  hver 2 KB og som heartbeat hvert 500 ms
//    App    → COMMAND     "ota:end"             når alle bytes er kvitteret
//    Pedal  → OTA_STATUS  {"s":"done"}          og genstarter derefter
//    Fejl:    {"s":"err","m":"<kode>"}          Afbryd: "ota:abort"
//    Læsning af OTA_STATUS (i hvile) giver {"fw":..,"ota":..,"max":..,"up":..}
//
//  Kræver en partitionstabel med to app-pladser (fx "Default 4MB with spiffs").
// ============================================================
#define OTA_CHUNK_MAX 184
struct OtaChunk { uint16_t len; uint8_t data[OTA_CHUNK_MAX]; };

static QueueHandle_t otaQueue = nullptr;
static BLECharacteristic* bleOtaStatus = nullptr;
static volatile bool otaOverflow = false;
static bool otaHeaderChecked = false;
static uint32_t otaLastAck = 0;
static uint32_t otaLastAckMs = 0;
static uint32_t otaLastDataMs = 0;
static uint32_t otaRebootAt = 0;

#ifdef CONFIG_APP_ROLLBACK_ENABLE
// En ny firmware markeres først som gyldig, når den har kørt stabilt i 10 sek. (se loop).
// Går den ned før da, ruller bootloaderen tilbage til den forrige version.
extern "C" bool verifyRollbackLater() { return true; }
#endif

static void otaNotify(const char* json) {
  if (!bleOtaStatus) return;
  bleOtaStatus->setValue((uint8_t*)json, strlen(json));
  if (bleClientConnected) bleOtaStatus->notify();
}

static void otaNotifyError(const char* code) {
  char buf[48];
  snprintf(buf, sizeof(buf), "{\"s\":\"err\",\"m\":\"%s\"}", code);
  otaNotify(buf);
}

static void otaCleanup() {
  otaActive = false;
  otaShowPrep = false;
  if (otaQueue) xQueueReset(otaQueue);
  displayNeedsForceUpdate = true;
}

static void otaFail(const char* code) {
  if (otaActive) Update.abort();
  otaCleanup();
  otaNotifyError(code);
}

static void otaAbort() {
  bool was = otaActive;
  if (was) Update.abort();
  otaCleanup();
  if (was) otaNotify("{\"s\":\"aborted\"}");
}

static void otaBegin(uint32_t size) {
  if (otaActive) { otaFail("busy"); return; }
  if (timerRunning) { otaNotifyError("running"); return; }

  const esp_partition_t* part = esp_ota_get_next_update_partition(nullptr);
  if (!part) { otaNotifyError("nopart"); return; }
  if (size < 100000UL || size > part->size) { otaNotifyError("size"); return; }

  // Sletning af flash blokerer loop() i op til ~15 sek. Vis det på displayet først.
  otaShowPrep = true;
  refreshAllDisplays();
  updateStatusLed();
  bool ok = Update.begin(size, U_FLASH);
  otaShowPrep = false;
  if (!ok) { displayNeedsForceUpdate = true; otaNotifyError("begin"); return; }

  if (otaQueue) xQueueReset(otaQueue);
  otaTotal = size;
  otaReceived = 0;
  otaLastAck = 0;
  otaHeaderChecked = false;
  otaOverflow = false;
  otaLastDataMs = millis();
  otaLastAckMs = millis();
  otaActive = true;
  displayNeedsForceUpdate = true;
  otaNotify("{\"s\":\"ready\"}");
}

static void otaEnd() {
  if (!otaActive) { otaNotifyError("state"); return; }
  if (otaReceived != otaTotal) { otaFail("size"); return; }

  bool ok = Update.end(true);              // verificerer image og skifter boot-partition
  if (!ok || !Update.isFinished()) { otaCleanup(); otaNotifyError("end"); return; }

  otaCleanup();
  otaNotify("{\"s\":\"done\"}");
  otaRebootAt = millis() + 1500;           // giv BLE tid til at sende "done"
}

// Kører i loop(): skriver modtagne pakker til flash og kvitterer
static void otaProcess(uint32_t now) {
  if (!otaActive) return;
  now = millis();   // frisk tid: otaBegin() kan have blokeret i mange sekunder siden loop() startede

  if (otaOverflow)         { otaFail("overflow");   return; }
  if (!bleClientConnected) { otaFail("disconnect"); return; }
  if ((int32_t)(now - otaLastDataMs) > 20000) { otaFail("timeout"); return; }

  OtaChunk item;
  int budget = 16;                          // begræns arbejdet pr. loop, så displayet ikke hakker
  while (budget-- > 0 && xQueueReceive(otaQueue, &item, 0) == pdTRUE) {
    otaLastDataMs = now;

    if (!otaHeaderChecked) {                // første pakke: ESP-image-header + app-descriptor
      if (item.len < 36 || item.data[0] != 0xE9 ||
          item.data[32] != 0x32 || item.data[33] != 0x54 ||
          item.data[34] != 0xCD || item.data[35] != 0xAB) {
        otaFail("magic");
        return;
      }
      otaHeaderChecked = true;
    }
    if (otaReceived + item.len > otaTotal) { otaFail("size"); return; }

    size_t written = Update.write(item.data, item.len);
    if (written != item.len) { otaFail("write"); return; }
    otaReceived += item.len;
  }

  bool full = (otaReceived == otaTotal && otaLastAck != otaReceived);
  if (full || (otaReceived - otaLastAck) >= 2048 || (now - otaLastAckMs) >= 500) {
    otaLastAck = otaReceived;
    otaLastAckMs = now;
    char buf[40];
    snprintf(buf, sizeof(buf), "{\"s\":\"p\",\"o\":%lu}", (unsigned long)otaReceived);
    otaNotify(buf);
  }
}

// BLE-callback: må kun lægge data i kø (blokerer kort, hvis køen er fuld = naturlig back-pressure)
class OtaDataCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* characteristic) override {
    if (!otaActive || otaQueue == nullptr) return;
    size_t len = characteristic->getLength();
    uint8_t* data = characteristic->getData();
    if (len == 0 || data == nullptr) return;
    if (len > OTA_CHUNK_MAX) { otaOverflow = true; return; }

    OtaChunk item;
    item.len = (uint16_t)len;
    memcpy(item.data, data, len);
    if (xQueueSend(otaQueue, &item, pdMS_TO_TICKS(250)) != pdTRUE) otaOverflow = true;
  }
};

// Ved læsning (i hvile) opdateres værdien med version, OTA-plads og oppetid
class OtaStatusCallbacks : public BLECharacteristicCallbacks {
  void onRead(BLECharacteristic* characteristic) override {
    if (otaActive) return;
    const esp_partition_t* part = esp_ota_get_next_update_partition(nullptr);
    char buf[96];
    snprintf(buf, sizeof(buf), "{\"fw\":\"%s\",\"ota\":%d,\"max\":%lu,\"up\":%lu}",
             FW_VERSION, part ? 1 : 0,
             part ? (unsigned long)part->size : 0UL,
             (unsigned long)(millis() / 1000UL));
    characteristic->setValue((uint8_t*)buf, strlen(buf));
  }
};

// ============================================================
//  Diagnostik: DIAG (dynamisk) og INFO (statisk). Begge kan læses af appen.
//  Temperatur og heap opdateres i loop() en gang i sekundet, så BLE-callbacken kun formaterer tal.
// ============================================================
static void diagUpdate() {
  diagTempC = temperatureRead();               // chippens kernetemperatur (ikke rumtemperatur)
  diagHeap = ESP.getFreeHeap();
  diagMinHeap = ESP.getMinFreeHeap();
}

static const char* resetReasonText() {
  switch (esp_reset_reason()) {
    case ESP_RST_POWERON:   return "poweron";
    case ESP_RST_EXT:       return "ext";
    case ESP_RST_SW:        return "sw";
    case ESP_RST_PANIC:     return "panic";
    case ESP_RST_INT_WDT:   return "intwdt";
    case ESP_RST_TASK_WDT:  return "taskwdt";
    case ESP_RST_WDT:       return "wdt";
    case ESP_RST_DEEPSLEEP: return "deepsleep";
    case ESP_RST_BROWNOUT:  return "brownout";
    default:                return "other";
  }
}

class DiagCallbacks : public BLECharacteristicCallbacks {
  void onRead(BLECharacteristic* characteristic) override {
    char buf[128];
    snprintf(buf, sizeof(buf),
             "{\"tc\":%.1f,\"up\":%lu,\"hp\":%lu,\"hm\":%lu,\"rr\":\"%s\",\"cr\":%lu,\"cd\":%lu,\"cx\":%lu}",
             diagTempC,
             (unsigned long)(millis() / 1000UL),
             (unsigned long)diagHeap, (unsigned long)diagMinHeap,
             resetReasonText(),
             (unsigned long)cmdReceived, (unsigned long)cmdDropped, (unsigned long)cmdRejected);
    characteristic->setValue((uint8_t*)buf, strlen(buf));
  }
};

class InfoCallbacks : public BLECharacteristicCallbacks {
  void onRead(BLECharacteristic* characteristic) override {
    uint8_t mac[6] = {0};
    esp_read_mac(mac, ESP_MAC_BT);
    const esp_partition_t* running = esp_ota_get_running_partition();
    char buf[200];
    snprintf(buf, sizeof(buf),
             "{\"mac\":\"%02X:%02X:%02X:%02X:%02X:%02X\",\"ch\":\"%s\",\"rev\":%d,\"cpu\":%d,"
             "\"fl\":%lu,\"ss\":%lu,\"pt\":\"%s\",\"bd\":\"%s %s\",\"fw\":\"%s\"}",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
             ESP.getChipModel(), (int)ESP.getChipRevision(), (int)getCpuFrequencyMhz(),
             (unsigned long)ESP.getFlashChipSize(), (unsigned long)ESP.getSketchSize(),
             running ? running->label : "?", __DATE__, __TIME__, FW_VERSION);
    characteristic->setValue((uint8_t*)buf, strlen(buf));
  }
};

// ============================================================
//  BLE: kommandoer (kører i loop()-tasken)
// ============================================================
static bool parseBool(const String& v) { return v == "1" || v == "on" || v == "true"; }

bool handleBleCommand(const String& input) {
  String command = input;
  command.trim();
  command.toLowerCase();
  if (command.length() == 0) return false;

  // Første separator afgør, hvor action slutter
  int split = -1;
  for (unsigned i = 0; i < command.length(); i++) {
    char c = command[i];
    if (c == ':' || c == '=' || c == ' ') { split = i; break; }
  }
  String action = command;
  String value = "";
  if (split >= 0) {
    action = command.substring(0, split);
    value = command.substring(split + 1);
    action.trim();
    value.trim();
  }

  // Tidssync må hverken vække skærmen eller nulstille screensaver-timeren
  if (action == "time" || action == "settime") {
    int h, m, s;
    if (!parseHms(value, h, m, s)) return false;
    clockBaseSecs = (uint32_t)h * 3600UL + (uint32_t)m * 60UL + (uint32_t)s;
    clockBaseMs = millis();
    if (!clockSet) { clockSet = true; configDirty = true; }
    return true;
  }

  registerInteraction();   // alle andre kommandoer tæller som brug

  if (action == "ota") {                                   // ota:begin:<bytes> | ota:end | ota:abort
    if (value.startsWith("begin:")) { otaBegin((uint32_t)strtoul(value.c_str() + 6, nullptr, 10)); return true; }
    if (value == "end")   { otaEnd();   return true; }
    if (value == "abort") { otaAbort(); return true; }
    return false;
  }
  if (otaActive) return false;                             // øvrige kommandoer ignoreres under opdatering

  if (action == "start")  { startTimerControl(); return true; }
  if (action == "stop")   { stopTimerControl();  return true; }
  if (action == "reset")  { resetTimerControl(); return true; }
  if (action == "toggle") { toggleTimerControl(); return true; }

  if (action == "endat") {
    if (value == "off") {
      if (endAtActive) { resetValues(); displayNeedsForceUpdate = true; }
      return true;
    }
    if (!clockSet) return false;                       // kræver at appen har sendt klokken
    int h, m, s;
    if (!parseHms(value, h, m, s)) return false;

    uint32_t now = millis();
    uint32_t target = (uint32_t)h * 3600UL + (uint32_t)m * 60UL + (uint32_t)s;
    uint32_t delta = (target + 86400UL - clockSecsOfDay(now)) % 86400UL;   // næste forekomst
    if (delta < 1 || delta > 35999UL) return false;    // displayet kan vise op til 9t 59m

    bool modeChanged = countUp || stopwatchMode;
    countUp = false;
    stopwatchMode = false;
    endAtActive = true;
    endAtDeadlineMs = now + delta * 1000UL;
    endAtTotalSecs = (long)delta;
    remainingTimeSigned = (long)delta;
    timerDone = false;
    isUnderrunBlinking = false;
    displayNeedsForceUpdate = true;
    if (modeChanged) markSettingsChanged(); else configDirty = true;
    return true;
  }

  if (action == "startat") {
    if (value == "off") {
      if (startAtActive) { startAtActive = false; configDirty = true; }
      return true;
    }
    if (!clockSet) return false;
    int h, m, s;
    if (!parseHms(value, h, m, s)) return false;

    uint32_t now = millis();
    uint32_t target = (uint32_t)h * 3600UL + (uint32_t)m * 60UL + (uint32_t)s;
    uint32_t delta = (target + 86400UL - clockSecsOfDay(now)) % 86400UL;   // næste forekomst
    if (delta < 1 || delta > 35999UL) return false;

    startAtActive = true;
    startAtDeadlineMs = now + delta * 1000UL;
    if (endAtActive) {                                  // samlet tid = slut minus start
      int32_t slotMs = (int32_t)(endAtDeadlineMs - startAtDeadlineMs);
      if (slotMs > 0) endAtTotalSecs = slotMs / 1000;
    }
    configDirty = true;
    return true;
  }

  if (action == "duration") {
    if (timerRunning) return false;               // ændres ikke midt i et sæt
    char* end = nullptr;
    long v = strtol(value.c_str(), &end, 10);
    if (end == value.c_str() || v < 1 || v > 35999) return false;
    countdownTime = v;
    resetValues();
    displayNeedsForceUpdate = true;
    markSettingsChanged();
    return true;
  }
  if (action == "mode") {
    if (timerRunning) return false;
    if (value == "stopwatch") { countUp = true;  stopwatchMode = true; }
    else if (value == "up" || value == "countup") { countUp = true;  stopwatchMode = false; }
    else if (value == "down" || value == "countdown") { countUp = false; stopwatchMode = false; }
    else return false;
    resetValues();
    displayNeedsForceUpdate = true;
    markSettingsChanged();
    return true;
  }
  if (action == "warning")     { warningTime = constrain(value.toInt(), 0, 60); markSettingsChanged(); return true; }
  if (action == "underrun")    { underRun = parseBool(value); markSettingsChanged(); return true; }
  if (action == "maxunderrun") { maxUnderRunMinutes = constrain(value.toInt(), 0, 60); markSettingsChanged(); return true; }

  if (action == "brightness1") {   // trin 0-7
    brightness1 = constrain(value.toInt(), 0, 7);
    applyDisplayBrightness();
    markSettingsChanged();
    return true;
  }
  if (action == "brightness2") {
    brightness2 = constrain(value.toInt(), 0, 7);
    applyDisplayBrightness();
    markSettingsChanged();
    return true;
  }
  if (action == "ledbrightness") {
    ledBrightness = constrain(value.toInt(), 0, 100);
    applyLedBrightness();
    markSettingsChanged();
    return true;
  }
  if (action == "ledesc")      { ledEscalation = parseBool(value); markSettingsChanged(); return true; }
  if (action == "standbyanim") { standbyAnim = parseBool(value); applyDisplayBrightness(); markSettingsChanged(); return true; }
  if (action == "clockalways") { clockAlwaysOn = parseBool(value); displayNeedsForceUpdate = true; markSettingsChanged(); return true; }
  if (action == "flip")        { displayFlipped = parseBool(value); displayNeedsForceUpdate = true; markSettingsChanged(); return true; }
  if (action == "swapdisplays") {
    swapDisplays = parseBool(value);
    applyDisplayBrightness();
    identifyActive = true;                         // vis "1" og "2" i 1,5 sek. uden at blokere
    identifyUntilMs = millis() + 1500;
    markSettingsChanged();
    return true;
  }
  if (action == "screensaver") {
    screensaverEnabled = parseBool(value);
    if (!screensaverEnabled && screensaverActive) { screensaverActive = false; displayNeedsForceUpdate = true; }
    markSettingsChanged();
    return true;
  }
  if (action == "screensavermin") {
    screenSaverMinutes = constrain(value.toInt(), 1, 60);
    markSettingsChanged();
    return true;
  }
  return false;
}

// ============================================================
//  BLE: callbacks (må kun sætte flag / lægge i kø)
// ============================================================
class TimerBleServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) override { bleClientConnected = true; }
  void onDisconnect(BLEServer* pServer) override {
    bleClientConnected = false;
    disconnectedAtMs = millis();
    needRestartAdvertising = true;   // genstartes i loop()
  }
};

class TimerBleCommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* characteristic) override {
    auto raw = characteristic->getValue();     // std::string (core 2.x) eller String (core 3.x)
    size_t len = raw.length();
    if (len == 0 || cmdQueue == nullptr) return;
    BleCmd cmd;
    if (len >= sizeof(cmd.text)) len = sizeof(cmd.text) - 1;
    memcpy(cmd.text, raw.c_str(), len);
    cmd.text[len] = 0;
    cmdReceived++;
    if (xQueueSend(cmdQueue, &cmd, 0) != pdTRUE) cmdDropped++;
  }
};

void initBle() {
  BLEDevice::init("Rage Against The Time");
  BLEDevice::setMTU(185);            // uden dette bliver notifications på 20 bytes

  bleServer = BLEDevice::createServer();
  bleServer->setCallbacks(new TimerBleServerCallbacks());
  BLEService* service = bleServer->createService(BLEUUID(SERVICE_UUID), 30);   // plads til alle characteristics

  BLECharacteristic* cmdChar = service->createCharacteristic(
    CMD_UUID, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  cmdChar->setCallbacks(new TimerBleCommandCallbacks());

  bleStatusCharacteristic = service->createCharacteristic(
    STATUS_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  bleStatusCharacteristic->addDescriptor(new BLE2902());

  bleConfigCharacteristic = service->createCharacteristic(
    CONFIG_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  bleConfigCharacteristic->addDescriptor(new BLE2902());

  BLECharacteristic* otaDataChar = service->createCharacteristic(
    OTA_DATA_UUID, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  otaDataChar->setCallbacks(new OtaDataCallbacks());

  bleOtaStatus = service->createCharacteristic(
    OTA_STATUS_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  bleOtaStatus->addDescriptor(new BLE2902());
  bleOtaStatus->setCallbacks(new OtaStatusCallbacks());
  {
    char info[96];
    snprintf(info, sizeof(info), "{\"fw\":\"%s\",\"ota\":1,\"max\":0,\"up\":0}", FW_VERSION);
    bleOtaStatus->setValue((uint8_t*)info, strlen(info));
  }

  BLECharacteristic* diagChar = service->createCharacteristic(DIAG_UUID, BLECharacteristic::PROPERTY_READ);
  diagChar->setCallbacks(new DiagCallbacks());
  diagChar->setValue((uint8_t*)"{}", 2);
  BLECharacteristic* infoChar = service->createCharacteristic(INFO_UUID, BLECharacteristic::PROPERTY_READ);
  infoChar->setCallbacks(new InfoCallbacks());
  infoChar->setValue((uint8_t*)"{}", 2);

  char buf[192];
  snprintf(buf, sizeof(buf), "{\"r\":0,\"t\":%ld,\"d\":0}", remainingTimeSigned);
  bleStatusCharacteristic->setValue((uint8_t*)buf, strlen(buf));
  buildConfig(buf, sizeof(buf));
  bleConfigCharacteristic->setValue((uint8_t*)buf, strlen(buf));

  service->start();
  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(service->getUUID());
  advertising->setScanResponse(true);
  BLEDevice::startAdvertising();
}

// ============================================================
//  setup / loop
// ============================================================
void setup() {
  Serial.begin(115200);
  loadPrefs();
  checkVersionSplash();
  pinMode(FOOTSWITCH_PIN, INPUT_PULLUP);

#if HAS_STATUS_LED
  statusLed.begin();
  statusLedInitialized = true;
  applyLedBrightness();
  statusLed.clear();
  statusLed.show();
#endif

  applyDisplayBrightness();
  lastInteractionTime = millis();

  cmdQueue = xQueueCreate(8, sizeof(BleCmd));
  otaQueue = xQueueCreate(64, sizeof(OtaChunk));   // ca. 12 KB, større end app'ens 8 KB vindue

  refreshAllDisplays();
  updateStatusLed();
  diagUpdate();
  initBle();
}

void handleFootswitch(uint32_t now) {
  bool reading = digitalRead(FOOTSWITCH_PIN);
  if (reading != footswitchLastReading) {
    footswitchLastDebounceTime = now;
    footswitchLastReading = reading;
  }
  if ((now - footswitchLastDebounceTime) > FOOTSWITCH_DEBOUNCE_MS) {
    if (reading != footswitchStableState) {
      footswitchStableState = reading;
      if (footswitchStableState == HIGH) {          // handling ved slip
        if (footswitchClickCount == 0) {
          footswitchClickCount = 1;
          footswitchFirstClickTime = now;
        } else if (footswitchClickCount == 1 && (now - footswitchFirstClickTime <= DOUBLE_CLICK_WINDOW_MS)) {
          resetTimerControl();
          footswitchClickCount = 0;
        }
      }
    }
    if (footswitchClickCount > 0 && (now - footswitchFirstClickTime > DOUBLE_CLICK_WINDOW_MS)) {
      if (footswitchClickCount == 1 && footswitchStableState == HIGH) toggleTimerControl();
      footswitchClickCount = 0;
    }
  }
}

void loop() {
  uint32_t now = millis();

  // 1. Kommandoer fra BLE
  BleCmd cmd;
  while (xQueueReceive(cmdQueue, &cmd, 0) == pdTRUE) {
    if (!handleBleCommand(String(cmd.text))) cmdRejected++;
  }
  now = millis();   // kommandoer kan blokere i mange sekunder (OTA-klargøring), så tiden opdateres

  // 2. Genstart advertising efter disconnect
  if (needRestartAdvertising && (now - disconnectedAtMs) >= 300) {
    needRestartAdvertising = false;
    BLEDevice::startAdvertising();
  }

  // 3. Ur
  if (clockSet) {
    uint32_t total = clockSecsOfDay(now);
    clockHours = total / 3600UL;
    clockMinutes = (total / 60UL) % 60UL;
    clockSeconds = total % 60UL;
  }

  // 4. Blink
  if (now - lastBlink >= 250) {
    lastBlink = now;
    blinkState = !blinkState;
  }

  // 4b. Automatisk start
  if (startAtActive && (int32_t)(now - startAtDeadlineMs) >= 0) {
    startAtActive = false;
    configDirty = true;
    if (!timerRunning) startTimerControl();
  }

  // 5. Timer: normal tick, eller deadline-baseret ved slut-klokkeslot
  if (endAtActive) {
    if (!timerDone) updateEndAt(now);
  } else {
    while (timerRunning && (uint32_t)(now - lastUpdate) >= 1000) {   // indhenter forsinkede sekunder
      lastUpdate += 1000;
      tickTimer();
    }
  }

  // Når timeren stopper af sig selv, skal skærmen ikke gå i screensaver med det samme
  static bool wasRunning = false;
  if (wasRunning && !timerRunning) lastInteractionTime = now;
  wasRunning = timerRunning;

  // Tidspunkt for DONE (bruges af LED'en)
  static bool prevDone = false;
  if (timerDone && !prevDone) doneSinceMs = now;
  prevDone = timerDone;

  // 6. Screensaver
  if (screensaverEnabled && !screensaverActive && !timerRunning && !startAtActive && !endAtActive && !otaActive) {
    if (now - lastInteractionTime >= (uint32_t)screenSaverMinutes * 60000UL) {
      screensaverActive = true;
      displayNeedsForceUpdate = true;
    }
  }

  // 6b. Standby starter/slutter: skift til dæmpet/normal lysstyrke
  static bool prevStandby = false;
  if (screensaverActive != prevStandby) {
    prevStandby = screensaverActive;
    applyDisplayBrightness();
  }

  // 7. Identify-visning ved skift af displays
  if (identifyActive && (int32_t)(now - identifyUntilMs) >= 0) {
    identifyActive = false;
    displayNeedsForceUpdate = true;
  }

  // 7b. OTA: skriv modtagne pakker, genstart efter succes, og bekræft ny firmware efter 10 sek.
  otaProcess(now);
  if (otaRebootAt && (int32_t)(now - otaRebootAt) >= 0) ESP.restart();
  static bool fwValidated = false;
  if (!fwValidated && now > 10000UL) {
    fwValidated = true;
#ifdef CONFIG_APP_ROLLBACK_ENABLE
    esp_ota_mark_app_valid_cancel_rollback();
#endif
  }

  // 7c. Diagnostik: opdater temperatur og heap hvert sekund (læses af BLE-callbacken)
  if (now - diagLastMs >= 1000UL) {
    diagLastMs = now;
    diagUpdate();
  }

  // 7d. Versionsvisningen slutter af sig selv (eller når timeren startes)
  if (versionSplashActive && ((now - versionSplashStartMs) >= versionSplashDurationMs() || timerRunning)) {
    versionSplashActive = false;
    displayNeedsForceUpdate = true;
  }

  // 8. Output
  refreshAllDisplays();
  updateStatusLed();
  if (!otaActive) handleFootswitch(now);

  // 9. BLE + gem indstillinger (2 sek. efter sidste ændring)
  updateBleStatus();
  updateBleConfig();
  if (prefsDirty && (now - prefsDirtyAt) >= 2000) {
    savePrefs();
    prefsDirty = false;
  }

  delay(otaActive ? 1 : 5);
}
