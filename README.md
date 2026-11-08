# Glite-Ratio-EdgeTX

Widget Lua **GlideStat** dla EdgeTX (radia z kolorowym ekranem, projektowany pod RadioMaster
TX16S MK3 – 5" 800×480) dla szybowców z napędem.

## Funkcje

- Telemetria na żywo: wysokość, wario, RxBt, jakość łącza (RQly/RSSI), liczba satelitów
- Czas lotu: z silnikiem / bez silnika / razem
- Dystans (GPS, awaryjnie z prędkości GSpd): z silnikiem / bez silnika / razem
- Zdobyta wysokość (suma wznoszeń) z silnikiem i bez silnika (termika)
- Max wysokość i najlepsze wznoszenie podczas szybowania
- Układ pełny dla dużych stref i kompaktowy dla małych; położenie elementów skaluje się do
  rozmiaru strefy, a czcionki są dobierane automatycznie (największa, która się mieści)

## Instalacja

1. Skopiuj folder `WIDGETS/GlideStat` na kartę SD radia do `/WIDGETS/`.
2. W menu telemetrii modelu wykonaj „Wykryj czujniki”.
3. Na ekranie głównym dodaj widget **GlideStat** (najlepiej w układzie z jedną dużą strefą).
4. W opcjach widgetu ustaw **MotorSrc**.

## Opcje

| Opcja | Opis |
|---|---|
| `MotorSrc` | Źródło silnika: drążek gazu lub kanał ESC (np. CH3) |
| `MotorThr` | Próg w % (-100..100); powyżej = silnik pracuje (domyślnie -80) |
| `ResetSw` | Przełącznik kasujący statystyki |
| `Hyst` | Histereza wysokości w metrach – filtr szumu barometru (domyślnie 2) |
| `Color` | Kolor tekstu |

Reset także długim naciśnięciem ENTER w trybie pełnoekranowym.

## Jak liczone są wartości

- **Wznios w termice** – sumowane są wznoszenia ≥ `Hyst` od lokalnego minimum, tylko przy
  wyłączonym silniku. Pierwsze 3 s po wyłączeniu silnika (lot z rozpędu) są pomijane
  (`MOTOR_OFF_DELAY`).
- **Dystans** – z kolejnych pozycji GPS (min. 5 satelitów, kroki < 5 m pomijane, skoki > 300 m
  odrzucane). Bez fixu GPS – całkowanie `GSpd` (km/h).
- **Start lotu** – pierwsze włączenie silnika lub wzrost wysokości o 10 m. Czasy liczone tylko
  przy aktywnej telemetrii.

Obsługiwane nazwy czujników: `Alt`/`GAlt`, `VSpd`, `GPS`, `GSpd`, `Sats`, `RxBt`, `RQly`/`1RSS`/`RSSI`
(CRSF/ELRS, INAV, FrSky).

Stałe konfiguracyjne znajdują się na początku `main.lua`.

> Status: wersja wstępna, nietestowana na radiu – sprawdź w symulatorze EdgeTX Companion.
