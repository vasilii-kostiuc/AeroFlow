# Запуск AeroFlow локально

Все сервисы поднимаются одной командой через [`dev.sh`](dev.sh) в корне репозитория.

## Требования

* Docker + Docker Compose v2 (`docker compose`)
* Node.js 20+ и npm (для web/Vite — он запускается на хосте, не в докере)
* .NET SDK и `ffplay` (пакет ffmpeg) — для агента на хосте с реальным звуком;
  не нужны, если запускать агент в докере через `--sim-agent`

## Команды

```bash
./dev.sh up                # поднять всё: core → playback → agent(host) → web
./dev.sh up --sim-agent    # agent в докере (Simulate, без звука)
./dev.sh up --no-migrate   # то же, но без doctrine-миграций
./dev.sh down              # остановить всё (данные в volume сохраняются)
./dev.sh restart           # down + up
./dev.sh agent             # запустить только host-агент (реальный звук)
./dev.sh migrate           # прогнать миграции core и playback вручную
./dev.sh ps                # статус контейнеров, host-агента и web
./dev.sh logs [core|playback|tts|agent|web]   # логи (по умолчанию — все docker)
```

## Порядок запуска (почему именно такой)

`dev.sh up` поднимает сервисы строго по очереди:

1. **core** (`up -d --wait`) — Postgres + **RabbitMQ** + nginx + worker. Идёт
   первым, потому что владеет общим брокером RabbitMQ на порту `5672`, к которому
   по `host.docker.internal` подключаются остальные сервисы. `--wait` держит
   старт, пока брокер не станет healthy.
2. **playback** — свой Postgres (порт `5433`) + два worker'а; подключается к
   брокеру core. Второй worker слушает только `emergency_commands` (задача 026):
   команда включения/снятия экстренного режима не должна ждать, пока основной
   worker доработает очередь обычных объявлений.
3. **tts** — сервис синтеза речи (`aeroflow-tts`). Свой compose-проект, слушает
   `8081`; core зовёт его по HTTP при сохранении текста объявления. Первая
   сборка долгая: в образ кладётся бинарник Piper и ~250 МБ голосовых моделей
   (ru / en / ro-MD). Порядок относительно core не критичен — синтез нужен не
   при старте, а при сохранении конфигурации объявления.
4. **agent** — по умолчанию запускается **на хосте** (`dotnet run`, реальный звук
   через `ffplay`), в фоне; слушает `agent_commands` и ходит в core за
   аудиофайлами. Его дефолты (`localhost:5672`, `localhost:8080`) совпадают с
   портами, которые пробрасывает docker. С флагом `--sim-agent` вместо host-агента
   поднимается docker-контейнер в режиме `Simulate` (без звука) — для машин без
   аудиоустройства или CI.
5. **web** — Vite dev-сервер на хосте (в фоне), проксирует `/api → localhost:8080`.

По умолчанию `up` дополнительно прогоняет doctrine-миграции для core и playback
(с `--allow-no-migration`, поэтому повторный запуск безопасен) — чтобы с чистой
БД всё заработало сразу. Отключается флагом `--no-migrate`.

## Точки входа после `up`

| Что | Адрес |
| --- | --- |
| web (диспетчер / админ) | http://localhost:5173 |
| core API (nginx) | http://localhost:8080 |
| tts (синтез речи) | http://localhost:8081 |
| RabbitMQ management UI | http://localhost:15672 (guest / guest) |
| core Postgres | localhost:5432 |
| playback Postgres | localhost:5433 |

## Остановка

```bash
./dev.sh down
```

Гасит web-процесс и все контейнеры. Docker-**volume с данными Postgres
сохраняются** — при следующем `up` база остаётся на месте. Чтобы удалить и
данные, нужно вручную снести volume соответствующего compose-проекта
(`docker compose -f aeroflow-core/docker-compose.yml -p aeroflow-core down -v`).

## Примечания

* **Первый `up` будет долгим** — Docker собирает образы core / playback / tts /
  agent, причём образ tts дополнительно скачивает бинарник Piper и голосовые
  модели (~250 МБ). Последующие запуски быстрые.
* **Реальная речь** синтезируется Piper'ом (`TTS_MODE=piper`, режим по умолчанию
  в compose). На машине без моделей тот же образ работает с `TTS_MODE=simulate`,
  но выдаёт **тишину** — годится для тестов, не для звука. Важно: кэш генерации в
  core ключуется по тексту + языку + голосу + версии модели, поэтому после смены
  движка или голоса нужно поднять `modelVersion` в `aeroflow-tts/config/services.yaml`
  и переозвучить уже сохранённые объявления:
  `docker compose -f aeroflow-core/docker-compose.yml -p aeroflow-core exec aeroflow_core_app \
   php bin/console app:announcements:seed-configs --limit=24 --revoice`
* **Дополнительные (аэропортовые) объявления** — пресеты «Дополнительно» старой САО
  (безопасность, такси, ручная кладь, регистрация и т.д.) сидятся отдельной командой,
  тоже озвучивая тексты через TTS (идемпотентна по имени, `--revoice` пересоздаёт):
  `docker compose -f aeroflow-core/docker-compose.yml -p aeroflow-core exec aeroflow_core_app \
   php bin/console app:announcements:seed-supplementary`
* **Экстренные объявления** — пресеты раздела «Экстренные» старой САО (пожар,
  проверка сигнализации, эвакуация, отмена тревоги) сидятся своей командой, тоже
  через TTS (идемпотентна по имени, `--revoice` пересоздаёт):
  `docker compose -f aeroflow-core/docker-compose.yml -p aeroflow-core exec aeroflow_core_app \
   php bin/console app:announcements:seed-emergency`
  Дальше их можно править и дополнять на экране «Экстренные объявления»
  (`http://localhost:5173/emergency-announcements`), а диспетчер запускает их
  кнопкой «Экстренное объявление» на своей панели. Сам сид ничего не запускает и
  экстренный режим не включает.
* **Операционный день** панели диспетчера core считает по часовому поясу
  аэропорта — переменная `AIRPORT_TIMEZONE` в `aeroflow-core/.env` (IANA-имя, по
  умолчанию `Europe/Chisinau`), а не по часам браузера (задача 027).
* **Пользователи и роли** (задача 033). Самостоятельной регистрации нет —
  учётки создаёт администратор на экране «Пользователи». Фикстуры core
  (`doctrine:fixtures:load`) дают `admin@aeroflow.local` (администратор),
  `dispatcher@aeroflow.local` (диспетчер) и `operator@aeroflow.local` (без роли —
  экран «Нет доступа»), пароль у всех `AeroFlow123!`. На чистой БД без фикстур
  первого администратора создаёт консоль:
  `docker compose -f aeroflow-core/docker-compose.yml -p aeroflow-core exec -u www-data aeroflow_core_app \
   php bin/console app:users:create admin@example.org --role=admin`
  (пароль спросит интерактивно; `--role` — `admin`, `dispatcher` или `none`).
* **Состояние системы** (задача 034) — экран администратора
  `http://localhost:5173/system-status`; диспетчер видит в панели красный баннер,
  если объявления могут не прозвучать. Воркеры core и playback раз в 15 с пишут
  heartbeat, остановленный воркер считается неработающим через 60 с. Агента core
  видит через management API RabbitMQ (`RABBITMQ_MANAGEMENT_URL`, в compose уже
  задан) по числу подписчиков на `agent_commands`: если host-агент не
  стартовал, экран сразу показывает его как «Не подключён». Проверка руками:
  `docker stop aeroflow_playback_worker` — через минуту предупреждение на экране и
  в панели, `docker start aeroflow_playback_worker` — пропадает.
* Web и host-агент запускаются в фоне; их PID/логи в корне —
  `.dev-web.pid`/`.dev-web.log` и `.dev-agent.pid`/`.dev-agent.log` (все в
  `.gitignore`). Смотреть лог: `./dev.sh logs web` / `./dev.sh logs agent`.
* **Реальный звук** идёт через host-агента (запуск по умолчанию). Первый запуск
  `dotnet run` собирает проект — это дольше. Нужны .NET SDK и `ffplay`; без
  `ffplay` агент поднимется, но упадёт на воспроизведении. Если звук не нужен —
  `./dev.sh up --sim-agent` (docker, `Simulate`).
* Отдельно поднять только агента (например, core уже запущен) —
  `./dev.sh agent`.
