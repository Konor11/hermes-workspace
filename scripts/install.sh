#!/usr/bin/env bash
#
# Hermes Workspace — автоустановка на чистый сервер (Ubuntu/Debian).
#
# Два режима рантайма (--mode):
#   systemd  (по умолчанию) — Hermes Agent ставится системно, gateway/dashboard/
#            workspace поднимаются как systemd-юниты, Caddy ставится системно.
#   docker   — всё в контейнерах: Hermes Agent (nousresearch/hermes-agent),
#            Workspace (собранный из Dockerfile репо) и Caddy — через docker compose.
#
# Порты: workspace ищет свободный 3000→3001→… ; gateway 8642 / dashboard 9119
# проверяются и при необходимости сдвигаются. Домены задаются через
# --domain (workspace), --dashboard-domain, --gateway-domain — любые FQDN.
#
# Использование:
#   sudo bash scripts/install.sh --domain ws.example.com
#   sudo bash scripts/install.sh --domain ws.example.com --dashboard-domain hermes.example.com
#   sudo bash scripts/install.sh --mode docker --domain ws.example.com
#   sudo bash scripts/install.sh --dry-run
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Цветной вывод
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
  C_BLU=$'\033[0;34m'; C_RST=$'\033[0m'; C_BLD=$'\033[1m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_RST=''; C_BLD=''
fi

info()  { echo "${C_BLU}ℹ${C_RST} $*"; }
ok()    { echo "${C_GRN}✓${C_RST} $*"; }
warn()  { echo "${C_YEL}⚠${C_RST} $*"; }
err()   { echo "${C_RED}✗${C_RST} $*" >&2; }
die()   { err "$*"; exit 1; }
step()  { echo; echo "${C_BLD}${C_BLU}==>${C_RST} $*"; }

# ---------------------------------------------------------------------------
# Параметры
# ---------------------------------------------------------------------------
WS_DIR="/root/hermes-workspace"
REPO_URL="https://github.com/outsourc-e/hermes-workspace.git"
GIT_REF="main"
DO_BUILD=1
UPDATE=0
DRY_RUN=0
MODE="systemd"
DOMAIN=""
DASH_DOMAIN=""
GW_DOMAIN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)             WS_DIR="$2"; shift 2 ;;
    --repo)            REPO_URL="$2"; shift 2 ;;
    --ref)             GIT_REF="$2"; shift 2 ;;
    --mode)            MODE="$2"; shift 2 ;;
    --domain)          DOMAIN="$2"; shift 2 ;;
    --dashboard-domain) DASH_DOMAIN="$2"; shift 2 ;;
    --gateway-domain)  GW_DOMAIN="$2"; shift 2 ;;
    --no-build)        DO_BUILD=0; shift ;;
    --update)          UPDATE=1; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

[[ "$MODE" == "systemd" || "$MODE" == "docker" ]] || die "Неизвестный --mode: $MODE (systemd|docker)"
run() { if [[ "$DRY_RUN" -eq 1 ]]; then info "[dry-run] $*"; else eval "$@"; fi; }
[[ "$(id -u)" -eq 0 ]] || die "Запускай от root: sudo bash $0"
[[ "${BASH_VERSINFO:-0}" -ge 4 ]] || die "Нужен bash 4+ (у тебя ${BASH_VERSION})"

ENV_FILE="/root/.hermes/workspace_env.conf"
CADDY_FILE="/etc/caddy/Caddyfile"

# ---------------------------------------------------------------------------
# Утилиты портов
# ---------------------------------------------------------------------------
port_free() {
  # $1 = порт; возвращает 0 если свободен
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$" && return 1
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 1 "http://127.0.0.1:${p}/" >/dev/null 2>&1 && return 1
  fi
  return 0
}

next_free_port() {
  # $1 = стартовый порт; печатает первый свободный >= старта (только число, в stdout)
  local p="$1"
  while ! port_free "$p"; do
    echo "  ⚠ Порт $p занят — пробую $((p+1))" >&2
    p=$((p+1))
  done
  echo "$p"
}

# ---------------------------------------------------------------------------
# 1. Зависимости
# ---------------------------------------------------------------------------
step "Проверка зависимостей"
need() { command -v "$1" >/dev/null 2>&1 || die "Не найдено: $1"; }
need curl; need git; need python3

# Системные пакеты, нужные для сборки hermes-agent (pip) и workspace (node-gyp):
# gcc/g++/make, заголовки python и openssl, а также базовые утилиты.
ensure_build_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    info "Ставлю системные зависимости сборки (apt) …"
    run "apt-get update -y"
    run "DEBIAN_FRONTEND=noninteractive apt-get install -y \
      build-essential python3-dev python3-venv python3-pip \
      libssl-dev libffi-dev libsqlite3-dev \
      curl git ca-certificates gnupg lsb-release"
  elif command -v dnf >/dev/null 2>&1; then
    info "Ставлю системные зависимости сборки (dnf) …"
    run "dnf -y install gcc gcc-c++ make python3-devel openssl-devel \
      libffi-devel sqlite-devel curl git"
  elif command -v apk >/dev/null 2>&1; then
    info "Ставлю системные зависимости сборки (apk) …"
    run "apk add --no-cache build-base python3-dev openssl-dev libffi-dev \
      sqlite-dev curl git"
  else
    warn "Неизвестный пакетный менеджер — пропускаю установку системных зависимостей."
    warn "Убедись, что установлены: gcc, g++, make, python3-dev, libssl-dev."
  fi
}

if ! command -v node >/dev/null 2>&1; then
  die "Node.js не установлен. Поставь Node 22+ и повтори."
fi
NODE_MAJOR=$(node -v | sed -E 's/v([0-9]+).*/\1/')
[[ "$NODE_MAJOR" -lt 22 ]] && die "Нужен Node.js 22+, сейчас v${NODE_MAJOR}."
ok "Node v$(node -v) ✓"
need npm; ok "npm $(npm -v) ✓"
if [[ "$MODE" == "docker" ]]; then
  need docker
  docker compose version >/dev/null 2>&1 || die "Нужен 'docker compose' (v2)."
  ok "docker $(docker --version) ✓"
fi

# Выбор портов (workspace ищет 3000→…; gateway/dashboard проверяем)
WS_PORT=$(next_free_port 3000)
GW_PORT=8642; port_free 8642 || GW_PORT=$(next_free_port 8643)
DASH_PORT=9119; port_free 9119 || DASH_PORT=$(next_free_port 9120)
info "Выбраны порты: workspace=:$WS_PORT  gateway=:$GW_PORT  dashboard=:$DASH_PORT"

# ---------------------------------------------------------------------------
# 2. Hermes Agent
# ---------------------------------------------------------------------------
step "Hermes Agent"
if command -v hermes >/dev/null 2>&1 && hermes --version >/dev/null 2>&1; then
  ok "Hermes Agent уже установлен: $(hermes --version 2>/dev/null || echo present)"
else
  warn "Hermes Agent не найден. Ставлю …"
  ensure_build_deps
  # НЕ используем официальный one-liner install.sh — он тянет устаревший
  # релиз (0.19.0). Ставим свежую версию через pip (как на рабочем сервере).
  run "python3 -m venv /usr/local/lib/hermes-agent/venv"
  run "/usr/local/lib/hermes-agent/venv/bin/pip install -U pip"
  run "/usr/local/lib/hermes-agent/venv/bin/pip install 'hermes-agent==0.20.4'"
  run "ln -sf /usr/local/lib/hermes-agent/venv/bin/hermes /usr/local/bin/hermes"
  command -v hermes >/dev/null 2>&1 || die "Не удалось установить Hermes Agent."
  ok "Hermes Agent $(hermes --version 2>/dev/null || echo установлен)"
fi

# ---------------------------------------------------------------------------
# 3. Gateway + Dashboard
# ---------------------------------------------------------------------------
if [[ "$MODE" == "systemd" ]]; then
  step "Gateway + Dashboard (systemd)"

  # hermes gateway install на чистом сервере НЕ создаёт юнит — пишем сами.
  GW_UNIT="/etc/systemd/system/hermes-gateway.service"
  DASH_UNIT="/etc/systemd/system/hermes-dashboard.service"

  # /root/.hermes/.env — нужен gateway для запуска API-сервера (API_SERVER_KEY)
  HERMES_ENV="/root/.hermes/.env"
  if [[ ! -f "$HERMES_ENV" && "$DRY_RUN" -eq 0 ]]; then
    mkdir -p /root/.hermes
    # Сгенерируем ключ, если ещё нет (используем для gateway API + workspace)
    GEN_KEY=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)
    cat > "$HERMES_ENV" <<EOF
HOME=/root
API_SERVER_ENABLED=true
API_SERVER_KEY=$GEN_KEY
API_SERVER_HOST=0.0.0.0
EOF
    chmod 600 "$HERMES_ENV"
    ok ".env gateway записан (API_SERVER_KEY сгенерирован)"
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] пропускаю запись $HERMES_ENV"
  fi

  if [[ -f "$GW_UNIT" && "$DRY_RUN" -eq 0 && "$UPDATE" -eq 0 ]]; then
    warn "$GW_UNIT уже существует — не перезаписываю."
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] пропускаю запись $GW_UNIT"
  else
    info "Устанавливаю $GW_UNIT (порт $GW_PORT) …"
    cat > "$GW_UNIT" <<EOF
[Unit]
Description=Hermes Gateway
After=network-online.target

[Service]
Type=simple
User=root
Environment="HOME=/root"
EnvironmentFile=/root/.hermes/.env
ExecStart=/usr/local/bin/hermes gateway run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    ok "Gateway unit записан"
  fi

  if [[ -f "$DASH_UNIT" && "$DRY_RUN" -eq 0 && "$UPDATE" -eq 0 ]]; then
    warn "$DASH_UNIT уже существует — не перезаписываю."
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] пропускаю запись $DASH_UNIT"
  else
    info "Устанавливаю $DASH_UNIT (порт $DASH_PORT) …"
    cat > "$DASH_UNIT" <<EOF
[Unit]
Description=Hermes Dashboard
After=network-online.target hermes-gateway.service
Wants=hermes-gateway.service

[Service]
Type=simple
User=root
Environment="HOME=/root"
EnvironmentFile=/root/.hermes/dashboard_auth_env.conf
ExecStart=/usr/local/bin/hermes dashboard --host 0.0.0.0 --port $DASH_PORT --no-open --tui
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    ok "Dashboard unit записан"
  fi

  run systemctl daemon-reload
  run systemctl enable hermes-gateway.service
  run systemctl enable hermes-dashboard.service
  run systemctl restart hermes-gateway.service
  run systemctl restart hermes-dashboard.service
  if [[ "$DRY_RUN" -eq 0 ]]; then
    sleep 5
    curl -fsS --max-time 5 "http://127.0.0.1:$GW_PORT/health" >/dev/null 2>&1 && ok "Gateway :$GW_PORT ✅" || warn "Gateway :$GW_PORT не отвечает"
    curl -fsS --max-time 5 "http://127.0.0.1:$DASH_PORT/" >/dev/null 2>&1 && ok "Dashboard :$DASH_PORT ✅" || warn "Dashboard :$DASH_PORT не отвечает"
  fi
else
  step "Gateway + Dashboard (docker)"
  run "docker pull nousresearch/hermes-agent:latest"
  ok "Образ hermes-agent получен (запуск через compose)"
fi

# ---------------------------------------------------------------------------
# 4. Репозиторий workspace
# ---------------------------------------------------------------------------
step "Репозиторий workspace"
if [[ -d "$WS_DIR/.git" ]]; then
  if [[ "$UPDATE" -eq 1 && "$DRY_RUN" -eq 0 ]]; then
    info "Обновляю $WS_DIR …"
    git -C "$WS_DIR" fetch --all --tags
    git -C "$WS_DIR" checkout "$GIT_REF"
    git -C "$WS_DIR" pull --ff-only || true
  elif [[ "$UPDATE" -eq 1 && "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] пропускаю git pull в $WS_DIR"
  else
    warn "$WS_DIR уже существует — пропускаю клон (используй --update для pull)."
  fi
else
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] пропускаю клон $REPO_URL → $WS_DIR"
  else
    info "Клонирую $REPO_URL → $WS_DIR …"
    mkdir -p "$(dirname "$WS_DIR")"
    git clone --depth 1 --branch "$GIT_REF" "$REPO_URL" "$WS_DIR"
  fi
fi
ok "Репозиторий: $WS_DIR"
[[ "$DRY_RUN" -eq 0 ]] && cd "$WS_DIR"

# ---------------------------------------------------------------------------
# 5. Сборка
# ---------------------------------------------------------------------------
if [[ "$DO_BUILD" -eq 1 ]]; then
  step "npm install + build"
  info "npm install (это может занять несколько минут) …"
  run "npm install"
  info "npm run build (NODE_OPTIONS=--max-old-space-size=3072) …"
  run "NODE_OPTIONS=\"--max-old-space-size=3072\" npm run build"
  [[ "$DRY_RUN" -eq 0 ]] && ok "Сборка завершена"
else
  warn "Сборка пропущена (--no-build). Убедись, что dist/ уже собран."
fi

# ---------------------------------------------------------------------------
# 6. Секреты (workspace_env.conf)
# ---------------------------------------------------------------------------
step "Конфигурация /root/.hermes/workspace_env.conf"
mkdir -p /root/.hermes

prompt_secret() {
  local key="$1" hint="$2" cur="${3:-}" val=""
  if [[ "$DRY_RUN" -eq 1 ]]; then
    val="${cur:-<dry-run>}"
    printf '%s=%s\n' "$key" "$val"
    return
  fi
  if [[ -n "$cur" ]]; then
    hint="$hint ${C_YEL}(текущее задано, Enter — оставить)${C_RST}"
  fi
  if [[ -t 0 ]]; then
    read -r -p "  $key — $hint: " val </dev/tty 2>&1 || true
  else
    read -r -p "  $key — $hint: " val || true
  fi
  [[ -z "$val" && -n "$cur" ]] && val="$cur"
  printf '%s=%s\n' "$key" "$val"
}

cur_token=$(grep -E '^HERMES_API_TOKEN='  "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
# Если токен ещё не задан — берём сгенерированный API_SERVER_KEY из .env gateway,
# чтобы workspace мог подключиться к тому же gateway без ручного ввода.
if [[ -z "$cur_token" && -n "${GEN_KEY:-}" ]]; then
  cur_token="$GEN_KEY"
  info "HERMES_API_TOKEN возьмёт сгенерированный API_SERVER_KEY (можно Enter)."
fi
cur_pw=$(grep -E '^HERMES_PASSWORD='      "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
cur_bu=$(grep -E '^HERMES_DASHBOARD_BASIC_AUTH_USERNAME=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
cur_bp=$(grep -E '^HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)

echo "Введи параметры подключения к Hermes Gateway/Dashboard."
echo "(HERMES_API_TOKEN = API_SERVER_KEY гейтвея; basic-auth — из dashboard_auth_env.conf)"
{
  prompt_secret "HERMES_API_TOKEN" "Bearer-токен гейтвея (API_SERVER_KEY)" "$cur_token"
  prompt_secret "HERMES_PASSWORD" "пароль входа в Workspace" "$cur_pw"
  prompt_secret "HERMES_DASHBOARD_BASIC_AUTH_USERNAME" "basic-auth user дашборда" "$cur_bu"
  prompt_secret "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD" "basic-auth пароль дашборда" "$cur_bp"
  echo "HERMES_WORKSPACE_DIR=$WS_DIR"
} | if [[ "$DRY_RUN" -eq 1 ]]; then
      cat >/dev/null
      info "[dry-run] запись $ENV_FILE пропущена"
    else
      cat > "$ENV_FILE"
    fi
[[ "$DRY_RUN" -eq 0 ]] && chmod 600 "$ENV_FILE"
ok "Записано: $ENV_FILE (chmod 600)"

# ---------------------------------------------------------------------------
# 7. Workspace unit / контейнер
# ---------------------------------------------------------------------------
if [[ "$MODE" == "systemd" ]]; then
  step "systemd unit hermes-workspace.service (порт $WS_PORT)"
  UNIT="/etc/systemd/system/hermes-workspace.service"
  if [[ -f "$UNIT" && "$UPDATE" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
    warn "$UNIT уже существует — не перезаписываю (используй --update для перезаписи)."
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] пропускаю запись $UNIT"
  else
    info "Устанавливаю $UNIT …"
    cat > "$UNIT" <<EOF
[Unit]
Description=Hermes Workspace
After=network-online.target hermes-gateway.service hermes-dashboard.service
Wants=hermes-gateway.service hermes-dashboard.service

[Service]
Type=simple
User=root
WorkingDirectory=$WS_DIR
Environment="HOME=/root"
Environment="PORT=$WS_PORT"
Environment="HOST=0.0.0.0"
Environment="COOKIE_SECURE=1"
Environment="HERMES_HOME=/root/.hermes"
Environment="HERMES_API_URL=http://127.0.0.1:$GW_PORT"
Environment="HERMES_DASHBOARD_URL=http://127.0.0.1:$DASH_PORT"
EnvironmentFile=$ENV_FILE
ExecStartPre=/bin/bash -c "for i in \$(seq 1 30); do /usr/bin/curl -sf http://127.0.0.1:$GW_PORT/health >/dev/null 2>&1 && break; sleep 1; done" || true
ExecStart=/usr/local/bin/node server-entry.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    ok "Unit записан"
  fi
  run systemctl daemon-reload
  run systemctl enable hermes-workspace.service
  run systemctl restart hermes-workspace.service
  if [[ "$DRY_RUN" -eq 0 ]]; then
    up=0
    for i in $(seq 1 30); do
      curl -fsS --max-time 3 "http://127.0.0.1:$WS_PORT/" >/dev/null 2>&1 && up=1 && break
      sleep 1
    done
    [[ "$up" -eq 1 ]] && ok "Workspace :$WS_PORT ✅" || err "Workspace не поднялся за 30с (journalctl -u hermes-workspace -n 50)"
  else
    info "[dry-run] пропускаю проверку :$WS_PORT"
  fi
else
  step "Workspace (docker build + compose)"
  run "docker build -t hermes-workspace:local ."
  ok "Образ hermes-workspace:local собран"
fi

# ---------------------------------------------------------------------------
# 8. Caddy (reverse proxy + HTTPS)
# ---------------------------------------------------------------------------
step "Caddy (reverse proxy, HTTPS)"
# Формируем блоки проксирования для Caddy
if [[ "$MODE" == "systemd" ]]; then
  if command -v caddy >/dev/null 2>&1; then
    ok "Caddy уже установлен: $(caddy version 2>/dev/null | head -1)"
  else
    run "apt-get update -y"
    run "apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl"
    run "curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg"
    run "echo 'deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/debian/deb/ stable main' > /etc/apt/sources.list.d/caddy-stable.list"
    run "apt-get update -y"
    run "apt-get install -y caddy"
    ok "Caddy установлен"
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] пропускаю запись $CADDY_FILE"
  else
    info "Пишу $CADDY_FILE …"
    {
      if [[ -n "$DOMAIN" ]]; then
        echo "$DOMAIN {"
        echo "    reverse_proxy 127.0.0.1:$WS_PORT"
        echo "}"
      else
        echo ":80 {"
        echo "    reverse_proxy 127.0.0.1:$WS_PORT"
        echo "}"
      fi
      if [[ -n "$DASH_DOMAIN" ]]; then
        echo ""
        echo "$DASH_DOMAIN {"
        echo "    reverse_proxy 127.0.0.1:$DASH_PORT"
        echo "}"
      fi
      if [[ -n "$GW_DOMAIN" ]]; then
        echo ""
        echo "$GW_DOMAIN {"
        echo "    reverse_proxy 127.0.0.1:$GW_PORT"
        echo "}"
      fi
    } > "$CADDY_FILE"
    ok "Caddyfile записан"
  fi
  run systemctl daemon-reload
  run systemctl enable caddy
  run systemctl restart caddy
  if [[ "$DRY_RUN" -eq 0 && -n "$DOMAIN" ]]; then
    sleep 3
    curl -fsS --max-time 5 "https://$DOMAIN/" >/dev/null 2>&1 && ok "Caddy $DOMAIN (HTTPS) ✅" || warn "Caddy $DOMAIN не отвечает (DNS + 80/443 открыты?)"
  fi
else
  info "Caddy будет контейнером через docker compose."
fi

# ---------------------------------------------------------------------------
# 9. docker-режим: compose
# ---------------------------------------------------------------------------
if [[ "$MODE" == "docker" ]]; then
  step "docker compose up"
  COMPOSE="$WS_DIR/docker-compose.yml"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] пропускаю docker compose up ($COMPOSE)"
  else
    if [[ ! -f "$COMPOSE" ]]; then
      cat > "$COMPOSE" <<EOF
services:
  hermes:
    image: nousresearch/hermes-agent:latest
    container_name: hermes-agent
    restart: always
    environment:
      - HERMES_HOME=/root/.hermes
    volumes:
      - /root/.hermes:/root/.hermes
    command: ["gateway", "run"]
  workspace:
    image: hermes-workspace:local
    container_name: hermes-workspace
    restart: always
    env_file:
      - /root/.hermes/workspace_env.conf
    environment:
      - PORT=$WS_PORT
      - HOST=0.0.0.0
      - HERMES_API_URL=http://hermes:$GW_PORT
      - HERMES_DASHBOARD_URL=http://hermes:$DASH_PORT
    depends_on:
      - hermes
  caddy:
    image: caddy:latest
    container_name: hermes-caddy
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile.docker:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - workspace
volumes:
  caddy_data:
  caddy_config:
EOF
    fi
    {
      if [[ -n "$DOMAIN" ]]; then
        echo "$DOMAIN {"
        echo "    reverse_proxy workspace:$WS_PORT"
        echo "}"
      else
        echo ":80 {"
        echo "    reverse_proxy workspace:$WS_PORT"
        echo "}"
      fi
      if [[ -n "$DASH_DOMAIN" ]]; then
        echo ""
        echo "$DASH_DOMAIN {"
        echo "    reverse_proxy workspace:$DASH_PORT"
        echo "}"
      fi
      if [[ -n "$GW_DOMAIN" ]]; then
        echo ""
        echo "$GW_DOMAIN {"
        echo "    reverse_proxy hermes:$GW_PORT"
        echo "}"
      fi
    } > "$WS_DIR/Caddyfile.docker"
    run "docker compose -f $COMPOSE up -d"
    ok "Контейнеры подняты"
  fi
fi

# ---------------------------------------------------------------------------
# Финал
# ---------------------------------------------------------------------------
echo
echo "${C_GRN}${C_BLD}Готово!${C_RST} (режим: $MODE)"
if [[ -n "$DOMAIN" ]]; then
  echo "  Workspace : https://$DOMAIN/  (порт $WS_PORT)"
else
  echo "  Workspace : http://127.0.0.1:$WS_PORT/  (порт $WS_PORT; задать --domain для HTTPS)"
fi
if [[ -n "$DASH_DOMAIN" ]]; then
  echo "  Dashboard : https://$DASH_DOMAIN/  (порт $DASH_PORT)"
else
  echo "  Dashboard : http://127.0.0.1:$DASH_PORT/  (задать --dashboard-domain для доступа по домену)"
fi
if [[ -n "$GW_DOMAIN" ]]; then
  echo "  Gateway   : https://$GW_DOMAIN/  (порт $GW_PORT)"
else
  echo "  Gateway   : http://127.0.0.1:$GW_PORT/health  (порт $GW_PORT)"
fi
echo "  Журналы   : $([[ "$MODE" == systemd ]] && echo "journalctl -u hermes-workspace -f" || echo "docker compose -f $WS_DIR/docker-compose.yml logs -f")"
echo
echo "Для HTTPS убедись, что DNS каждого домена указывает на этот сервер и"
echo "порты 80/443 открыты — Caddy сам выпустит TLS-сертификаты Let's Encrypt."
