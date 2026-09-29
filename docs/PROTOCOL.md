# Bluetooth-protokol (v2.3)

Pedalen er en BLE-peripheral med navnet `Rage Against The Time` (firmware før 2.5.0: `ESP32 Pedal Timer`). Appen finder den via service-UUID'en.

Service: `6f8d0100-2b44-4c1c-a7f9-7d9d2f734301`

| Characteristic | UUID (…-2b44-4c1c-a7f9-7d9d2f734301) | Egenskaber | Indhold |
|---|---|---|---|
| COMMAND | `6f8d0101` | write | tekstkommandoer `handling:værdi` |
| STATUS | `6f8d0102` | read, notify | hurtig status (JSON) |
| CONFIG | `6f8d0103` | read, notify | indstillinger (JSON) |
| OTA_DATA | `6f8d0104` | write, write without response | rå firmware-bytes |
| OTA_STATUS | `6f8d0105` | read, notify | version, fremdrift, fejl (JSON) |

MTU sættes til 185 (payload 182 bytes).

## STATUS

```json
{"r":1,"t":1234,"d":0}
```

| Felt | Betydning |
|---|---|
| `r` | 1 = timeren kører |
| `t` | resterende sekunder (negativ ved under-run). Ved optælling/stopur: forløbne sekunder |
| `d` | 1 = færdig |

## CONFIG

Nøgler: `mode` (countdown/countup/stopwatch), `dur` (effektiv varighed i sek.), `b1`/`b2` (lysstyrke 0–7 for ur/timer),
`led` (0–100), `warn` (min), `ur` (under-run), `mur` (max under-run i min), `flip`, `clk` (ur altid tændt), `swap`,
`scr`/`scrm` (pauseskærm), `ts` (uret er sat), `ea` (slut-klokkeslot aktivt), `esc` (LED-farveskift), `sa` (automatisk start venter).

## COMMAND

| Kommando | Værdi |
|---|---|
| `start`, `stop`, `reset`, `toggle` | – |
| `time` | `HH:MM:SS` (sætter pedalens ur) |
| `endat` | `HH:MM[:SS]` eller `off` (nedtælling til klokkeslæt, højst 9t 59m frem) |
| `startat` | `HH:MM[:SS]` eller `off` (start automatisk; sendes efter `endat`) |
| `duration` | sekunder, 1–35999 (kun når timeren står stille) |
| `mode` | `countdown`, `countup`, `stopwatch` (kun når timeren står stille) |
| `warning` | minutter, 0–60 |
| `underrun` | `on`/`off` |
| `maxunderrun` | minutter, 0–60 |
| `brightness1`, `brightness2` | 0–7 |
| `ledbrightness` | 0–100 |
| `ledesc` | `on`/`off` |
| `clockalways`, `flip`, `swapdisplays`, `screensaver` | `on`/`off` |
| `screensavermin` | 1–60 |
| `ota` | `begin:<bytes>`, `end`, `abort` |

Kommandoer lægges i en kø på pedalen (8 pladser) og udføres i hovedløkken. Send dem med lidt luft imellem (ca. 80 ms).

## OTA (firmwareopdatering)

```
App    → COMMAND     ota:begin:<bytes>
Pedal  → OTA_STATUS  {"s":"ready"}                    (efter at flash er slettet, op til ~15 sek.)
App    → OTA_DATA    firmware-bytes, pakker på højst 182 bytes, write without response, højst 8 KB i luften
Pedal  → OTA_STATUS  {"s":"p","o":<bytes skrevet>}    hver 2 KB, og som heartbeat hvert 500 ms
App    → COMMAND     ota:end                          når alle bytes er kvitteret
Pedal  → OTA_STATUS  {"s":"done"}                     genstarter derefter
```

Læsning af OTA_STATUS i hvile: `{"fw":"2.5.0","ota":1,"max":1310720,"up":12}` (version, OTA-plads til rådighed, størrelse på OTA-partitionen, oppetid i sek.).

Fejl: `{"s":"err","m":"<kode>"}` med koderne `running`, `nopart`, `size`, `begin`, `magic`, `write`, `end`, `overflow`, `timeout`, `disconnect`, `busy`, `state`.
Afbrydes forbindelsen under overførslen, forbliver den gamle firmware aktiv.

Filen skal være app-imaget (`*.ino.bin`). Første pakke skal starte med byten `0xE9`, og app-descriptorens magic (`32 54 CD AB`) skal ligge på byte 32.
