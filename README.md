# cc-flatten

Programy dla CC: Tweaked (Minecraft) do wyrównywania terenu żółwiem, sterowane zdalnie z pocket computera.

| Plik | Gdzie | Opis |
|---|---|---|
| `flatten.lua` | żółw (zapisz jako `flatten`) | wyrównuje obszar: ścina wzniesienia, zasypuje dziury |
| `listener.lua` | żółw (zapisz jako `startup`) | czeka na polecenia z pilota przez rednet |
| `remote.lua` | pocket computer (zapisz jako `remote`) | pilot: wybór ID żółwia, wymiary, start zdalny |

## Wymagania

- Mining turtle z wireless/ender modemem
- Pocket computer z wireless/ender modemem
- Węgiel oraz trochę ziemi/cobble w ekwipunku żółwia

## Użycie

Ręcznie na żółwiu:

```
flatten <dlugosc> <szerokosc> [maxWGore=32] [maxWDol=8] [-c]
```

- bez `-c`: żółw stoi w lewym-tylnym rogu, obszar idzie do przodu i w prawo
- z `-c`: żółw stoi na środku obszaru

Zdalnie: na pocket computerze uruchom `remote`, podaj ID żółwia i wymiary.

Żółw stoi **na docelowym poziomie** — blok pod nim to przyszła powierzchnia.
