# cc-flatten

Programy dla CC: Tweaked (Minecraft): żółwie do wyrównywania terenu i stawiania pochodni oraz SCADA do monitorowania zakładu (Create, prąd FE, płyny, magazyn, pociągi) z alarmami.

| Plik | Gdzie | Opis |
|---|---|---|
| `flatten.lua` | żółw (`flatten`) | wyrównuje obszar: ścina wzniesienia, zasypuje dziury |
| `torches.lua` | żółw (`torches`) | stawia pochodnie w siatce, także w górach |
| `listener.lua` | żółw (`startup`) | odbiera polecenia z pilota przez rednet |
| `remote.lua` | pocket (`remote`) | pilot: ID żółwia, program, wymiary, start |
| `pscada.lua` | pocket (`pscada`) | mini SCADA: grupy zakładu, alarmy |
| `scada.lua` + `scadalib/*.lua` | komputer + advanced monitor (`scada`) | panel zakładu z sidebarem: alarmy, przegląd, kategorie, wykresy |
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

Zdalnie: `remote` na pockecie. Żółwie są **niezależne od SCADA** — aktualizujesz je ręcznie (`update`).

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

Monitor z **sidebarem** po lewej (dotyk). Im większy monitor, tym lepiej (min. ok. 50×14 znaków; wielkość tekstu dobiera się sama, ręcznie: `set scada.scale 1`):

| Pozycja | Co pokazuje |
|---|---|
| **ALARMY** | lista alarmów (dotknij = potwierdź), dziennik zdarzeń |
| **PRZEGLAD** | prąd całego zakładu z prognozą, karty grup |
| **PRAD** | magazyny FE ze wszystkich grup: pasek, bilans FE/t, „pełne/puste za” |
| **KINETYKA** | stressometry (SU, pasek obciążenia) i speedometry ze wszystkich grup |
| **PLYNY** | płyny ze wszystkich grup; z ustawioną pojemnością: pasek i prognoza |
| **MAGAZYN** | obserwowane i najliczniejsze przedmioty w każdej grupie |
| **POCIAGI** | stacje i sygnały Create |
| TEST SYRENY / UPDATE | na dole sidebara |

Pozycja w sidebarze miga na czerwono, gdy w jej kategorii jest niepotwierdzony alarm. W kategorii: dotknij nazwy grupy → wszystkie sekcje tej grupy; dotknij pozycji → **wykres** (10 min / 2 h), próg alarmu i (dla płynów) pojemność.

Kod SCADA jest podzielony na moduły w `scadalib/`: `app` (stan, narzędzia), `config` (progi), `data` (grupy, historia), `alarms` (alarmy, syrena, ntfy), `ui` (monitor, sidebar), `sections` (kategorie), `views` (ekrany).

Zapisywane na dysku (przetrwa restart i UPDATE): progi i pojemności (`settings`), historia wykresów (`scada_hist`), alarmy i dziennik (`scada_state`). Przez pierwsze 20 s po starcie SCADA czeka na dane i nie przelicza alarmów.

`scada demo` pokazuje przykładowe dane bez czujników.

## Alarmy

| Alarm | Poziom | Próg (domyślnie) |
|---|---|---|
| mało prądu w grupie | ALARM | < 20% |
| przeciążenie sieci Create (SU > pojemność) | ALARM | zawsze |
| wysokie obciążenie SU | uwaga | ≥ 90% |
| mało płynu (np. lawy) | ALARM | ustawiasz dotykiem (domyślnie wył.) |
| mało przedmiotu w magazynie | uwaga | ustawiasz dotykiem (domyślnie wył.) |
| za niskie RPM | uwaga | ustawiasz dotykiem (domyślnie wył.) |
| czujnik offline | uwaga | – |

- **Pocket** (`pscada`, klawisz 2): te same alarmy, potwierdzanie zdalne.
- **Syrena**: speakery podłączone do komputera SCADA (może ich być kilka, przez wired modemy). Alarm krytyczny: dzwon + syrena dwutonowa co 5 s do potwierdzenia; ostrzeżenie: dwa krótkie sygnały. Przycisk TEST SYRENY na dole sidebara. Dźwięk: `set scada.siren bell|notes|horn` (horn = róg rajdu, bardzo głośny), głośność `set scada.siren_volume 3`.
- **Prawdziwy telefon** (opcjonalnie): aplikacja **ntfy**, zasubskrybuj swój tajny temat i na komputerze SCADA wpisz `set scada.ntfy <temat>`.

## Autostart i aktualizacja

`autostart list` pokazuje, co startuje; `autostart add|remove <program>` (scada, sensor, diskstation). Kilka programów może działać razem na jednym komputerze; program, który się wywali, uruchamia się ponownie po 5 s.

**Przycisk UPDATE** (na dole sidebara, dotknąć dwa razy) aktualizuje zdalnie wszystkie czujniki, a potem samą SCADA z restartem. Żółwie i pockety aktualizujesz ręcznie (`update`).

## Dyskietka instalacyjna

1. **Nagranie**: komputer z internetem + stacja dysków + dyskietka → `mkdisk`.
   Albo **stacja dyskietek**: `diskstation install` + `reboot` — potem każda włożona pusta dyskietka (albo stary instalator) jest sama nagrywana najnowszą wersją i wysuwana. Inne dyskietki są pomijane.
2. **Instalacja**: stacja z dyskietką obok żółwia/komputera + restart (Ctrl+R). Instalator:
   - **żółw**: kopiuje programy, pyta o nazwę,
   - **komputer**: rola (1 SCADA, 2 czujnik, 3 SCADA + czujnik), nazwa, autostart.
3. Na koniec wysuwa dyskietkę i restartuje urządzenie.

Jeśli urządzenie ma już oprogramowanie, instalator czeka 10 s na Enter (ponowna instalacja), a potem uruchamia normalny start. Stacja dyskietek (`diskstation`, `mkdisk`) nie jest instalowana z dyskietki.
