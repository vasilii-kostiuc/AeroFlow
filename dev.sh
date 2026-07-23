#!/usr/bin/env bash
#
# AeroFlow local dev launcher — поднимает все сервисы одной командой.
#
# Порядок важен: aeroflow-core владеет общим RabbitMQ (порт 5672) и Postgres,
# к которым по host.docker.internal подключаются playback и agent. Поэтому core
# стартует первым (с --wait, чтобы брокер стал healthy), затем playback, затем
# agent. TTS — отдельный сервис синтеза речи, core зовёт его по HTTP на 8081.
# Web — это Vite dev-сервер на хосте (не в докере), проксирует /api на
# core (localhost:8080).
#
# По умолчанию agent запускается НА ХОСТЕ (реальный звук через ffplay), а не в
# докере: дефолты агента (RabbitMQ localhost:5672, core localhost:8080) совпадают
# с портами, которые пробрасывает docker. Для машин без аудиоустройства есть
# флаг --sim-agent — тогда вместо host-агента поднимается docker-контейнер в
# режиме Simulate (без звука).
#
# Два агента взаимоисключающие: они слушают одну очередь agent_commands, и если
# поднять оба, брокер раскидает объявления между ними — часть уйдёт в немой
# simulate. Поэтому запуск любого из вариантов сначала гасит другой.
#
# Использование:
#   ./dev.sh up          # поднять всё (core -> playback -> tts -> agent(host) -> web)
#   ./dev.sh up --sim-agent    # agent в докере (Simulate, без звука)
#   ./dev.sh up --no-migrate   # то же, но без doctrine-миграций
#   ./dev.sh down        # остановить всё (данные в volume сохраняются)
#   ./dev.sh restart     # down + up
#   ./dev.sh agent       # запустить только host-агент (реальный звук)
#   ./dev.sh migrate     # прогнать миграции core и playback
#   ./dev.sh ps          # статус контейнеров
#   ./dev.sh logs [core|playback|tts|agent|web]   # логи (по умолчанию — все docker)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

WEB_DIR="$ROOT/aeroflow-web"
WEB_PID="$ROOT/.dev-web.pid"
WEB_LOG="$ROOT/.dev-web.log"
WEB_PORT=5173

AGENT_DIR="$ROOT/aeroflow-agent"
AGENT_PID="$ROOT/.dev-agent.pid"
AGENT_LOG="$ROOT/.dev-agent.log"

# repo-dir : compose-project-name : service из этого репо, который держит app-контейнер
CORE_DC=(-f aeroflow-core/docker-compose.yml -p aeroflow-core)
PLAYBACK_DC=(-f aeroflow-playback/docker-compose.yml -p aeroflow-playback)
AGENT_DC=(-f aeroflow-agent/docker-compose.yml -p aeroflow-agent)
TTS_DC=(-f aeroflow-tts/docker-compose.yml -p aeroflow-tts)

log()  { printf '\033[1;36m[dev]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[dev]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[dev]\033[0m %s\n' "$*" >&2; }

migrate_one() {
  local name="$1"; shift
  local svc="$1"; shift
  log "Миграции $name…"
  if ! docker compose "$@" exec -T "$svc" php bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration; then
    warn "Миграции $name завершились с ошибкой — проверь вручную."
  fi
}

start_web() {
  if [ ! -d "$WEB_DIR/node_modules" ]; then
    log "Устанавливаю зависимости web (npm install)…"
    (cd "$WEB_DIR" && npm install)
  fi
  if [ -f "$WEB_PID" ] && kill -0 "$(cat "$WEB_PID")" 2>/dev/null; then
    log "Web уже запущен (pid $(cat "$WEB_PID"))."
    return
  fi
  log "Запускаю web (Vite) в фоне…"
  (cd "$WEB_DIR" && nohup npm run dev -- --port "$WEB_PORT" >"$WEB_LOG" 2>&1 &
   echo $! >"$WEB_PID")
  sleep 1
  log "Web логи: $WEB_LOG"
}

stop_web() {
  if [ -f "$WEB_PID" ]; then
    local pid; pid="$(cat "$WEB_PID")"
    if kill -0 "$pid" 2>/dev/null; then
      log "Останавливаю web (pid $pid)…"
      # Vite форкает дочерний процесс — гасим всю группу.
      kill "$pid" 2>/dev/null || true
      pkill -P "$pid" 2>/dev/null || true
    fi
    rm -f "$WEB_PID"
  fi
}

start_agent_host() {
  if ! command -v dotnet >/dev/null 2>&1; then
    err "dotnet не найден — host-агент не запущен. Поставь .NET SDK или используй --sim-agent."
    return 1
  fi
  if ! command -v ffplay >/dev/null 2>&1; then
    warn "ffplay не найден — реального звука не будет (агент упадёт на воспроизведении)."
    warn "Установи ffmpeg (ffplay) либо запускай с --sim-agent."
  fi
  if [ -f "$AGENT_PID" ] && kill -0 "$(cat "$AGENT_PID")" 2>/dev/null; then
    log "Host-агент уже запущен (pid $(cat "$AGENT_PID"))."
    return
  fi
  # Docker-агент слушает ту же очередь agent_commands. Если оставить его
  # поднятым, брокер раскидает объявления между ним и host-агентом, и часть
  # уйдёт в немой simulate. Агенты взаимоисключающие.
  stop_agent_docker

  log "Запускаю agent на хосте (реальный звук) в фоне…"
  # Дефолты AgentOptions уже указывают на localhost:5672 и localhost:8080,
  # Simulate=false — то, что нужно для звука. Первый запуск собирает проект.
  #
  # Запуск именно здесь, а не в подоболочке `( … & echo $! )`: там $! давал pid
  # не агента, и в pid-файл попадал сам dev.sh — stop убивал бы не то. Путь
  # проекта абсолютный, поэтому cd не нужен. </dev/null и перенаправление обоих
  # потоков в лог отвязывают агента от вызывающего терминала: иначе он держал бы
  # пайп открытым и `./dev.sh agent | …` не завершался бы.
  : >"$AGENT_LOG"
  nohup dotnet run --project "$AGENT_DIR/src/AeroFlow.Agent" </dev/null >"$AGENT_LOG" 2>&1 &
  echo $! >"$AGENT_PID"

  # Первый запуск собирает проект, поэтому ждём именно строку готовности, а не
  # фиксированную паузу: без неё «запустил» означало бы лишь «форкнул процесс».
  local waited=0
  while [ "$waited" -lt 90 ]; do
    if grep -q 'Agent consuming' "$AGENT_LOG" 2>/dev/null; then
      log "Host-агент готов (pid $(cat "$AGENT_PID")). Логи: $AGENT_LOG"
      return 0
    fi
    if ! kill -0 "$(cat "$AGENT_PID")" 2>/dev/null; then
      err "Host-агент упал на старте. Смотри $AGENT_LOG:"
      tail -n 15 "$AGENT_LOG" >&2
      rm -f "$AGENT_PID"
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done

  warn "Host-агент за ${waited}s не сообщил о готовности — проверь $AGENT_LOG."
}

stop_agent_docker() {
  if [ -n "$(docker compose "${AGENT_DC[@]}" ps -q 2>/dev/null)" ]; then
    log "Останавливаю docker-агент (конфликтует с host-агентом за agent_commands)…"
    docker compose "${AGENT_DC[@]}" down || true
  fi
}

stop_agent_host() {
  if [ -f "$AGENT_PID" ]; then
    local pid; pid="$(cat "$AGENT_PID")"
    if kill -0 "$pid" 2>/dev/null; then
      log "Останавливаю host-агент (pid $pid)…"
      # Сначала дочерний AeroFlow.Agent, потом сам `dotnet run`: убив родителя
      # первым, мы бы отдали ребёнка init и pkill -P его уже не нашёл.
      pkill -P "$pid" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
      for _ in 1 2 3 4 5; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
      done
    fi
    rm -f "$AGENT_PID"
  fi
}

cmd_up() {
  local do_migrate=1 sim_agent=0
  for arg in "$@"; do
    [ "$arg" = "--no-migrate" ] && do_migrate=0
    [ "$arg" = "--sim-agent" ] && sim_agent=1
  done

  log "1/5 core (Postgres + RabbitMQ + nginx + worker)…"
  docker compose "${CORE_DC[@]}" up -d --wait
  [ "$do_migrate" = 1 ] && migrate_one core aeroflow_core_app "${CORE_DC[@]}"

  log "2/5 playback (Postgres + worker)…"
  docker compose "${PLAYBACK_DC[@]}" up -d --wait
  [ "$do_migrate" = 1 ] && migrate_one playback aeroflow_playback_app "${PLAYBACK_DC[@]}"

  # Первая сборка тянет бинарник Piper и ~250 МБ голосовых моделей — долго.
  # Core зовёт TTS только при сохранении текста объявления, поэтому порядок
  # относительно core не критичен, но до сидинга сервис должен быть жив.
  log "3/5 tts (синтез речи)…"
  docker compose "${TTS_DC[@]}" up -d --wait

  if [ "$sim_agent" = 1 ]; then
    log "4/5 agent (docker, simulate mode — без звука)…"
    # Тот же взаимоисключающий контракт, что и в обратную сторону.
    stop_agent_host
    docker compose "${AGENT_DC[@]}" up -d
  else
    log "4/5 agent (на хосте, реальный звук)…"
    start_agent_host || warn "Host-агент не поднялся — см. сообщение выше."
  fi

  log "5/5 web…"
  start_web

  cat <<EOF

$(log "Готово. Точки входа:")
  web (диспетчер/админ):  http://localhost:$WEB_PORT
  core API (nginx):       http://localhost:8080
  tts (синтез речи):      http://localhost:8081
  RabbitMQ management:    http://localhost:15672  (guest/guest)
  core Postgres:          localhost:5432
  playback Postgres:      localhost:5433

Логи:   ./dev.sh logs [core|playback|tts|agent|web]
Стоп:   ./dev.sh down
EOF
}

cmd_down() {
  stop_web
  stop_agent_host
  # docker-агент гасим тоже — вдруг он был поднят через --sim-agent.
  log "Останавливаю agent…";    docker compose "${AGENT_DC[@]}" down || true
  log "Останавливаю tts…";      docker compose "${TTS_DC[@]}" down || true
  log "Останавливаю playback…"; docker compose "${PLAYBACK_DC[@]}" down || true
  log "Останавливаю core…";     docker compose "${CORE_DC[@]}" down || true
  log "Остановлено (volume с данными сохранены)."
}

cmd_migrate() {
  migrate_one core aeroflow_core_app "${CORE_DC[@]}"
  migrate_one playback aeroflow_playback_app "${PLAYBACK_DC[@]}"
}

cmd_ps() {
  for dc in CORE_DC PLAYBACK_DC TTS_DC AGENT_DC; do
    declare -n ref="$dc"
    docker compose "${ref[@]}" ps
  done
  if [ -f "$AGENT_PID" ] && kill -0 "$(cat "$AGENT_PID")" 2>/dev/null; then
    echo "agent (host): running (pid $(cat "$AGENT_PID"))"
  else
    echo "agent (host): stopped"
  fi
  if [ -f "$WEB_PID" ] && kill -0 "$(cat "$WEB_PID")" 2>/dev/null; then
    echo "web: running (pid $(cat "$WEB_PID"), port $WEB_PORT)"
  else
    echo "web: stopped"
  fi
}

cmd_logs() {
  case "${1:-all}" in
    core)     docker compose "${CORE_DC[@]}" logs -f ;;
    playback) docker compose "${PLAYBACK_DC[@]}" logs -f ;;
    tts)      docker compose "${TTS_DC[@]}" logs -f ;;
    agent)    if [ -f "$AGENT_PID" ] && kill -0 "$(cat "$AGENT_PID")" 2>/dev/null
              then tail -f "$AGENT_LOG"
              else docker compose "${AGENT_DC[@]}" logs -f; fi ;;
    web)      tail -f "$WEB_LOG" ;;
    all)      docker compose "${CORE_DC[@]}" logs -f &
              docker compose "${PLAYBACK_DC[@]}" logs -f &
              docker compose "${TTS_DC[@]}" logs -f &
              # agent: host-лог, если host-агент жив; иначе docker-контейнер.
              if [ -f "$AGENT_PID" ] && kill -0 "$(cat "$AGENT_PID")" 2>/dev/null
              then tail -f "$AGENT_LOG" &
              else docker compose "${AGENT_DC[@]}" logs -f &
              fi
              # web живёт только на хосте.
              [ -f "$WEB_LOG" ] && tail -f "$WEB_LOG" &
              wait ;;
    *) err "Неизвестный сервис: $1 (core|playback|tts|agent|web)"; exit 1 ;;
  esac
}

case "${1:-up}" in
  up)      shift || true; cmd_up "$@" ;;
  down)    cmd_down ;;
  restart) cmd_down; cmd_up "${@:2}" ;;
  agent)   start_agent_host ;;
  migrate) cmd_migrate ;;
  ps)      cmd_ps ;;
  logs)    cmd_logs "${2:-all}" ;;
  *) err "Неизвестная команда: $1"; sed -n '11,24p' "$0"; exit 1 ;;
esac
