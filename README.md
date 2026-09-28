# cc-flatten

Programy dla CC: Tweaked (Minecraft) do wyrównywania terenu i stawiania pochodni żółwiem, sterowane zdalnie z pocket computera.

| Plik | Gdzie | Opis |
|---|---|---|
| `flatten.lua` | żółw (zapisz jako `flatten`) | wyrównuje obszar: ścina wzniesienia, zasypuje dziury |
| `torches.lua` | żółw (zapisz jako `torches`) | stawia pochodnie w siatce co N kratek |
| `listener.lua` | żółw (zapisz jako `startup`) | czeka na polecenia z pilota przez rednet |
| `remote.lua` | pocket computer (zapisz jako `remote`) | pilot: wybór ID żółwia, wymiary, start zdalny |
| `scada.lua` | komputer z advanced monitorem (zapisz jako `scada`) | panel stanu żółwi + dotykowe uruchamianie programów; zakładka LAWA (zapas ze zbiorników i skrzyń, trend, wykres); `scada demo` = dane testowe |
| `lavasensor.lua` | komputer przy zbiornikach (zapisz jako `lavasensor`) | czujnik lawy: wysyła zapas bezprzewodowo do SCADA; `lavasensor install` = autostart |
| `energysensor.lua` | komputer przy magazynach FE (zapisz jako `energysensor`) | czujnik prądu (np. Powah): wysyła stan FE do SCADA; `energysensor install` = autostart |
| `pscada.lua` | pocket computer (zapisz jako `pscada`) | mini SCADA: żółwie, lawa, prąd na ekranie pocketa; `pscada demo` = dane testowe |
| `update.lua` | wszędzie (zapisz jako `update`) | pobiera najnowsze wersje odpowiednich plików |

## Instalacja

Na żółwiu i na pocket computerze wpisz:

```
wget https://raw.githubusercontent.com/dawidzgoda/cc-flatten/main/update.lua update
update
```

`update` sam rozpozna, czy działa na żółwiu (pobierze `flatten`, `torches` i `startup`), czy na pilocie (pobierze `remote`).
Na żółwiu po aktualizacji wpisz `reboot`. Później do aktualizacji wystarczy samo `update`.

## Wymagania

- Mining turtle z wireless/ender modemem
- Pocket computer z wireless/ender modemem
- Węgiel oraz trochę ziemi/cobble (flatten) lub pochodnie (torches) w ekwipunku żółwia

## Użycie

Ręcznie na żółwiu:

```
flatten <dlugosc> <szerokosc> [maxWGore=32] [maxWDol=8] [-c]
```

- bez `-c`: żółw stoi w lewym-tylnym rogu, obszar idzie do przodu i w prawo
- z `-c`: żółw stoi na środku obszaru

```
torches <dlugosc> <szerokosc> [odstep=5] [-c]
```

Żółw leci 1 blok nad ziemią i stawia pochodnie pod sobą. Najlepiej działa na terenie wyrównanym przez `flatten`.

Zdalnie: na pocket computerze uruchom `remote`, podaj ID żółwia, wybierz program i wymiary.

Żółw stoi **na docelowym poziomie** — blok pod nim to przyszła powierzchnia.

## Alarmy

SCADA sama pilnuje stanu i podnosi alarmy:

| Alarm | Poziom |
|---|---|
| mało lawy (poniżej progu z USTAW) | ALARM |
| mało prądu (poniżej 20%) | ALARM |
| żółw czeka: brak paliwa / bloków / pochodni | ALARM |
| żółw przerwał pracę (błąd) | ALARM (do potwierdzenia) |
| żółw offline, mało paliwa, czujnik offline | uwaga |

- Zakładka **ALM** na monitorze (pierwsza z lewej): lista alarmów, dotknięcie = potwierdzenie, dziennik zdarzeń.
- **Pocket** (`pscada`, klawisz 4): te same alarmy, potwierdzanie zdalne.
- **Syrena**: speaker podłączony do komputera SCADA gra, dopóki alarm krytyczny nie zostanie potwierdzony.
- **Prawdziwy telefon** (opcjonalnie): zainstaluj aplikację **ntfy**, zasubskrybuj swój tajny temat i na komputerze SCADA wpisz `set scada.ntfy <temat>`.
