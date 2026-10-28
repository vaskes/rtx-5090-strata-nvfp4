# Подключение бота к Strata NVFP4 — инструкция для Mavis

Короткая версия: Strata — это OpenAI-совместимый HTTP-сервис на llmhost1.
Бот подключается к нему как к обычному `/v1/chat/completions`.

---

## 1. Точка подключения

```
BASE_URL = http://<llmhost1>:8080     # внутри LAN: http://192.168.10.6:8080
API_KEY  = <тот же, что в /opt/strata-nvfp4.service.d/env, поле API_KEY>
MODEL    = qwen3.8-flash-next-nvfp4   # имя из /v1/models, можно взять оттуда
```

Из песочницы Mavis хост доступен как `llmhost1` (`ssh llmhost1`).
По SSH-туннелю: `ssh -L 8080:127.0.0.1:8080 llmhost1` → `http://127.0.0.1:8080`.

**Порт 8080 на llmhost1 уже занят контейнером `strata-nvfp4`** — это он и есть.

---

## 2. Проверка перед подключением

```sh
# жив ли сервис
curl -s http://localhost:8080/health | python3 -m json.tool

# какая модель и какой контекст
curl -s -H "Authorization: Bearer $API_KEY" http://localhost:8080/v1/models

# быстрый смоук
curl -s -H "Authorization: Bearer $API_KEY" http://localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-flash-next-nvfp4","messages":[{"role":"user","content":"Привет"}],"max_tokens":64}'
```

Если `/health` отвечает, а `/v1/models` нет — скорее всего не тот API-ключ.

---

## 3. Формат запроса

Strata отдаёт OpenAI-совместимый формат:

```json
{
  "model": "qwen3.8-flash-next-nvfp4",
  "messages": [
    {"role": "system", "content": "..."},
    {"role": "user",   "content": "..."}
  ],
  "max_tokens": 1024,
  "temperature": 0.7
}
```

Ответ:

```json
{
  "choices": [{"message": {"role": "assistant", "content": "..."}, "finish_reason": "stop"}],
  "usage": {"prompt_tokens": 52, "completion_tokens": 311, "total_tokens": 363}
}
```

### ⚠️ Две ловушки, которые стоят часа

**Ловушка 1: `max_tokens` должен быть БОЛЬШЕ бюджета размышления.**

Модель сначала думает (reasoning), потом отвечает. Если
`reasoning_budget == max_tokens`, весь бюджет съедает reasoning, и `content`
приходит **пустым**, а `finish_reason` = `length`. Симптом: «модель отвечает, но
текста нет».

```json
// ПЛОХО: max_tokens=200 при reasoning_budget=200 -> content пустой
{"messages": [...], "max_tokens": 200, "reasoning_budget": 200}

// ХОРОШО: бюджет меньше max_tokens с запасом
{"messages": [...], "max_tokens": 2000, "reasoning_budget": 512}
```

**Ловушка 2: реальная стена — это контекст, а не `max_tokens`.**

`prompt + thinking + answer ≤ 262144`. Длинная история чата съедает окно;
Strata обрежет запрос, а не ответит ошибкой. Считай:

```
доступно_на_ответ = 262144 - prompt_tokens - reasoning_budget
```

---

## 4. Агентные фичи Strata — НЕ включать

В форке есть MCP-клиент (`--mcp-config`, `mcp_servers` в конфиге) и
`{"strata_mcp": true}` в теле запроса. **В проде всё это выключено**, и включать
не надо. Проверка, что выключено:

```sh
curl -s -H "Authorization: Bearer $API_KEY" http://localhost:8080/mcp
# {"servers": [], "tools": 0}
```

Если тут появились серверы — значит кто-то добавил `mcp_servers` в конфиг.
Также проверь, что в контейнере нет процесса `tools/strata_mcp.py`:

```sh
docker exec strata-nvfp4 sh -c 'ps aux | grep -c "[s]trata_mcp"'
# ожидаем 0
```

**Кто вызывает Strata — тот и владеет инструментами.** Бот сам решает, какие
инструменты звать; Strata в этом не участвует. Это чистый LLM-сервер.

---

## 5. Подключение к боту — пример на Python (OpenAI SDK)

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://192.168.10.6:8080/v1",
    api_key="<API_KEY из env-файла>",
)

resp = client.chat.completions.create(
    model="qwen3.8-flash-next-nvfp4",
    messages=[{"role": "user", "content": "Привет"}],
    max_tokens=1024,
)
print(resp.choices[0].message.content)
```

`base_url` с `/v1` — SDK добавит `/chat/completions` сам.

---

## 6. Особые режимы

### 512K контекст (спецрежим, не норма)

Отдельный сервис с другими флагами:

```
--max-context 524288 --kv q4_0 --rope-scaling yarn --rope-scale 2
```

Проверено: needle-тест на 142 933 токенах проходит, prefill 6237 tok/s,
decode 86.8 tok/s, VRAM 31.6/32 ГБ. Но это **другой контейнер на той же карте** —
одновременно с 256K-инстансом 5090 не поднять (VRAM кончится).

### Vision (картинки)

Энкодер на CPU, отдельный `mmproj` уже на месте. Работает из коробки: в
сообщении передаётся image_url.

```json
{"role": "user", "content": [
  {"type": "text", "text": "Что на картинке?"},
  {"type": "image_url", "image_url": {"url": "data:image/png;base64,..."}}
]}
```

---

## 7. Если что-то не работает

| Симптом | Причина | Что делать |
|---|---|---|
| `Connection refused` | контейнер не поднят | `systemctl status strata-nvfp4` на llmhost1 |
| 401/403 | неверный API-ключ | взять из `/opt/strata-nvfp4.service.d/env` |
| `content` пустой, `finish_reason=length` | `max_tokens` ≤ бюджета размышления | увеличить `max_tokens` |
| ответ обрезан на середине | контекст исчерпан | сократить историю или уменьшить `reasoning_budget` |
| очень медленно | запрос попал на RTX 5080 | проверить `--gpus '"device=1"'` в `run.sh` |
| `the K/V cannot grow to this prompt: no VRAM is left` | контекст выше того, что влезает в VRAM | для 256K нужен int8 KV и 5090; на 5080 потолок ~62K |

Логи движка: `journalctl -u strata-nvfp4 -f` и
`/var/log/strata-nvfp4/strata-qwen-mix-nvfp4.log` (туда пишутся per-request
строки с tok/s и cache hit).

---

## 8. Что этот сервис НЕ делает

- Не скачивает модель сам — файлы уже на диске и проверены по SHA-256.
- Не компилирует движок на старте — движок внутри образа.
- Не запускает MCP-серверы и не имеет агентного цикла.
- Не трогает RTX 5080 (ComfyUI).
