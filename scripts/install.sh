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
# Что делает:
#   1. Проверяет зависимости (bash4+, curl, git, python3, Node 22+; docker — для --mode docker).
#   2. Ставит Hermes Agent (если ещё не установлен).
#   3. Поднимает Gateway (:8642) + Dashboard (:9119) — systemd или docker.
#   4. Клонирует форк hermes-workspace, npm install + npm run build.
#   5. Пишет /root/.hermes/workspace_env.conf (секреты интерактивно).
#   6. Поднимает Workspace (:3001) — systemd или docker.
#   7. Ставит Caddy и проксирует домены (HTTPS, авто-Let's Encrypt).
#
# Требования: запуск от root.
# Использование:
#   sudo bash scripts/install.sh                         # systemd + caddy
#   sudo bash scripts/install.sh --mode docker           # всё в docker
#   sudo bash scripts/install.sh --domain ws.example.com --dir /opt/hermes-workspace
#   sudo bash scripts/install.sh --dry-run               # только проверки
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)      WS_DIR="$2"; shift 2 ;;
    --repo)     REPO_URL="$2"; shift 2 ;;
    --ref)      GIT_REF="$2"; shift 2 ;;
    --mode)     MODE="$2"; shift 2 ;;
    --domain)   DOMAIN="$2"; shift 2 ;;
    --no-build) DO_BUILD=0; shift ;;
    --update)   UPDATE=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

[[ "$MODE" == "systemd" || "$MODE" == "docker" ]] || die "Неизвестный --mode: $MODE (systemd|docker)"

# В dry-run не пишем файлы и не трогаем сервисы/контейнеры
run() { if [[ "$DRY_RUN" -eq 1 ]]; then info "[dry-run] $*"; else eval "$@"; fi; }

[[ "$(id -u)" -eq 0 ]] || die "Запускай от root: sudo bash $0"
[[ "${BASH_VERSINFO:-0}" -ge 4 ]] || die "Нужен bash 4+ (у тебя ${BASH_VERSION})"

ENV_FILE="/root/.hermes/workspace_env.conf"
CADDY_FILE="/etc/caddy/Caddyfile"

# ---------------------------------------------------------------------------
# 1. Зависимости
# ---------------------------------------------------------------------------
step "Проверка зависимостей"
need() { command -v "$1" >/dev/null 2>&1 || die "Не найдено: $1"; }
need curl; need git; need python3

if ! command -v node >/dev/null 2>&1; then
  die "Node.js не установлен. Поставь Node 22+ (напр. via NodeSource) и повтори."
fi
NODE_MAJOR=$(node -v | sed -E 's/v([0-9]+).*/\1/')
if [[ "$NODE_MAJOR" -lt 22 ]]; then
  die "Нужен Node.js 22+, сейчас v${NODE_MAJOR}. Обнови Node и повтори."
fi
ok "Node v$(node -v) ✓"
need npm
ok "npm $(npm -v) ✓"

if [[ "$MODE" == "docker" ]]; then
  need docker
  if ! docker compose version >/dev/null 2>&1; then
    die "Нужен 'docker compose' (v2). Поставь docker с compose-плагином."
  fi
  ok "docker $(docker --version) ✓"
fi

# ---------------------------------------------------------------------------
# 2. Hermes Agent
# ---------------------------------------------------------------------------
step "Hermes Agent"
if command -v hermes >/dev/null 2>&1 && hermes --version >/dev/null 2>&1; then
  ok "Hermes Agent уже установлен: $(hermes --version 2>/dev/null || echo present)"
else
  warn "Hermes Agent не найден. Ставлю …"
  if curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/install.sh -o /tmp/hermes-install.sh 2>/dev/null; then
    run bash /tmp/hermes-install.sh || true
  fi
  if ! command -v hermes >/dev/null 2>&1; then
    run "python3 -m venv /usr/local/lib/hermes-agent/venv"
    run "/usr/local/lib/hermes-agent/venv/bin/pip install -U pip"
    run "/usr/local/lib/hermes-agent/venv/bin/pip install hermes-agent"
    run "ln -sf /usr/local/lib/hermes-agent/venv/bin/hermes /usr/local/bin/hermes"
  fi
  command -v hermes >/dev/null 2>&1 || die "Не удалось установить Hermes Agent."
  ok "Hermes Agent установлен"
fi

# ---------------------------------------------------------------------------
# 3. Gateway + Dashboard
# ---------------------------------------------------------------------------
if [[ "$MODE" == "systemd" ]]; then
  step "Gateway + Dashboard (systemd)"
  # Gateway — родной systemd-юнит от Hermes
  if systemctl list-unit-files 2>/dev/null | grep -q "hermes-gateway.service"; then
    warn "hermes-gateway.service уже есть — пропускаю install (restart при финале)."
  else
    run "hermes gateway install" || warn "hermes gateway install не сработал — см. hermes gateway --help"
  fi
  # Dashboard — пишем unit вручную (hermes не делает install для dashboard)
  DASH_UNIT="/etc/systemd/system/hermes-dashboard.service"
  if [[ -f "$DASH_UNIT" && "$DRY_RUN" -eq 0 ]]; then
    warn "$DASH_UNIT уже существует — не перезаписываю."
  elif [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] пропускаю запись $DASH_UNIT"
  else
    info "Устанавливаю $DASH_UNIT …"
    cat > "$DASH_UNIT" <<'EOF'
[Unit]
Description=Hermes Dashboard
After=network-online.target hermes-gateway.service
Wants=hermes-gateway.service

[Service]
Type=simple
User=root
Environment="HOME=/root"
EnvironmentFile=/root/.hermes/dashboard_auth_env.conf
ExecStart=/usr/local/bin/hermes dashboard --host 0.0.0.0 --port 9119 --no-open --tui
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
    sleep 4
    curl -fsS --max-time 5 http://127.0.0.1:8642/health >/dev/null 2>&1 && ok "Gateway :8642 ✅" || warn "Gateway :8642 не отвечает"
    curl -fsS --max-time 5 http://127.0.0.1:9119/  >/dev/null 2>&1 && ok "Dashboard :9119 ✅" || warn "Dashboard :9119 не отвечает"
  fi
else
  step "Gateway + Dashboard (docker)"
  # Используем официальный образ; gateway и dashboard в одном контейнере.
  run "docker pull nousresearch/hermes-agent:latest"
  ok "Образ hermes-agent получен (будет запущен через compose на финале)"
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
  if [[ -z "$val" && -n "$cur" ]]; then val="$cur"; fi
  printf '%s=%s\n' "$key" "$val"
}

cur_token=$(grep -E '^HERMES_API_TOKEN='  "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
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
  step "systemd unit hermes-workspace.service"
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
Environment="PORT=3001"
Environment="HOST=0.0.0.0"
Environment="COOKIE_SECURE=1"
Environment="HERMES_HOME=/root/.hermes"
Environment="HERMES_API_URL=http://127.0.0.1:8642"
Environment="HERMES_DASHBOARD_URL=http://127.0.0.1:9119"
EnvironmentFile=$ENV_FILE
ExecStartPre=/bin/bash -c "for i in \$(seq 1 30); do /usr/bin/curl -sf http://127.0.0.1:8642/health >/dev/null 2>&1 && break; sleep 1; done" || true
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
      curl -fsS --max-time 3 "http://127.0.0.1:3001/" >/dev/null 2>&1 && up=1 && break
      sleep 1
    done
    [[ "$up" -eq 1 ]] && ok "Workspace :3001 ✅" || err "Workspace не поднялся за 30с (journalctl -u hermes-workspace -n 50)"
  else
    info "[dry-run] пропускаю проверку :3001"
  fi
else
  step "Workspace (docker build + compose)"
  run "docker build -t hermes-workspace:local ."
  ok "Образ hermes-workspace:local собран (запустится через compose)"
fi

# ---------------------------------------------------------------------------
# 8. Caddy (reverse proxy + HTTPS)
# ---------------------------------------------------------------------------
step "Caddy (reverse proxy, HTTPS)"
if [[ -z "$DOMAIN" ]]; then
  warn "Домен не задан (--domain). Caddy будет слушать на IP без авто-TLS."
  DOMAIN=":3001"   # fallthrough: Caddy отдаёт workspace напрямую по IP
fi

if [[ "$MODE" == "systemd" ]]; then
  # Ставим caddy системно (официальный репо)
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
    if [[ "$DOMAIN" == ":3001" ]]; then
      cat > "$CADDY_FILE" <<EOF
# Без домена: отдаём workspace напрямую по IP (HTTP, без TLS)
:80 {
    reverse_proxy 127.0.0.1:3001
}
EOF
    else
      cat > "$CADDY_FILE" <<EOF
# Авто-TLS через Let's Encrypt. Замени DOMAIN на свой.
$DOMAIN {
    reverse_proxy 127.0.0.1:3001
}

# Опционально: дашборд и гейтвей под отдельными субдоменами
# dashboard.$DOMAIN {
#     reverse_proxy 127.0.0.1:9119
# }
# gateway.$DOMAIN {
#     reverse_proxy 127.0.0.1:8642
# }
EOF
    fi
    ok "Caddyfile записан"
  fi
  run systemctl daemon-reload
  run systemctl enable caddy
  run systemctl restart caddy
  if [[ "$DRY_RUN" -eq 0 && "$DOMAIN" != ":3001" ]]; then
    sleep 3
    curl -fsS --max-time 5 "https://$DOMAIN/" >/dev/null 2>&1 && ok "Caddy $DOMAIN (HTTPS) ✅" || warn "Caddy $DOMAIN не отвечает (проверь DNS + открытый 80/443)"
  fi
else
  # docker-режим: caddy тоже в контейнере (через compose)
  info "Caddy будет запущен как контейнер через docker compose."
fi

# ---------------------------------------------------------------------------
# 9. docker-режим: собираем compose и поднимаем
# ---------------------------------------------------------------------------
if [[ "$MODE" == "docker" ]]; then
  step "docker compose up"
  COMPOSE="$WS_DIR/docker-compose.yml"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "[dry-run] пропускаю docker compose up (файл: $COMPOSE)"
  else
    if [[ ! -f "$COMPOSE" ]]; then
      # Генерируем минимальный compose, если нет в репо
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
      - PORT=3001
      - HOST=0.0.0.0
      - HERMES_API_URL=http://hermes:8642
      - HERMES_DASHBOARD_URL=http://hermes:9119
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
    # Caddyfile для docker-режима
    if [[ -z "$DOMAIN" || "$DOMAIN" == ":3001" ]]; then
      cat > "$WS_DIR/Caddyfile.docker" <<'EOF'
:80 {
    reverse_proxy workspace:3001
}
EOF
    else
      cat > "$WS_DIR/Caddyfile.docker" <<EOF
$DOMAIN {
    reverse_proxy workspace:3001
}
EOF
    fi
    run "docker compose -f $COMPOSE up -d"
    ok "Контейнеры подняты (hermes / workspace / caddy)"
  fi
fi

# ---------------------------------------------------------------------------
# Финал
# ---------------------------------------------------------------------------
echo
echo "${C_GRN}${C_BLD}Готово!${C_RST} (режим: $MODE)"
if [[ "$MODE" == "systemd" ]]; then
  if [[ "$DOMAIN" == ":3001" ]]; then
    echo "  Workspace : http://127.0.0.1:3001/  (без домена; задать --domain для HTTPS)"
  else
    echo "  Workspace : https://$DOMAIN/"
  fi
  echo "  Gateway   : http://127.0.0.1:8642/health"
  echo "  Dashboard : http://127.0.0.1:9119/"
  echo "  Журналы   : journalctl -u hermes-workspace -f"
else
  if [[ "$DOMAIN" == ":3001" ]]; then
    echo "  Workspace : http://<IP-сервера>:3001/  (контейнер hermes-workspace; задать --domain для HTTPS)"
  else
    echo "  Workspace : https://$DOMAIN/ (контейнер hermes-workspace)"
  fi
  echo "  Журналы   : docker compose -f $WS_DIR/docker-compose.yml logs -f"
fi
echo
echo "Если задан --domain, убедись, что DNS указывает на этот сервер и"
echo "порты 80/443 открыты — Caddy сам выпустит TLS-сертификат Let's Encrypt."
