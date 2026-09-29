# Rage Against The Time

*Kortnavn: **RATT** (bruges under ikonet på hjemmeskærmen).*

Gig-timer til pedalboardet. En fodpedal med to 7-segment-displays og en statuslampe, styret fra en iPhone-app over Bluetooth LE.

Bandet kan holde øje med, hvor lang tid sættet har tilbage, uden at røre telefonen.

## Funktioner

- **Tre tilstande:** nedtælling, optælling og stopur
- **Fodpedal:** ét tryk starter/pauser, to hurtige tryk nulstiller
- **Slut-klokkeslot:** tæl ned til et klokkeslæt, så et sent start automatisk giver kortere tid
- **Automatisk start** ved et fastsat klokkeslæt (kører på pedalen, også med låst telefon)
- **Gig-profiler:** gem indstillinger pr. spillested og skift med ét tryk
- **LED-farveskift:** grøn → gul → orange → rød blink jo tættere på slut
- **Advarsel og under-run** (fortsæt over tid, med maksgrænse)
- **Live Activity** på låseskærm og i Dynamic Island, plus lokale notifikationer
- **Trådløs firmwareopdatering** (OTA) fra appen

## Opbygning

```
.
├── *.xcodeproj                    Xcode-projektet (iOS-app + widget)
├── <app-mappen>/                  app-koden (SwiftUI, CoreBluetooth)
├── <widget-mappen>/               Live Activity (widget-extension)
├── firmware/RageAgainstTheTime/   ESP32-C3 firmware (Arduino)
└── docs/PROTOCOL.md               Bluetooth-protokollen mellem app og pedal
```

## Hardware

| Del | Forbindelse (ESP32-C3) |
|---|---|
| 2 × TM1637 4-cifret display | CLK = GPIO 4, DIO1 = GPIO 5, DIO2 = GPIO 6 |
| Fodkontakt (normalt åben, mod GND) | GPIO 10 (INPUT_PULLUP) |
| Status-LED (WS2812) | GPIO 7 |

Pins kan ændres øverst i `RageAgainstTheTime.ino`.

## Byg firmwaren

1. Installér ESP32-boardpakken og bibliotekerne `TM1637Display` og `Adafruit NeoPixel` i Arduino IDE.
2. Vælg dit ESP32-C3-board og **Tools → Partition Scheme → "Default 4MB with spiffs"** (skal have OTA, to app-pladser).
3. Upload via USB første gang. Herefter kan pedalen opdateres trådløst.

### Trådløs opdatering

1. Hæv `FW_VERSION` i sketchen.
2. **Sketch → Export Compiled Binary**, og brug filen der ender på `.ino.bin` (ikke `_flashed`, `merged`, `bootloader` eller `partitions`).
3. Send filen til iPhonen, og vælg den i appen under **Indstillinger → Firmware**.

## Byg appen

1. Åbn Xcode-projektet (`.xcodeproj`) i Xcode 16 eller nyere.
2. Sæt dit eget Team og bundle identifier under *Signing & Capabilities* (for både app og widget).
3. Kør på en rigtig iPhone (Bluetooth virker ikke i simulatoren). Kræver iOS 17.

## Status

Under udvikling. Fejl og forslag er velkomne som issues.

## Licens

Endnu ikke valgt. Uden en licens har andre ikke ret til at bruge, kopiere eller ændre koden.
