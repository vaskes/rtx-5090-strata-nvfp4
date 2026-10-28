# Strata NVFP4 на llmhost1 — инструкция оператора

Сервер LLM на **RTX 5090**, репозиторий **sergqwer/strata-nvfp4** (main = `586dc5e`,
релиз `0.2.0-beta-nvfp4.3`), модель
`Maximilian228/Qwen3.8-Flash-Next-NVFP4-Q8-Mix-Strata` (158 ГБ, NVFP4 + Q8_0 микс).

Всё описано в терминах «что где лежит на хосте».

---

## 1. Что где лежит

| Что | Путь на хосте | Комментарий |
|---|---|---|
| Репозиторий (клон для сборки) | `/opt/rtx-5090-strata-nvfp4-fresh` | наш git-репозиторий с Dockerfile и скриптами |
| Исходники форка (чистый checkout) | `/opt/strata-nvfp4/src-0.2.0` | `git status` пустой, ветка `main` = `586dc5e` |
| Контекст сборки | `/opt/strata-nvfp4/build-0.2.0` | исходники + `third_party/llama.cpp` @ `3cf03257` |
| Файлы модели | `/opt/strata-data/models/Maximilian228--Qwen3.8-Flash-Next-NVFP4-Q8-Mix-Strata/` | 17 файлов, у каждого `.done` с `sha256` |
| Энкодер изображений | `/opt/strata-data/models/mmproj-Qwen3.8-Flash-Next-BF16.gguf` | 907 МБ |
| Образ | `strata-nvfp4:sm120-v020` | движок собран под Zen 5 + sm_120 |
| Старый образ (откат) | `strata-nvfp4:sm120` | из прошлой ревизии, оставлен для отката |
| systemd-юнит | `/etc/systemd/system/strata-nvfp4.service` | **выключен по умолчанию** |
| Файл окружения | `/opt/strata-nvfp4.service.d/env` | `chmod 600`, root-only |
| Обёртка запуска | `/opt/strata-nvfp4.service.d/run.sh` | весь `docker run` одной командой |
| Логи | `journalctl -u strata-nvfp4` + `/var/log/strata-nvfp4/` | |

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

Если нужен автостарт при загрузке:

```sh
systemctl enable strata-nvfp4     # и systemctl disable, чтобы откатить
```

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
| `-p 8080:8080` | порт | API на `http://<host>:8080` |
| `--ulimit memlock=-1` | без лимита | движок `mlock`ает свои выделения |
| `-v /opt/strata-data:/data` | модель | 158 ГБ файлов модели, переиспользуются, не копируются |
| `-e FAMILY=qwen-nvfp4-mix` | семейство | NVFP4 + Q8_0 микс |
| `-e CONTEXT=262144` | 256K | рабочий контекст |
| `-e KV=int8` | 8-бит K/V | точность/память баланс |
| `-e VISION=yes` | картинки | энкодер на CPU, VRAM остаётся экспертам |
| `-e UNCENSORED=on` | цензура | проекция отказа отказа фотора из репозитория, грузится всегда, по умолчанию **включена** |
| `-e LOW_RAM=off` | все эксперты в RAM | 103 ГБ экспертов + запас |
| `-e HOST=0.0.0.0` | доступ из сети | вместе с `API_KEY` |
| `-e API_KEY=...` | ключ | клиенты должны его слать |
| `-e HF_TOKEN=...` | токен HF | на случай докачки чего-то |
| `--restart unless-stopped` | перезапуск | контейнер поднимется сам после ребута хоста |

**`/opt/strata-nvfp4.service.d/strata-start-v020.sh`** (внутри контейнера) — параметры
модели, две фазы:

```
фаза 1 (setup): setup.py --setup --no-start --family qwen-nvfp4-mix --model NVFP4 \
                 --context 262144 --kv int8 --vision yes --uncensored on --low-ram off \
                 --data-dir /data --host 0.0.0.0 --api-key ... --port 8080 --yes
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
curl -s localhost:8080/health | python3 -m json.tool

# 2. модель видна
curl -s -H "Authorization: Bearer $API_KEY" localhost:8080/v1/models | python3 -m json.tool

# 3. агентные поверхности выключены
curl -s -H "Authorization: Bearer $API_KEY" localhost:8080/mcp
#   ожидаем: {"servers": [], "tools": 0}

# 4. скорость
curl -s -H "Authorization: Bearer $API_KEY" localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"x","messages":[{"role":"user","content":"Скажи 200 слов про Linux"}],"max_tokens":300}' \
  | python3 -m json.tool
```

Ожидаемые числа на 5090: **~100 tok/s decode**, prefill ~6000 tok/s,
принятие MTP-драфта 72–92 %.

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

---

## 7. Пересборка движка

Нужна только если исходники форка обновились:

```sh
cd /opt/strata-nvfp4/src-0.2.0 && git pull          # или git checkout <commit>
# пересобрать контекст, остановив прод (нужна RAM под компиляцию):
docker stop strata-nvfp4
rsync -a --exclude .git /opt/strata-nvfp4/src-0.2.0/ /opt/strata-nvfp4/build-0.2.0/
cp -a /opt/strata-nvfp4/src/third_party/llama.cpp /opt/strata-nvfp4/build-0.2.0/third_party/
cd /opt/strata-nvfp4/build-0.2.0 && docker build -f Dockerfile.zen5-v020 -t strata-nvfp4:sm120-v020 .
```

**Прод при этом должен быть остановлен:** компиляция CUDA+LTO съедает всю
свободную RAM, а хост отдаёт под неё 122 ГБ всего.

---

## 8. Место в схеме хоста

```
llmhost1 (85.136.112.144:12007)
├── RTX 5080 (nvidia-smi idx 0) — ComfyUI, генерация картинок
└── RTX 5090 (nvidia-smi idx 1) — Strata NVFP4, LLM      ← этот сервис
```

Обе карты на PCIe Gen5 x8 (не x16) — lane sharing с M.2. Измеренная скорость
host↔device 28.9 GB/s у обеих, так что PCIe не бутылочное горлышко; различает
карты объём VRAM.
