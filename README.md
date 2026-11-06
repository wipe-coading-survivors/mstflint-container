# mstflint-container

Компаньон репозитория [mlxini](https://github.com/wipe-coading-survivors/mlxini):
образ `mstflint:4.37.0-1.3` — mstflint из
[upstream Mellanox](https://github.com/Mellanox/mstflint) по SHA-пину
`1b8ac4b520390563ff0822d472a54895d033d143` (merge relicense-dual2,
первый полностью dual-licensed коммит) + патч-серия 4.37.0-1.x
(`MSTFLINT_DATA_PATH`, `--mcc_read`). Тег `v4.37.0-1.3` — наш сборочный
лейбл (версия патч-серии), у апстрима его нет.

## Сборка и деплой

```sh
make image            # shallow-fetch по SHA + образ mstflint:4.37.0-1.3
                      # (grep-гейты патчей и self-report SHA внутри build)
make mstflint-deploy HOST=<ssh-alias>
                      # AppImage + manifest из образа -> /usr/local/... на HOST
```

Тег образа переопределяется через `local.mk` (см. `local.mk.example`).

## Контракт потребления (mlxini)

- Образ содержит `/opt/mft-artifacts/mstflint-<ver>-x86_64.AppImage`
  и `manifest.txt` (BIN=… на строку) — deploy раскладывает AppImage
  по `/usr/local/share/mlxini-mstflint/` и симлинки бинарей из
  манифеста в `/usr/local/bin/`.
- `mstflint --version` в образе показывает `Git SHA Hash: <пин>` —
  проверяется в build-time (grep-гейты патчей тоже).
