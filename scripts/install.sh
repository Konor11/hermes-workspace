#!/usr/bin/env bash
#
# Hermes Workspace — автоустановка на чистый сервер (Ubuntu/Debian).
#
# Что делает:
#   1. Проверяет зависимости (bash4+, curl, node 22+, npm, python3, git).
#   2. Ставит Hermes Agent (если ещё не установлен) системно.
#   3. Клонирует форк hermes-workspace (или использует текущую папку).
#   4. npm install + npm run build.
#   5. Генерирует /root/.hermes/workspace_env.conf (секреты интерактивно).
#   6. Устанавливает systemd unit hermes-workspace.service.
#   7. Запускает и проверяет доступность.
#
# Требования: запуск от root (нужны systemd + запись в /root/.hermes).
# Использование:
#   sudo bash scripts/install.sh
#   sudo bash scripts/install.sh --dir /opt/hermes-workspace --no-build
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)   WS_DIR="$2"; shift 2 ;;
    --repo)  REPO_URL="$2"; shift 2 ;;
    --ref)   GIT_REF="$2"; shift 2 ;;
    --no-build) DO_BUILD=0; shift ;;
    --update)   UPDATE=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

# В dry-run не пишем файлы и не трогаем systemd/сервисы
run() { if [[ "$DRY_RUN" -eq 1 ]]; then info "[dry-run] $*"; else eval "$@"; fi; }
run_quiet() { if [[ "$DRY_RUN" -eq 1 ]]; then info "[dry-run] $*"; else eval "$@"; fi; }

[[ "$(id -u)" -eq 0 ]] || die "Запускай от root: sudo bash $0"
[[ "${BASH_VERSINFO:-0}" -ge 4 ]] || die "Нужен bash 4+ (у тебя ${BASH_VERSION})"

ENV_FILE="/root/.hermes/workspace_env.conf"

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

if ! command -v npm >/dev/null 2>&1; then
  die "npm не найден (идёт с Node). Переустанови Node 22+."
fi
ok "npm $(npm -v) ✓"

# ---------------------------------------------------------------------------
# 2. Hermes Agent
# ---------------------------------------------------------------------------
step "Hermes Agent"
if command -v hermes >/dev/null 2>&1 && hermes --version >/dev/null 2>&1; then
  ok "Hermes Agent уже установлен: $(hermes --version 2>/dev/null || echo present)"
else
  warn "Hermes Agent не найден. Ставлю через pipx/uv/pip в venv /usr/local/lib/hermes-agent …"
  # Приоритет установщика — официальный one-liner; если недоступен — pip.
  if curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/install.sh -o /tmp/hermes-install.sh 2>/dev/null; then
    bash /tmp/hermes-install.sh || true
  fi
  if ! command -v hermes >/dev/null 2>&1; then
    python3 -m venv /usr/local/lib/hermes-agent/venv
    /usr/local/lib/hermes-agent/venv/bin/pip install -U pip
    /usr/local/lib/hermes-agent/venv/bin/pip install hermes-agent
    ln -sf /usr/local/lib/hermes-agent/venv/bin/hermes /usr/local/bin/hermes
  fi
  command -v hermes >/dev/null 2>&1 || die "Не удалось установить Hermes Agent."
  ok "Hermes Agent установлен: $(hermes --version 2>/dev/null || echo present)"
fi

# Убедимся, что gateway/dashboard могут стартовать (systemd-юниты ставит сам hermes при first-run)
if ! systemctl list-unit-files 2>/dev/null | grep -q "hermes-gateway.service"; then
  warn "Юнит hermes-gateway.service не найден. Включи автозапуск: hermes gateway enable (или см. доку Hermes)."
fi

# ---------------------------------------------------------------------------
# 3. Клон / обновление репозитория
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

if [[ "$DRY_RUN" -eq 0 ]]; then
  cd "$WS_DIR"
fi

# ---------------------------------------------------------------------------
# 4. Сборка
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
# 5. Секреты (workspace_env.conf)
# ---------------------------------------------------------------------------
step "Конфигурация /root/.hermes/workspace_env.conf"
mkdir -p /root/.hermes

prompt_secret() {
  # $1=ключ $2=подсказка $3=текущее_значение(опц)
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

# Считываем текущие значения, если файл есть
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
# 6. systemd unit
# ---------------------------------------------------------------------------
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
After=network-online.target hermes-gateway.service
Wants=hermes-gateway.service

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
ok "Unit включён (автозапуск при загрузке)"

# ---------------------------------------------------------------------------
# 7. Запуск + проверка
# ---------------------------------------------------------------------------
step "Запуск и проверка"
run systemctl restart hermes-workspace.service
# Ждём поднятия (до 30с)
if [[ "$DRY_RUN" -eq 1 ]]; then
  info "[dry-run] пропускаю ожидание/проверку порта"
else
  up=0
  for i in $(seq 1 30); do
    if curl -fsS --max-time 3 "http://127.0.0.1:3001/" >/dev/null 2>&1; then up=1; break; fi
    sleep 1
  done
  if [[ "$up" -eq 1 ]]; then
    ok "Workspace отвечает на http://127.0.0.1:3001/ ✅"
  else
    err "Workspace не поднялся за 30с. Смотри: journalctl -u hermes-workspace -n 50"
    exit 1
  fi
fi

echo
echo "${C_GRN}${C_BLD}Готово!${C_RST}"
echo "  Workspace : http://127.0.0.1:3001/"
echo "  Gateway   : http://127.0.0.1:8642/health"
echo "  Dashboard : http://127.0.0.1:9119/"
echo
echo "Для доступа извне поставь reverse-proxy (caddy/nginx) на :3001 / :9119 / :8642."
echo "Журнал: ${C_BLD}journalctl -u hermes-workspace -f${C_RST}"
