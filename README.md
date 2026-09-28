# cc-flatten

Programy dla CC: Tweaked (Minecraft): żółwie do wyrównywania terenu i stawiania pochodni oraz SCADA do monitorowania zakładu (Create, prąd FE, płyny, magazyn, pociągi) z alarmami.

| Plik | Gdzie | Opis |
|---|---|---|
| `flatten.lua` | żółw (`flatten`) | wyrównuje obszar: ścina wzniesienia, zasypuje dziury |
| `torches.lua` | żółw (`torches`) | stawia pochodnie w siatce, także w górach |
| `listener.lua` | żółw (`startup`) | odbiera polecenia z pilota/SCADA przez rednet |
| `remote.lua` | pocket (`remote`) | pilot: ID żółwia, program, wymiary, start |
| `pscada.lua` | pocket (`pscada`) | mini SCADA: żółwie, grupy zakładu, alarmy |
| `scada.lua` | komputer + advanced monitor (`scada`) | panel: alarmy, żółwie, zakład w grupach |
| `sensor.lua` | komputer przy maszynach (`sensor`) | czujnik: sam wykrywa i wysyła dane do SCADA |
| `lavasensor.lua`, `energysensor.lua` | – | stare nazwy, aliasy do `sensor` |
| `autostart.lua` | komputer (`autostart`) | autostart programów z auto-restartem |
| `mkdisk.lua` | komputer ze stacją dysków (`mkdisk`) | nagrywa dyskietkę instalacyjną |
| `diskstation.lua` | komputer ze stacją dysków (`diskstation`) | automatyczna stacja nagrywania dyskietek (nie trafia na dyskietki) |
| `installer.lua` | dyskietka (`startup.lua`) | instalator offline dla żółwi i komputerów |
| `update.lua` | wszędzie (`update`) | pobiera najnowsze wersje odpowiednich plików |

## Instalacja

Przez internet, na dowolnym urządzeniu:

```
wget https://raw.githubusercontent.com/dawidzgoda/cc-flatten/main/update.lua update
update
```

`update` sam rozpozna urządzenie (żółw / pocket / komputer) i pobierze właściwe programy. Potem na komputerze ustaw autostart:

```
scada install        # komputer z monitorem
sensor install       # komputer z czujnikiem
reboot
```

Bez internetu: dyskietka instalacyjna (niżej).

## Żółwie

```
flatten <dlugosc> <szerokosc> [maxWGore=32] [maxWDol=8] [-c]
torches <dlugosc> <szerokosc> [odstep=5] [-c]
```

- bez `-c`: żółw stoi w lewym-tylnym rogu, obszar idzie do przodu i w prawo; z `-c`: na środku,
- `flatten`: żółw stoi **na docelowym poziomie** (blok pod nim = przyszła powierzchnia),
- `torches`: leci nad terenem (przed zboczem się wznosi, nie kopie), w miejscu pochodni opada do gruntu; pomija wodę/lawę, pnie drzew i przepaści.

Zdalnie: `remote` na pockecie albo zakładka **ZOLWIE** na SCADA.

## Czujnik (`sensor`)

Jeden komputer z czujnikiem = jedna **grupa** na SCADA. Nazwa grupy to etykieta komputera (`label set Kopalnia`). Czujnik sam wykrywa podłączone urządzenia (obok komputera albo przez wired modem + kabel):

| Sekcja | Urządzenia | Dane |
|---|---|---|
| PRAD | magazyny FE (Powah, Thermal, ...) | energia, pojemność, bilans FE/t |
| KINETYKA | Create Stressometer, Speedometer | obciążenie SU, RPM |
| PLYNY | Create Fluid Tank i inne zbiorniki | wszystkie płyny (lawa, woda, ...) |
| MAGAZYN | skrzynie, Create Item Vault, Stock Ticker | ilości przedmiotów |
| POCIAGI | Create Train Station, Train Signal | pociąg na stacji, stan sygnału |

`sensor test` wypisuje, co czujnik widzi (diagnostyka).

## SCADA

Zakładki na monitorze (dotyk):

- **ALM** — alarmy, dziennik zdarzeń, przycisk **UPDATE**,
- **ZOLWIE** — stan żółwi; dotknij żółwia → program i parametry → START,
- **ZAKLAD** — karty grup (status, prąd, SU, płyny...). Dotknij grupy → szczegóły w sekcjach. Dotknij pozycji → **wykres** (10 min albo 2 h) i próg alarmu tej pozycji.

Wszystko zapisuje się na dysku komputera SCADA i przetrwa restart oraz UPDATE: progi alarmów i temat ntfy (`settings`), historia wykresów 10 min i 2 h (`scada_hist`, co minutę), alarmy z potwierdzeniami, dziennik zdarzeń i parametry startu żółwi (`scada_state`, co 30 s i po każdym dotknięciu). Przez pierwsze 20 s po starcie SCADA czeka na dane i nie przelicza alarmów.

`scada demo` pokazuje przykładowe dane bez żółwi i czujników.

## Alarmy

| Alarm | Poziom | Próg (domyślnie) |
|---|---|---|
| mało prądu w grupie | ALARM | < 20% |
| przeciążenie sieci Create (SU > pojemność) | ALARM | zawsze |
| wysokie obciążenie SU | uwaga | ≥ 90% |
| mało płynu (np. lawy) | ALARM | ustawiasz dotykiem (domyślnie wył.) |
| mało przedmiotu w magazynie | uwaga | ustawiasz dotykiem (domyślnie wył.) |
| za niskie RPM | uwaga | ustawiasz dotykiem (domyślnie wył.) |
| żółw czeka: brak paliwa / bloków / pochodni | ALARM | – |
| żółw przerwał pracę (błąd) | ALARM (do potwierdzenia) | – |
| żółw lub czujnik offline, mało paliwa | uwaga | – |

- **Pocket** (`pscada`, klawisz 3): te same alarmy, potwierdzanie zdalne.
- **Syrena**: speaker podłączony do komputera SCADA gra, dopóki alarm krytyczny nie zostanie potwierdzony.
- **Prawdziwy telefon** (opcjonalnie): aplikacja **ntfy**, zasubskrybuj swój tajny temat i na komputerze SCADA wpisz `set scada.ntfy <temat>`.

## Autostart i aktualizacja

`autostart list` pokazuje, co startuje; `autostart add|remove <program>` (scada, sensor, diskstation). Kilka programów może działać razem na jednym komputerze; program, który się wywali, uruchamia się ponownie po 5 s.

**Przycisk UPDATE** (zakładka ALM, dotknąć dwa razy) aktualizuje zdalnie wszystkie żółwie i czujniki, a potem samą SCADA z restartem. Pracujące żółwie są pomijane. Pockety aktualizujesz ręcznie (`update`).

## Dyskietka instalacyjna

1. **Nagranie**: komputer z internetem + stacja dysków + dyskietka → `mkdisk`.
   Albo **stacja dyskietek**: `diskstation install` + `reboot` — potem każda włożona pusta dyskietka (albo stary instalator) jest sama nagrywana najnowszą wersją i wysuwana. Inne dyskietki są pomijane.
2. **Instalacja**: stacja z dyskietką obok żółwia/komputera + restart (Ctrl+R). Instalator:
   - **żółw**: kopiuje programy, pyta o nazwę,
   - **komputer**: rola (1 SCADA, 2 czujnik, 3 SCADA + czujnik), nazwa, autostart.
3. Na koniec wysuwa dyskietkę i restartuje urządzenie.

Jeśli urządzenie ma już oprogramowanie, instalator czeka 10 s na Enter (ponowna instalacja), a potem uruchamia normalny start. Stacja dyskietek (`diskstation`, `mkdisk`) nie jest instalowana z dyskietki.
