# cc-flatten

Programy dla CC: Tweaked (Minecraft) do wyrównywania terenu i stawiania pochodni żółwiem, sterowane zdalnie z pocket computera.

| Plik | Gdzie | Opis |
|---|---|---|
| `flatten.lua` | żółw (zapisz jako `flatten`) | wyrównuje obszar: ścina wzniesienia, zasypuje dziury |
| `torches.lua` | żółw (zapisz jako `torches`) | stawia pochodnie w siatce co N kratek |
| `listener.lua` | żółw (zapisz jako `startup`) | czeka na polecenia z pilota przez rednet |
| `remote.lua` | pocket computer (zapisz jako `remote`) | pilot: wybór ID żółwia, wymiary, start zdalny |
| `scada.lua` | komputer z advanced monitorem (zapisz jako `scada`) | panel stanu wszystkich żółwi; `scada demo` = dane testowe |
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
