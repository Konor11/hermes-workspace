#!/usr/bin/env bash
#
# Hermes Workspace — интерактивная установка на чистый сервер (Ubuntu/Debian).
#
# Запуск без аргументов — скрипт сам задаст понятные вопросы (TUI):
#   режим рантайма (systemd / docker), домен workspace, отдельный домен
#   для dashboard, и секреты (пароли/токены). Enter принимает значение по
#   умолчанию. Можно также передать флаги для неинтерактивного режима.
#
# Порты: workspace ищет свободный 3000→3001→… ; gateway 8642 / dashboard 9119
# проверяются и при необходимости сдвигаются автоматически.
#
# Использование:
#   sudo bash scripts/install.sh
#   sudo bash scripts/install.sh --domain ws.mydomen.com --mode docker
#   sudo bash scripts/install.sh --dry-run
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Цветной вывод
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YEL=$'\033[0;33m'
  C_BLU=$'\033[0;34m'; C_RST=$'\033[0m'; C_BLD=$'\033[1m'; C_CYN=$'\033[0;36m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_RST=''; C_BLD=''; C_CYN=''
fi

info()  { echo "${C_BLU}ℹ${C_RST} $*"; }
ok()    { echo "${C_GRN}✓${C_RST} $*"; }
warn()  { echo "${C_YEL}⚠${C_RST} $*"; }
err()   { echo "${C_RED}✗${C_RST} $*" >&2; }
die()   { err "$*"; exit 1; }
step()  { echo; echo "${C_BLD}${C_BLU}==>${C_RST} $*"; }

# ---------------------------------------------------------------------------
# Системные зависимости (build-tools, Node 22, Caddy) — ставит всё само
# ---------------------------------------------------------------------------
# Полный набор системных зависимостей:
#  - сборка hermes-agent (pip) и workspace (node-gyp): gcc/g++/make, заголовки python/openssl;
#  - базовые утилиты: curl, git, ca-certificates, gnupg, lsb-release, systemd, sqlite;
#  - Node.js 22+ (через NodeSource, если нет в системе);
#  - Caddy (только для systemd-режима, для reverse-proxy + авто-TLS).
ensure_build_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    info "Ставлю системные зависимости (apt) …"
    run "apt-get update -y"
    run "DEBIAN_FRONTEND=noninteractive apt-get install -y \
      build-essential python3-dev python3-venv python3-pip \
      libssl-dev libffi-dev libsqlite3-dev \
      curl git ca-certificates gnupg lsb-release systemd \
      software-properties-common unzip"
    # Node.js 22+ (если нет или старее 22)
    if ! command -v node >/dev/null 2>&1 || [[ "$(node -v 2>/dev/null | sed -E 's/v([0-9]+).*/\1/')" -lt 22 ]]; then
      info "Ставлю Node.js 22 (NodeSource) …"
      run "curl -fsSL https://deb.nodesource.com/setup_22.x | bash -"
      run "DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs"
    fi
    # Caddy (systemd-режим)
    if [[ "$MODE" == "systemd" ]] && ! command -v caddy >/dev/null 2>&1; then
      info "Ставлю Caddy (apt) …"
      run "install -m 0755 -d /etc/apt/keyrings"
      run "curl -fsSL https://dl.cloudflare.com/apt/caddy.key | gpg --dearmor -o /etc/apt/keyrings/caddy.gpg 2>/dev/null || true"
      if [[ -f /etc/apt/keyrings/caddy.gpg ]]; then
        run "echo \"deb [signed-by=/etc/apt/keyrings/caddy.gpg] https://dl.cloudflare.com/apt/caddy stable main\" > /etc/apt/sources.list.d/caddy.list"
        run "apt-get update -y"
        run "DEBIAN_FRONTEND=noninteractive apt-get install -y caddy"
      else
        warn "Не удалось добавить репу Caddy — пропускаю (reverse-proxy настроишь вручную)."
      fi
    fi
  elif command -v dnf >/dev/null 2>&1; then
    info "Ставлю системные зависимости (dnf) …"
    run "dnf -y install gcc gcc-c++ make python3-devel openssl-devel \
      libffi-devel sqlite-devel curl git systemd"
    if ! command -v node >/dev/null 2>&1 || [[ "$(node -v 2>/dev/null | sed -E 's/v([0-9]+).*/\1/')" -lt 22 ]]; then
      info "Ставлю Node.js 22 (NodeSource) …"
      run "curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -"
      run "dnf -y install nodejs"
    fi
    if [[ "$MODE" == "systemd" ]] && ! command -v caddy >/dev/null 2>&1; then
      info "Ставлю Caddy (dnf) …"
      run "dnf -y install 'dnf-command(copr)' && dnf -y copr enable @caddy/caddy && dnf -y install caddy" || warn "Caddy не установлен — настрой reverse-proxy вручную."
    fi
  elif command -v apk >/dev/null 2>&1; then
    info "Ставлю системные зависимости (apk) …"
    run "apk add --no-cache build-base python3-dev openssl-dev libffi-dev \
      sqlite-dev curl git gcompat"
    if ! command -v node >/dev/null 2>&1; then
      run "apk add --no-cache nodejs npm"
    fi
    if [[ "$MODE" == "systemd" ]] && ! command -v caddy >/dev/null 2>&1; then
      run "apk add --no-cache caddy" || warn "Caddy не установлен — настрой reverse-proxy вручную."
    fi
  else
    warn "Неизвестный пакетный менеджер — пропускаю установку системных зависимостей."
    warn "Убедись, что установлены: gcc, g++, make, python3-dev, libssl-dev, Node.js 22+."
  fi
}

# ---------------------------------------------------------------------------
# Параметры (с дефолтами; перекрываются TUI или флагами)
# ---------------------------------------------------------------------------
WS_DIR="/root/hermes-workspace"
REPO_URL="https://github.com/Konor11/hermes-workspace.git"
GIT_REF="main"
DO_BUILD=1
UPDATE=0
DRY_RUN=0
MODE=""
TARGET=""   # local | vps
UFW_ENABLE=0
DOMAIN=""
DASH_DOMAIN=""
GW_DOMAIN=""
NONINTERACTIVE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)               WS_DIR="$2"; shift 2 ;;
    --repo)              REPO_URL="$2"; shift 2 ;;
    --ref)               GIT_REF="$2"; shift 2 ;;
    --mode)              MODE="$2"; shift 2 ;;
    --target)            TARGET="$2"; shift 2 ;;
    --ufw)               UFW_ENABLE=1; TARGET="vps"; shift ;;
    --domain)            DOMAIN="$2"; shift 2 ;;
    --dashboard-domain)  DASH_DOMAIN="$2"; shift 2 ;;
    --gateway-domain)    GW_DOMAIN="$2"; shift 2 ;;
    --no-build)          DO_BUILD=0; shift ;;
    --update)            UPDATE=1; shift ;;
    --dry-run)           DRY_RUN=1; shift ;;
    --yes|-y)            NONINTERACTIVE=1; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Неизвестный аргумент: $1" ;;
  esac
done

run() { if [[ "$DRY_RUN" -eq 1 ]]; then info "[dry-run] $*"; else eval "$@"; fi; }
[[ "$(id -u)" -eq 0 ]] || die "Запускай от root: sudo bash $0"
[[ "${BASH_VERSINFO:-0}" -ge 4 ]] || die "Нужен bash 4+ (у тебя ${BASH_VERSION})"

# ---------------------------------------------------------------------------
# TUI-помощники
# ---------------------------------------------------------------------------
# ask_choice <вопрос> <дефолт> <вариант1> [вариант2] ...  -> пишет ответ в $REPLY
ask_choice() {
  local q="$1"; local def="${2:-}"; shift 2; local opts=("$@")
  local n=${#opts[@]}
  echo "${C_BLD}${C_CYN}$q${C_RST}"
  local i
  for i in "${!opts[@]}"; do
    printf "  %d) %s%s\n" "$((i+1))" "${opts[$i]}" "$([[ "$def" == "${opts[$i]}" ]] && echo " ${C_GRN}(по умолчанию)${C_RST}")"
  done
  local ans=""
  if [[ -t 0 ]]; then
    read -r -p "  Выбор [1-$n${def:+, $def}]: " ans
  else
    read -r ans || true   # читаем из stdin (пайп/автотест); EOF не должен убивать скрипт
  fi
  if [[ -z "$ans" && -n "$def" ]]; then REPLY="$def"
  elif [[ "$ans" =~ ^[0-9]+$ ]] && (( ans>=1 && ans<=n )); then
    REPLY="${opts[$((ans-1))]}"
  else
    # совпал ли ввод с одним из вариантов (строкой) — принимаем, иначе дефолт/первый
    REPLY="$def"
    local j
    for j in "${!opts[@]}"; do
      [[ "$ans" == "${opts[$j]}" ]] && { REPLY="${opts[$j]}"; break; }
    done
  fi
  return 0
}

# ask_text <вопрос> <дефолт>  -> $REPLY
ask_text() {
  local q="$1"; local def="${2:-}"
  local hint=""; [[ -n "$def" ]] && hint="${C_YEL} [${def}]${C_RST}"
  read -r -p "  $q$hint: " REPLY || REPLY=""
  [[ -z "$REPLY" ]] && REPLY="$def"
  return 0
}

# ---------------------------------------------------------------------------
# TUI-опрос (только если не заданы флагами / не --yes)
# ---------------------------------------------------------------------------
tui_configure() {
  clear 2>/dev/null || true
  echo "${C_BLD}${C_GRN}╔════════════════════════════════════════════════════════════╗${C_RST}"
  echo "${C_BLD}${C_GRN}║        Установка Hermes Workspace — мастер настройки        ║${C_RST}"
  echo "${C_BLD}${C_GRN}╚════════════════════════════════════════════════════════════╝${C_RST}"
  echo

  [[ -z "$TARGET" ]] && { ask_choice "Куда устанавливаем?" "vps" "vps" "local"; TARGET="$REPLY"; }
  [[ -z "$MODE" ]] && { ask_choice "Режим рантайма:" "systemd" "systemd" "docker"; MODE="$REPLY"; }

  if [[ "$TARGET" == "vps" ]]; then
    [[ -z "$DOMAIN" ]] && {
      ask_text "Домен для Workspace (напр. ws.mydomen.com, пусто — доступ по IP:3000)" ""; DOMAIN="$REPLY"
    }
    if [[ -z "$DASH_DOMAIN" ]]; then
      ask_choice "Отдельный домен для Dashboard (напр. dash.mydomen.com)?" "нет" "нет" "да"; local d="$REPLY"
      if [[ "$d" == "да" ]]; then
        ask_text "Домен dashboard (напр. dash.mydomen.com)" ""; DASH_DOMAIN="$REPLY"
      fi
    fi
    if [[ $UFW_ENABLE -eq 0 ]]; then
      ask_choice "Настроить firewall (ufw): открыть 22/80/443, закрыть остальные?" "да" "да" "нет"
      UFW_ENABLE=$([[ "$REPLY" == "да" ]] && echo 1 || echo 0)
    fi
  else
    DOMAIN=""; DASH_DOMAIN=""
    info "Локальная установка: домены не используются, доступ по http://localhost:${WS_PORT:-3000}"
  fi

  echo
  ok "Конфигурация принята: target=$TARGET, режим=$MODE, domain=${DOMAIN:-<нет>}, dashboard=${DASH_DOMAIN:-<нет>}, ufw=$([[ $UFW_ENABLE -eq 1 ]] && echo да || echo нет)"
}

# Запуск TUI, если не все ключевые параметры заданы флагами и не --yes
if [[ "$NONINTERACTIVE" -eq 0 && ( -z "$MODE" || -z "$DOMAIN" && -z "$DASH_DOMAIN" ) ]]; then
  tui_configure
fi
[[ -n "$MODE" ]] || MODE="systemd"   # fallback если вообще ничего не задано

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
# Ставим ВСЕ системные зависимости сразу (build-tools, Node 22, Caddy и т.д.)
ensure_build_deps

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
  # ensure_build_deps уже вызван в блоке 1 (ставит gcc/g++/make/python-dev, Node 22, Caddy).
  # Официальный инсталлятор (https://hermes-agent.nousresearch.com/install.sh).
  # НЕ пайпим в bash и НЕ даём </dev/null — инсталлятор бывает интерактивным и
  # падает в pipe (curl: (23) Failure writing output to destination на мобильном
  # терминале). Качаем во временный файл, проверяем запись, затем запускаем.
  INSTALLER_TMP="$(mktemp -t hermes-install.XXXXXX.sh 2>/dev/null || echo /tmp/hermes-install.sh)"
  DONE_MARK=/tmp/hermes-install.done
  rm -f "$DONE_MARK"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    if curl -fsSL --retry 3 --retry-delay 2 "https://hermes-agent.nousresearch.com/install.sh" -o "$INSTALLER_TMP" 2>/tmp/hermes-curl.err; then
      ok "Инсталлятор скачан ($(wc -c < "$INSTALLER_TMP" 2>/dev/null || echo ?) байт)"
      # Запускаем ВНЕ нашей SSH-сессии (setsid), чтобы systemctl --user
      # инсталлятора не обрывал наш SSH. Но setsid отвязывает controlling
      # terminal — поэтому оборачиваем инсталлятор в `script` НА ВЕРХНЕМ
      # уровне: script сам вызывает TIOCSCTTY на псевдо-tty (pty) и делает
      # его controlling terminal для инсталлятора. В результате hermes видит
      # терминал и запускает интерактивный мастер (запрашивает пароли/токены).
      # Промпты идут на наш терминал: пользователь их видит и отвечает.
      # Скрипт СТОИТ, пока инсталлятор не завершится (он интерактивный).
      if command -v script >/dev/null 2>&1; then
        setsid -f script -qec "bash $INSTALLER_TMP" /dev/null < /dev/tty > /dev/tty 2>&1
      else
        # Нет script — запускаем напрямую вне сессии. TTY может отсутствовать,
        # тогда мастер пропустится; страховка ниже добавит `hermes setup`.
        setsid -f bash "$INSTALLER_TMP" < /dev/tty > /dev/tty 2>&1
      fi
      ok "Инсталлятор hermes запущен — отвечай на его вопросы в терминале…"
      # Ждём завершения инсталлятора (маркер пишем сами после выхода из setsid).
      for _ in $(seq 1 600); do
        # Если hermes появился в PATH и процесс инсталлятора неактивен — стоп.
        if command -v hermes >/dev/null 2>&1; then
          if ! pgrep -f "hermes-install" >/dev/null 2>&1 && \
             ! pgrep -f "install.sh" >/dev/null 2>&1; then
            break
          fi
        fi
        sleep 3
      done
      ok "Этап инсталлятора hermes пройден"
      # Страховка: если мастер всё же пропущен (нет конфига), запускаем
      # `hermes setup` интерактивно ПРЯМО ЗДЕСЬ (в нашей сессии, с терминалом),
      # чтобы пользователь мог ввести пароли/токены.
      if ! [[ -f /root/.hermes/.env ]] && command -v hermes >/dev/null 2>&1; then
        warn "Конфиг hermes не найден (~/.hermes/.env) — запускаю 'hermes setup' интерактивно…"
        if command -v script >/dev/null 2>&1; then
          script -qec "hermes setup" /dev/null < /dev/tty > /dev/tty 2>&1
        else
          hermes setup < /dev/tty > /dev/tty 2>&1
        fi
      fi
    else
      warn "Не удалось скачать инсталлятор: $(cat /tmp/hermes-curl.err 2>/dev/null | head -1)"
    fi
    rm -f "$INSTALLER_TMP" 2>/dev/null || true
  fi
  hash -r 2>/dev/null || true
  # Убедимся, что 'hermes' доступен. Ищем в типичных местах + широкий find.
  if ! command -v hermes >/dev/null 2>&1; then
    warn "hermes не в PATH после инсталлятора — ищу бинарь …"
    found=""
    for p in /usr/local/bin/hermes /root/.local/bin/hermes /usr/bin/hermes /opt/hermes/bin/hermes /root/bin/hermes; do
      [[ -x "$p" ]] && { found="$p"; break; }
    done
    if [[ -z "$found" ]]; then
      found=$(find /usr/local /opt /root/.local -maxdepth 4 -name hermes -type f 2>/dev/null | head -1)
    fi
    if [[ -n "$found" ]]; then
      ln -sf "$found" /usr/local/bin/hermes
      ok "Симлинк hermes → $found"
    fi
  fi
  hash -r 2>/dev/null || true
  if ! command -v hermes >/dev/null 2>&1; then
    warn "Официальный инсталлятор не добавил hermes в PATH — пробую pip fallback"
    run "python3 -m venv /usr/local/lib/hermes-agent/venv"
    run "/usr/local/lib/hermes-agent/venv/bin/pip install -U pip"
    run "/usr/local/lib/hermes-agent/venv/bin/pip install hermes-agent"
    run "ln -sf /usr/local/lib/hermes-agent/venv/bin/hermes /usr/local/bin/hermes"
    hash -r 2>/dev/null || true
  fi
  command -v hermes >/dev/null 2>&1 || die "Не удалось установить Hermes Agent. Проверь 'which hermes' и /root/.local/bin в PATH."
  ok "Hermes Agent $(hermes --version 2>/dev/null || echo установлен)"
fi

# ---------------------------------------------------------------------------
# 3. Gateway + Dashboard
# ---------------------------------------------------------------------------
# Блок 3 выполняется БЕЗ set -e: некоторые команды (hermes config, systemctl
# enable при уже-существующем юните) могут вернуть не-0 и молча убить скрипт
# под set -uo pipefail. Ловим ошибки явно, продолжаем установку.
set +e
if [[ "$MODE" == "systemd" ]]; then
  step "Gateway + Dashboard (systemd)"

  # hermes gateway/dashboard install на чистом сервере сам создаёт user-unit
  # (~/.config/systemd/user/hermes-*.service) при ответе "Да" на вопрос
  # "install systemd?" (напр. при подключении Telegram). ПРОБЛЕМА: этот
  # user-unit стартует в scope текущей SSH-сессии и при реконфигурации
  # systemd РВЁТ SSH-подключение. Поэтому МЫ ЕГО ЗАБИРАЕМ:
  #   останавливаем user-unit hermes, ставим свой system-unit (живёт вне SSH,
  #   не рвёт сессию) и запускаем его. Gateway стартует нормально, SSH — цел.
  USER_GW_UNIT="/root/.config/systemd/user/hermes-gateway.service"
  USER_DASH_UNIT="/root/.config/systemd/user/hermes-dashboard.service"
  SKIP_SYSTEM_GATEWAY=0
  SKIP_SYSTEM_DASHBOARD=0
  # Инсталлятор hermes запущен в фоне (setsid) — user-unit появляется не сразу.
  # Ждём его до 40с, чтобы перехват сработал даже при медленном старте.
  for _ in $(seq 1 40); do
    [[ -f "$USER_GW_UNIT" || -f "$USER_DASH_UNIT" ]] && break
    sleep 1
  done
  if [[ -f "$USER_GW_UNIT" || -f "$USER_DASH_UNIT" ]]; then
    ok "Обнаружен user-unit hermes (отвечали 'Да' на systemd) — перехватываю под systemd, чтобы не рвало SSH"
    # Лингер: чтобы systemd --user сервисы жили вне сессии (страховка)
    loginctl enable-linger root 2>/dev/null || true
    # Останавливаем и отключаем user-unit hermes (он рвёт SSH при рестарте)
    systemctl --user disable --now hermes-gateway.service 2>/dev/null || true
    systemctl --user disable --now hermes-dashboard.service 2>/dev/null || true
    # Удаляем user-unit-файлы, чтобы hermes не переподнял их
    rm -f "$USER_GW_UNIT" "$USER_DASH_UNIT"
    systemctl --user daemon-reload 2>/dev/null || true
    # SKIP остаётся 0 → ниже создадим и запустим свой system-unit
  fi
  GW_UNIT="/etc/systemd/system/hermes-gateway.service"
  DASH_UNIT="/etc/systemd/system/hermes-dashboard.service"

  # /root/.hermes/.env — нужен gateway для запуска API-сервера (API_SERVER_KEY).
  # Генерим ключ один раз и переиспользуем для workspace (HERMES_API_TOKEN),
  # чтобы пользователю не приходилось вводить его вручную.
  HERMES_ENV="/root/.hermes/.env"
  GEN_KEY=""
  if [[ "$DRY_RUN" -eq 0 ]]; then
    mkdir -p /root/.hermes
    # если в существующем .env уже есть API_SERVER_KEY — берём его
    if [[ -f "$HERMES_ENV" ]]; then
      GEN_KEY=$(grep -E '^API_SERVER_KEY=' "$HERMES_ENV" | cut -d= -f2- | head -c 64)
    fi
    # иначе генерим новый и дописываем/создаём .env
    if [[ -z "$GEN_KEY" ]]; then
      GEN_KEY=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)
      if [[ -f "$HERMES_ENV" ]]; then
        # дописать недостающие ключи, не затирая существующие
        grep -q '^API_SERVER_ENABLED=' "$HERMES_ENV" || echo "API_SERVER_ENABLED=true" >> "$HERMES_ENV"
        grep -q '^API_SERVER_KEY=' "$HERMES_ENV"    || echo "API_SERVER_KEY=$GEN_KEY" >> "$HERMES_ENV"
        grep -q '^API_SERVER_HOST=' "$HERMES_ENV"   || echo "API_SERVER_HOST=0.0.0.0" >> "$HERMES_ENV"
        grep -q '^HOME=' "$HERMES_ENV"              || echo "HOME=/root" >> "$HERMES_ENV"
        # HERMES_HOME сюда НЕ пишем: значение в .env переопределяет home hermes
        # и создаёт петлю (.env начинает читаться из другого места). См. #petlya.
        ok ".env дополнен API_SERVER_KEY (переиспользуется для workspace)"
      else
        cat > "$HERMES_ENV" <<EOF
HOME=/root
API_SERVER_ENABLED=true
API_SERVER_KEY=$GEN_KEY
API_SERVER_HOST=0.0.0.0
EOF
        ok ".env gateway записан (API_SERVER_KEY сгенерирован)"
      fi
      chmod 600 "$HERMES_ENV"
    else
      ok "API_SERVER_KEY уже есть в .env — переиспользуется"
    fi

    # Базовый MCP-сервер filesystem в config.yaml, чтобы на hermes-agent
    # >=0.20.5 MCP сразу работал в Workspace (native /api/mcp убран, Workspace
    # читает mcp_servers из config.yaml через `hermes config`). GitHub/прочие
    # серверы НЕ добавляем автоматически — они требуют токенов, которые есть
    # не у всех; добавляй их в UI позже. Не перезаписываем, если mcp_servers
    # уже заданы пользователем.
    # ВАЖНО: `hermes config get/set` может быть интерактивным/зависать на чистом
    # сервере — оборачиваем в timeout и || true, чтобы не убить скрипт.
    if [[ "$DRY_RUN" -eq 0 ]]; then
      if ! timeout 20 hermes config get mcp_servers >/dev/null 2>&1; then
        timeout 20 hermes config set mcp_servers.filesystem.command npx >/dev/null 2>&1 || true
        timeout 20 hermes config set mcp_servers.filesystem.args '["-y","@modelcontextprotocol/server-filesystem","/root"]' >/dev/null 2>&1 || true
        timeout 20 hermes config set mcp_servers.filesystem.enabled true >/dev/null 2>&1 || true
        ok "Добавлен базовый MCP-сервер (filesystem) в config.yaml"
      else
        ok "mcp_servers уже заданы в config.yaml — оставляем как есть"
      fi
    fi

    # HERMES_DASHBOARD_PUBLIC_URL — без него дашборд отказывается биндиться на 0.0.0.0.
    # Берём домен дашборда, либо основной домен workspace; иначе не задаём (127.0.0.1).
    DASH_PUBLIC=""
    if [[ -n "$DASH_DOMAIN" ]]; then DASH_PUBLIC="https://$DASH_DOMAIN"
    elif [[ -n "$DOMAIN" ]]; then DASH_PUBLIC="https://$DOMAIN"; fi
    if [[ -n "$DASH_PUBLIC" ]]; then
      if grep -q '^HERMES_DASHBOARD_PUBLIC_URL=' "$HERMES_ENV"; then
        sed -i "s#^HERMES_DASHBOARD_PUBLIC_URL=.*#HERMES_DASHBOARD_PUBLIC_URL=$DASH_PUBLIC#" "$HERMES_ENV"
      else
        echo "HERMES_DASHBOARD_PUBLIC_URL=$DASH_PUBLIC" >> "$HERMES_ENV"
      fi
      DASH_BIND="0.0.0.0"
      ok "Dashboard: OAuth (PUBLIC_URL=$DASH_PUBLIC) + Basic Auth, bind 0.0.0.0 --public-bind"
    else
      DASH_BIND="0.0.0.0"
      ok "Dashboard: Basic Auth только, bind 0.0.0.0 (задай --dashboard-domain для OAuth)"
    fi
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
WorkingDirectory=/root
Environment="HOME=/root"
Environment="PATH=/usr/local/bin:/usr/local/lib/hermes-agent/venv/bin:/usr/bin:/bin"
EnvironmentFile=/root/.hermes/.env
ExecStart=/usr/local/bin/hermes gateway run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    ok "Gateway unit записан"
  fi

  if [[ "$SKIP_SYSTEM_DASHBOARD" == "1" ]]; then
    ok "dashboard system-unit пропущен (user-unit hermes активен)"
  elif [[ -f "$DASH_UNIT" && "$DRY_RUN" -eq 0 && "$UPDATE" -eq 0 ]]; then
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
WorkingDirectory=/root
Environment="HOME=/root"
Environment="PATH=/usr/local/bin:/usr/local/lib/hermes-agent/venv/bin:/usr/bin:/bin"
EnvironmentFile=-/root/.hermes/dashboard_auth_env.conf
ExecStart=/usr/local/bin/hermes dashboard --host ${DASH_BIND:-127.0.0.1} --port $DASH_PORT --no-open --tui
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    ok "Dashboard unit записан"
  fi

  # daemon-reload / enable не должны убивать скрипт (set -e) — ловим ошибки.
  # setsid: отвязываем от SSH-сессии, чтобы реконфигурация systemd не оборвала SSH.
  setsid -f systemctl daemon-reload >/dev/null 2>&1 || warn "daemon-reload вернул ошибку (не критично)"
  if [[ "$SKIP_SYSTEM_GATEWAY" == "1" ]]; then
    ok "system-unit gateway skipped (user-unit active)"
  elif systemctl enable hermes-gateway.service 2>/dev/null; then
    ok "Gateway enabled"
  else
    warn "Gateway enable не удался — проверь юнит /etc/systemd/system/hermes-gateway.service"
  fi
  if [[ "$SKIP_SYSTEM_DASHBOARD" == "1" ]]; then
    ok "dashboard system-unit enable/restart пропущен (user-unit hermes управляет)"
  elif systemctl enable hermes-dashboard.service 2>/dev/null; then
    ok "Dashboard enabled"
  else
    warn "Dashboard enable не удался — проверь юнит /etc/systemd/system/hermes-dashboard.service"
  fi
  step "Запуск Gateway"
  if [[ "$SKIP_SYSTEM_GATEWAY" == "1" ]]; then
    ok "gateway restart skipped (user-unit manages it)"
  else
    # setsid: отвязываем restart от текущей SSH-сессии, чтобы systemd
    # реконфигурация/старт юнита не оборвал SSH-подключение скрипта.
    if setsid -f systemctl restart hermes-gateway.service >/dev/null 2>&1; then
      ok "Gateway запущен (systemd, вне SSH-сессии)"
    elif systemctl restart hermes-gateway.service 2>/dev/null; then
      ok "Gateway перезапущен"
    else
      warn "Gateway не стартует — диагностика:"
      journalctl -u hermes-gateway.service -n 30 --no-pager 2>/dev/null | sed 's/^/    /' || true
    fi
  fi
  step "Запуск Dashboard"
  if [[ "$SKIP_SYSTEM_DASHBOARD" == "1" ]]; then
    ok "dashboard restart skipped (user-unit manages it)"
  else
    if setsid -f systemctl restart hermes-dashboard.service >/dev/null 2>&1; then
      ok "Dashboard запущен (systemd, вне SSH-сессии)"
    elif systemctl restart hermes-dashboard.service 2>/dev/null; then
      ok "Dashboard перезапущен"
    else
      warn "Dashboard не стартует — диагностика:"
      journalctl -u hermes-dashboard.service -n 30 --no-pager 2>/dev/null | sed 's/^/    /' || true
    fi
  fi
  if [[ "$DRY_RUN" -eq 0 ]]; then
    sleep 8
    # Ждём запуска gateway/dashboard (retry до 20с), чтобы на медленном сервере
    # не было ложной ошибки "не отвечает".
    local up=0
    for _ in $(seq 1 20); do
      if curl -fsS --max-time 3 "http://127.0.0.1:$GW_PORT/health" >/dev/null 2>&1; then up=1; break; fi
      sleep 1
    done
    [[ "$up" -eq 1 ]] && ok "Gateway :$GW_PORT ✅" || warn "Gateway :$GW_PORT не отвечает — см. журнал выше"
    up=0
    for _ in $(seq 1 20); do
      if curl -fsS --max-time 3 "http://127.0.0.1:$DASH_PORT/" >/dev/null 2>&1; then up=1; break; fi
      sleep 1
    done
    [[ "$up" -eq 1 ]] && ok "Dashboard :$DASH_PORT ✅" || warn "Dashboard :$DASH_PORT не отвечает — см. журнал выше"
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
[[ "$DRY_RUN" -eq 0 ]] && { cd "$WS_DIR" || die "не удалось войти в $WS_DIR"; }

# ---------------------------------------------------------------------------
# 5. Сборка
# ---------------------------------------------------------------------------
if [[ "$DO_BUILD" -eq 1 && "$DRY_RUN" -eq 1 ]]; then
  info "[dry-run] пропускаю npm install + build"
elif [[ "$DO_BUILD" -eq 1 ]]; then
  step "npm install + build"
  info "npm install (это может занять несколько минут) …"
  if npm install 2>&1 | tail -5; then
    ok "npm install завершён"
  else
    warn "npm install вернул ошибку — продолжаем (возможно, warnings некритичны)"
  fi
  info "npm run build (NODE_OPTIONS=--max-old-space-size=3072) …"
  if NODE_OPTIONS="--max-old-space-size=3072" npm run build 2>&1 | tail -8; then
    ok "Сборка завершена"
  else
    warn "npm run build не удался — проверь 'npm run build' вручную в $WS_DIR"
  fi
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
  # Читаем из /dev/tty, чтобы приглашение и ввод работали ДАЖЕ когда функция
  # вызвана внутри конвейера { ... } | ... (иначе read берёт пустой stdin пайпа
  # и пользователь не видит строку ввода — баг "нет строк ввода логина/паролей").
  echo "  $key — $hint:"
  if [[ -c /dev/tty ]]; then
    read -r val < /dev/tty || true
  else
    read -r val || true
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
# Basic Auth дашборда: дефолт admin/admin (Enter — оставить), либо введи свои
: "${cur_bu:=admin}"; : "${cur_bp:=admin}"

echo "Введи параметры подключения к Hermes Gateway/Dashboard."
echo "(HERMES_API_TOKEN = API_SERVER_KEY гейтвея — подставляется автоматически; basic-auth — из dashboard_auth_env.conf)"
{
  # HERMES_API_TOKEN: не спрашиваем, если GEN_KEY сгенерирован (берём его),
  # чтобы пользователю не нужно было вводить ключ вручную.
  if [[ -n "${GEN_KEY:-}" ]]; then
    printf '%s=%s\n' "HERMES_API_TOKEN" "$GEN_KEY"

  else
    prompt_secret "HERMES_API_TOKEN" "Bearer-токен гейтвея (API_SERVER_KEY)" "$cur_token"
  fi
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

# HERMES_API_TOKEN obligatorisch: bez nego workspace slot pustoy Bearer.
if ! grep -qE '^HERMES_API_TOKEN=.+' "$ENV_FILE"; then
  GW_KEY=$(grep -E '^API_SERVER_KEY=' /root/.hermes/.env 2>/dev/null | cut -d= -f2- || true)
  if [[ -n "$GW_KEY" ]]; then
    if grep -qE '^HERMES_API_TOKEN=' "$ENV_FILE"; then
      sed -i "s|^HERMES_API_TOKEN=.*|HERMES_API_TOKEN=$GW_KEY|" "$ENV_FILE"
    else
      echo "HERMES_API_TOKEN=$GW_KEY" >> "$ENV_FILE"
    fi
    ok "HERMES_API_TOKEN = API_SERVER_KEY (auto)"
  else
    warn "API_SERVER_KEY not found in /root/.hermes/.env"
  fi
fi

# Workspace отказывается стартовать с HOST=0.0.0.0 без пароля (#122).
# Если пользователь оставил HERMES_PASSWORD пустым — генерируем надёжный.
if grep -qE '^HERMES_PASSWORD=$' "$ENV_FILE"; then
  GEN_PW=$(python3 -c "import secrets; print(secrets.token_urlsafe(12))")
  sed -i "s|^HERMES_PASSWORD=$|HERMES_PASSWORD=$GEN_PW|" "$ENV_FILE"
  ok "HERMES_PASSWORD сгенерирован: $GEN_PW"
fi
ok "Записано: $ENV_FILE (chmod 600)"

# Файл basic-auth для дашборда (читается unit'ом hermes-dashboard.service через
# EnvironmentFile). Если не создать — systemd считает отсутствующий файл фатальным.
DASH_AUTH="/root/.hermes/dashboard_auth_env.conf"
if [[ "$DRY_RUN" -eq 0 ]]; then
  # вытащим значения из только что записанного ENV_FILE
  bu=$(grep -E '^HERMES_DASHBOARD_BASIC_AUTH_USERNAME=' "$ENV_FILE" | cut -d= -f2-)
  bp=$(grep -E '^HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)
  : "${bu:=admin}"; : "${bp:=admin}"
  cat > "$DASH_AUTH" <<EOF
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=$bu
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=$bp
EOF
  chmod 600 "$DASH_AUTH"
  ok "Записано: $DASH_AUTH (basic-auth дашборда)"
fi

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
    # Путь к node: на чистом сервере NodeSource apt ставит в /usr/bin/node,
    # а не /usr/local/bin/node. Берём реальный путь, иначе 203/EXEC.
    NODE_BIN="$(command -v node || true)"
    [[ -z "$NODE_BIN" ]] && NODE_BIN="/usr/bin/node"
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
EnvironmentFile=-$ENV_FILE
ExecStartPre=/bin/bash -c "for i in \$(seq 1 30); do /usr/bin/curl -sf http://127.0.0.1:$GW_PORT/health >/dev/null 2>&1 && break; sleep 1; done" || true
ExecStart=$NODE_BIN server-entry.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    ok "Unit записан"
  fi
  systemctl daemon-reload 2>/dev/null || warn "daemon-reload вернул ошибку (не критично)"
  if systemctl enable hermes-workspace.service 2>/dev/null; then
    ok "Workspace enabled"
  else
    warn "Workspace enable не удался — проверь юнит /etc/systemd/system/hermes-workspace.service"
  fi
  if systemctl restart hermes-workspace.service 2>/dev/null; then
    ok "Workspace перезапущен"
  else
    warn "Workspace не стартует — диагностика: journalctl -u hermes-workspace.service -n 50"
  fi
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
  systemctl daemon-reload 2>/dev/null || warn "daemon-reload вернул ошибку (не критично)"
  if systemctl enable caddy 2>/dev/null; then
    ok "Caddy enabled"
  else
    warn "Caddy enable не удался"
  fi
  if systemctl restart caddy 2>/dev/null; then
    ok "Caddy перезапущен"
  else
    warn "Caddy не стартует — проверь Caddyfile и 'journalctl -u caddy -n 30'"
  fi
  if [[ "$DRY_RUN" -eq 0 && -n "$DOMAIN" ]]; then
    # Caddy только что перезапущен и должен ВЫПУСТИТЬ TLS-сертификат
    # Let's Encrypt (ACME HTTP-01 challenge на :80 — сетевой round-trip,
    # обычно 5–30с, иногда дольше). Сразу дёргать https бессмысленно — будет
    # ложная ошибка "не отвечает". Сначала проверяем DNS, потом retry HTTPS.
    SRV_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    DOMAIN_IP="$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1)"
    if [[ -n "$DOMAIN_IP" && -n "$SRV_IP" && "$DOMAIN_IP" != "$SRV_IP" ]]; then
      warn "DNS $DOMAIN → $DOMAIN_IP, но этот сервер $SRV_IP. Workspace заработает, когда DNS укажет на сервер."
    fi
    up=0
    for _ in $(seq 1 30); do
      if curl -fsS --max-time 5 "https://$DOMAIN/" >/dev/null 2>&1; then up=1; break; fi
      sleep 3
    done
    if [[ "$up" -eq 1 ]]; then
      ok "Caddy $DOMAIN (HTTPS) ✅"
    else
      warn "Caddy $DOMAIN не отвечает по HTTPS за 90с — проверь: DNS указывает на сервер? 80/443 открыты? 'journalctl -u caddy -n 30'. Workspace поднимется, когда Caddy выпустит сертификат."
    fi
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
# ---------------------------------------------------------------------------
# Firewall (ufw) — только для VPS
# ---------------------------------------------------------------------------
if [[ "$TARGET" == "vps" && $UFW_ENABLE -eq 1 ]] && command -v ufw >/dev/null 2>&1; then
  step "Firewall (ufw)"
  run "ufw allow 22/tcp"   # SSH — обязательно, иначе потеряешь доступ
  run "ufw allow 80/tcp"   # HTTP (Caddy + ACME challenge)
  run "ufw allow 443/tcp"  # HTTPS
  run "yes | ufw enable"
  ok "UFW активен: наружу только 22/80/443; прямые порты закрыты (доступ через домены/Caddy)"
elif [[ "$TARGET" == "local" ]]; then
  info "Локальная машина: firewall не настраиваю."
fi

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
