# Strata NVFP4 на llmhost1 — инструкция оператора

Сервер LLM на **RTX 5090**, репозиторий **sergqwer/strata-nvfp4** (main = `586dc5e`,
релиз `0.2.0-beta-nvfp4.3`), модель
`Maximilian228/Qwen3.8-Flash-Next-NVFP4-Q8-Mix-Strata` (158 ГБ, NVFP4 + Q8_0 микс).

Всё описано в терминах «что где лежит на хосте».

---

## 1. Что где лежит

| Что | Путь на хосте | Комментарий |
|---|---|---|
| Репозиторий (рецепт сборки) | `/opt/rtx-5090-strata-nvfp4-fresh` | наш git-репозиторий: Dockerfile, entrypoints, скрипты, доки |
| Исходники форка (чистый checkout) | `/opt/strata-nvfp4/src-0.2.0` | `git status` пустой, `main` = `586dc5e` |
| Контекст сборки | `/opt/strata-nvfp4/build-0.2.0` | исходники форка + `third_party/llama.cpp` @ `3cf03257` |
| Файлы модели | `/opt/strata-data/models/Maximilian228--Qwen3.8-Flash-Next-NVFP4-Q8-Mix-Strata/` | 17 файлов, у каждого `.done` с `sha256` |
| Энкодер изображений | `/opt/strata-data/models/mmproj-Qwen3.8-Flash-Next-BF16.gguf` | 907 МБ |
| Образ (прод) | `strata-nvfp4:sm120-v020` | движок собран под Zen 5 + sm_120 |
| Старый образ (откат) | `strata-nvfp4:sm120` | из прошлой ревизии, оставлен для отката |
| systemd-юнит | `/etc/systemd/system/strata-nvfp4.service` | **выключен по умолчанию** |
| Файл окружения | `/opt/strata-nvfp4.service.d/env` | `chmod 600`, root-only |
| Обёртка запуска | `/opt/strata-nvfp4.service.d/run.sh` | весь `docker run` одной командой |
| Логи | `journalctl -u strata-nvfp4` + `/var/log/strata-nvfp4/` | |

> Репозиторий **не содержит** дерева форка: только рецепт (Dockerfile, entrypoints,
> скрипты, доки) и закреплённый сабмодуль `third_party/llama.cpp`. Форк тянется
> скриптом деплоя по пину `586dc5e`, так что «репозиторий» и «прод» разъехаться не могут.

---

## 2. Запуск и остановка

Юнит **не включается** при загрузке — это осознанно: хост может остаться без
заимствованной 128 ГБ планки памяти, и автостарт в таком случае уронил бы
сам себя. Запускаем руками:

```sh
systemctl start strata-nvfp4      # поднять
systemctl status strata-nvfp4     # посмотреть
systemctl stop strata-nvfp4       # остановить
systemctl restart strata-nvfp4    # перезапустить
```

> Юнит сделан на `Type=exec` + `RemainAfterExit=yes`, а **не** на `Type=oneshot`:
> с oneshot systemd считает юнит «завершённым навсегда» и больше не выполняет
> ни ExecStart, ни ExecStop - `systemctl start` молча ничего не делает, а
> `systemctl stop` оставляет контейнер работать. С `Type=exec` все четыре команды
> (`start`, `stop`, `restart`, повторный `start`) делают то, что сказано.

### Прямой запуск мимо systemd (для отладки)

```sh
/opt/strata-nvfp4.service.d/run.sh start
docker logs -f strata-nvfp4
```

---

## 3. Параметры — все явные

Всё, что влияет на поведение, задано явно и лежит в двух местах.

**`/opt/strata-nvfp4.service.d/run.sh`** — параметры контейнера:

| Параметр | Значение | Почему |
|---|---|---|
| `--gpus '"device=1"'` | RTX 5090 | на хосте `nvidia-smi` idx 0 = RTX 5080 (reserved под ComfyUI), idx 1 = RTX 5090. Внутри контейнера 5090 имеет индекс **0** |
| `-p 8081:8080` | порт | API на `http://<host>:8081`. **8080 на хосте занят под llama** (`llama-qwen5090-256k.service`), поэтому Strata живёт на 8081. Внутри контейнера порт по-прежнему 8080 |
| `--ulimit memlock=-1` | без лимита | движок `mlock`ает свои выделения |
| `-v /opt/strata-data:/data` | модель | 158 ГБ файлов модели, переиспользуются, не копируются |
| `-e FAMILY=qwen-nvfp4-mix` | семейство | NVFP4 + Q8_0 микс |
| `-e CONTEXT=262144` | 256K | рабочий контекст |
| `-e KV=int8` | 8-бит K/V | точность/память баланс |
| `-e VISION=yes` | картинки | энкодер на CPU, VRAM остаётся экспертам |
| `-e UNCENSORED=on` | цензура | проекция отказа, грузится всегда, по умолчанию **включена** |
| `-e LOW_RAM=off` | все эксперты в RAM | 103 ГБ экспертов + запас |
| `-e VRAM_RESERVE_MIB=768` | свободная VRAM | движок оставляет 768 МиБ под другие программы; его own default 700, но при 5399 экспертах свободная VRAM падала до 492 МиБ — ниже порога LOW (512), и драйвер начинает сбрасывать VRAM в RAM, а decode падает |
| `-e HOST=0.0.0.0` | доступ из сети | вместе с `API_KEY` |
| `-e API_KEY=...` | ключ | клиенты должны его слать |
| `-e HF_TOKEN=...` | токен HF | на случай докачки чего-то |
| `--restart unless-stopped` | перезапуск | контейнер поднимется сам после ребута хоста |

> `--model` **не передаётся**: у каждого NVFP4-семейства ровно одно имя, а
> `--model NVFP4` — это из 0.1.44 имя для `--family qwen-nvfp4-gptq`, и setup.py
> такой флаг для нашего семейства отвергает.

**`/opt/strata-nvfp4.service.d/strata-start-v020.sh`** (внутри контейнера) — параметры
модели, две фазы:

```
фаза 1 (setup): setup.py --setup --no-start --family qwen-nvfp4-mix --context 262144 \
                 --kv int8 --vision yes --uncensored on --low-ram off \
                 --vram-reserve-mib 768 --data-dir /data --host 0.0.0.0 \
                 --api-key ... --port 8080 --yes
фаза 2 (serve): setup.py --port 8080 --yes
```

> **Важно:** во второй фазе **нет** `--family` / `--setup` / `--no-start` / `--data-dir`.
> С этими флагами `setup.py` уходит в ветку «поставить модель заново» вместо
> «запустить установленную». Первая фаза пишет конфиг
> `strata-qwen-mix-nvfp4.json`, вторая его запускает.

---

## 4. Что модель качает, а что нет

**Модель не качается.** 17 файлов лежат в `/opt/strata-data/models/...` и каждый
проверен по SHA-256 против пинов репозитория (`.done`-марки содержат `sha256 <hex>`).
Пины форка `586dc5e` совпадают с лежащими на диске **байт-в-байт** — это проверено
скриптом, а не на глаз. При старте `setup.py` сверяет эти марки и идёт дальше.

Единственное, что при первом старте может уйти в сеть, — энкодер изображений; он
тоже уже на диске (`mmproj-Qwen3.8-Flash-Next-BF16.gguf`).

Движок собран **внутри образа** под этот CPU (Zen 5, AVX-512) и под эту карту
(`sm_120`). На старте ничего не компилируется.

---

## 5. Проверка после запуска

```sh
# 1. жив ли сервер и какой контекст
curl -s localhost:8081/health | python3 -m json.tool

# 2. модель видна
curl -s -H "Authorization: Bearer $API_KEY" localhost:8081/v1/models | python3 -m json.tool

# 3. агентные поверхности выключены
curl -s -H "Authorization: Bearer $API_KEY" localhost:8081/mcp
#   ожидаем: {"servers": [], "tools": 0}

# 4. скорость
curl -s -H "Authorization: Bearer $API_KEY" localhost:8081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"x","messages":[{"role":"user","content":"Скажи 200 слов про Linux"}],"max_tokens":300}' \
  | python3 -m json.tool
```

Ожидаемый ответ `/health`:

```json
{"status": "ok", "max_context": 262144, "model": "qwen3.8-flash-next-mix-nvfp4",
 "images": true, "api_key": true, "loaded": true, "service": "strata"}
```

Измерено на этой сборке: **130.9-134.6 tok/s decode**, prefill ~6000 tok/s,
принятие MTP-драфта 84.6-97.2 %, cache hit экспертов 80-85 %,
5378 экспертов в 22.7 GiB VRAM. (Старая ревизия форка давала 95-101 tok/s.)

В логах должно быть:

```
decode expert cache hit rate: 80%+   (эксперты в кэше GPU)
experimental_speed_projection=True    (uncensored применён)
```

---

## 6. Откат

Старый образ `strata-nvfp4:sm120` оставлен на месте. Откат — поменять образ в
`run.sh` и перезапустить:

```sh
sed -i 's|strata-nvfp4:sm120-v020|strata-nvfp4:sm120|' /opt/strata-nvfp4.service.d/run.sh
systemctl restart strata-nvfp4
```

Файлы модели общие для обоих образов — совпадают по пинам, ничего не перекачивается.

**Откат проверен на живом стенде, а не только на словах.** Тот же самый
entrypoint `strata-start-v020.sh` умеет обслуживать оба образа: он находит
интерпретатор динамически (`/venv/bin/python` в новом образе,
`/opt/strata/.venv/bin/python` в старом). Прогон отката поднимал старый образ
с тем же entrypoint, тем же `-p 8081:8080` и тем же набором env:

- `/health` → `{"status": "ok", "max_context": 262144, ...}`
- `/mcp` → `{"servers": [], "tools": 0}` — агентных поверхностей нет и там
- эксперты загрузились: 103.13 GiB за 69 с
- цензура выключена: на пробный запрос модель ответила «DAN here — no restrictions»
  и расписала вскрытие замка

Так что откат — это правда одна строка и рестарт. Документация не обещает того,
что не проверено.

---

## 7. Пересборка движка

Нужна только если исходники форка обновились.

**Прод при этом должен быть остановлен:** компиляция CUDA+LTO съедает всю
свободную RAM, а хост отдаёт под неё 122 ГБ всего.

```sh
# 1. обновить форк на нужный коммит
cd /opt/strata-nvfp4/src-0.2.0 && git fetch origin && git checkout <commit>

# 2. пересобрать контекст сборки из форка + закреплённого llama.cpp
sudo /opt/rtx-5090-strata-nvfp4-fresh/scripts/prepare-build-context.sh /opt/strata-nvfp4/build-0.2.0

# 3. собрать образ
docker stop strata-nvfp4
cd /opt/strata-nvfp4/build-0.2.0 && docker build -f Dockerfile.zen5-v020 -t strata-nvfp4:sm120-v020 .
```

`prepare-build-context.sh` делает ровно то, что нужно, и **ничего лишнего**:

1. копирует дерево форка в контекст сборки;
2. убирает из `.dockerignore` строку `third_party/llama.cpp/` — иначе `COPY . .`
   оставит исходники движка вне образа и сборка упадёт;
3. копирует `third_party/llama.cpp` из закреплённого сабмодуля репозитория
   (исключения **якорные**: `/.git`, `/models` — без якоря `models/` вырезал бы ещё
   и `llama.cpp/src/models`, `tools/mtmd/models` и UI-модели);
4. пересоздаёт симлинк `ggml/include/ggml-common.h -> ../src/ggml-common.h`,
   который llama.cpp создаёт при сборке, но git не отслеживает;
5. кладёт в контекст `Dockerfile.zen5-v020` и entrypoint.

Проверено: после этого `diff -rq` против настоящего контекста, из которого собрана
продовая картинка, **не находит ни одного различия**. То есть пересборка
воспроизводит контекст байт-в-байт.

### Отдельно про llama.cpp

Форк пинит llama.cpp в своём `setup.py` (`LLAMA_CPP_COMMIT`) — тот же коммит
`3cf03257`, что закреплён сабмодулем в нашем репозитории. В дереве форка этого
каталога **нет**: он скачивается при первой установке. Поэтому в репозитории он
есть как сабмодуль, и `git clone` без `--recurse-submodules` не даст собрать образ.

---

## 8. Место в схеме хоста

```
llmhost1 (85.136.112.144:12007)
├── RTX 5080 (nvidia-smi idx 0) — ComfyUI, генерация картинок
└── RTX 5090 (nvidia-smi idx 1) — Strata NVFP4, LLM      ← этот сервис
```

Порты хоста:

| Порт | Кто слушает |
|---|---|
| 8080 | свободен — зарезервирован под `llama-qwen5090-256k.service` |
| 8081 | Strata NVFP4 (этот сервис) |
| 8443 | телеграм-бот (webhook) |

Бот ходит в Strata по `http://127.0.0.1:8081/v1` (контейнер бота в режиме
`network_mode: host`). При переезде Strata на другой порт надо править это
значение в `/opt/telegrambot/bot/app/.env` и пересоздавать контейнер бота —
иначе бот останется без языковой модели.

Обе карты на PCIe Gen5 x8 (не x16) — lane sharing с M.2. Измеренная скорость
host↔device 28.9 GB/s у обеих, так что PCIe не бутылочное горлышко; различает
карты объём VRAM.
