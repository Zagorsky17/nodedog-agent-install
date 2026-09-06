#!/usr/bin/env bash
# Установка агента NodeDog на ноду Remnawave — вариант с systemd.
#
# Основной способ установки — контейнер: docker/install.sh. Этот вариант
# оставлен для тех, кому важна максимальная изоляция: у systemd-юнита
# песочница жёстче всего, что даёт docker, и агент не разделяет с нодой
# ни одного общего компонента. Сравнение — в docs/deploy.md, раздел 7.
#
# Что скрипт делает на ноде:
#   - создаёт системного пользователя nodedog без оболочки и без дома;
#   - кладёт бинарник в /usr/local/bin;
#   - даёт пользователю доступ на ЧТЕНИЕ журнала Xray;
#   - ставит systemd-юнит с жёсткой песочницей.
#
# Чего скрипт НЕ делает — и это важнее:
#   - не трогает конфигурацию Xray и ноды Remnawave;
#   - не перезапускает контейнер ноды;
#   - не меняет правила файрвола;
#   - не открывает ни одного входящего порта.
#
# Установка не прерывает работу ноды и не влияет на клиентов.

set -euo pipefail

BINARY_PATH="/usr/local/bin/nodedog-agent"
CONFIG_DIR="/etc/nodedog"
CONFIG_FILE="$CONFIG_DIR/agent.env"
STATE_DIR="/var/lib/nodedog"
SERVICE_FILE="/etc/systemd/system/nodedog-agent.service"
LOG_PATH="${NODEDOG_LOG_PATH:-/var/log/remnanode/access.log}"
AGENT_USER="nodedog"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info()  { printf '\033[0;36m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[0;33mВНИМАНИЕ:\033[0m %s\n' "$*"; }
error() { printf '\033[0;31mОШИБКА:\033[0m %s\n' "$*" >&2; }

# Права на журнал выдаёт общий с контейнерным установщиком файл: это
# единственное место, где агент получает доступ к персональным данным,
# и расходиться двум его копиям нельзя.
# shellcheck source=lib/log-access.sh
. "$SCRIPT_DIR/lib/log-access.sh"

# --- Проверки --------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || { error "Запустите с правами root."; exit 1; }
command -v systemctl >/dev/null || { error "Нужен systemd."; exit 1; }

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64) GOARCH=amd64 ;;
    aarch64|arm64) GOARCH=arm64 ;;
    *) error "Архитектура $ARCH не поддерживается."; exit 1 ;;
esac
info "Архитектура: $ARCH → linux-$GOARCH"

# --- Бинарник --------------------------------------------------------------
# Ищем рядом со скриптом: скачивать что-то из интернета на боевую ноду
# без нужды не стоит, бинарник приезжает готовым.
#
# Порядок кандидатов повторяет два способа запуска. Первый — из клона
# репозитория (`deploy/agent/install.sh`), там dist лежит на два уровня
# выше. Второй — на ноде после `scp -r deploy/agent agent/dist`, где
# каталоги становятся соседями: `agent/` и `dist/` внутри
# /tmp/nodedog-install. Без второго кандидата документированный способ
# установки не находил бы бинарник вовсе.
SOURCE_BINARY=""
for candidate in \
    "$SCRIPT_DIR/../../agent/dist/nodedog-agent-linux-$GOARCH" \
    "$SCRIPT_DIR/../dist/nodedog-agent-linux-$GOARCH" \
    "$SCRIPT_DIR/nodedog-agent-linux-$GOARCH" \
    "$SCRIPT_DIR/nodedog-agent"
do
    [ -f "$candidate" ] && { SOURCE_BINARY="$candidate"; break; }
done

if [ -z "$SOURCE_BINARY" ]; then
    error "Бинарник не найден. Соберите его у себя: make agent — и"
    error "скопируйте на ноду вместе с этим каталогом:"
    error "    scp -r deploy/agent agent/dist root@нода:/tmp/nodedog-install/"
    exit 1
fi

# --- Журнал Xray -----------------------------------------------------------
check_log_present "$LOG_PATH"

# --- Пользователь ----------------------------------------------------------
if id "$AGENT_USER" >/dev/null 2>&1; then
    info "Пользователь $AGENT_USER уже существует"
else
    info "Создание системного пользователя $AGENT_USER"
    # Без оболочки и без домашнего каталога: учётная запись служебная,
    # входить под ней некуда и незачем.
    useradd --system --no-create-home --shell /usr/sbin/nologin "$AGENT_USER"
fi

# --- Доступ к журналу ------------------------------------------------------
# Только чтение и только для агента. Обоснование выбранного способа —
# в lib/log-access.sh, там же живёт та же логика для контейнера.
grant_log_access "$LOG_PATH" "$AGENT_USER" "$AGENT_USER"

# --- Файлы -----------------------------------------------------------------
info "Установка бинарника в $BINARY_PATH"
# Останавливаем службу перед заменой: перезаписать работающий бинарник
# нельзя («text file busy»).
systemctl stop nodedog-agent 2>/dev/null || true
install -m 0755 -o root -g root "$SOURCE_BINARY" "$BINARY_PATH"

info "Подготовка каталогов"
install -d -m 0750 -o root -g "$AGENT_USER" "$CONFIG_DIR"
install -d -m 0750 -o "$AGENT_USER" -g "$AGENT_USER" "$STATE_DIR"
install -d -m 0750 -o "$AGENT_USER" -g "$AGENT_USER" "$STATE_DIR/spool"

if [ -f "$CONFIG_FILE" ]; then
    info "Настройки уже есть, не трогаем: $CONFIG_FILE"
else
    info "Создание $CONFIG_FILE из шаблона"
    # Права 0640 и группа nodedog: в файле лежит токен агента, читать
    # его посторонним незачем.
    install -m 0640 -o root -g "$AGENT_USER" \
        "$SCRIPT_DIR/agent.env.example" "$CONFIG_FILE"
    NEEDS_CONFIG=1
fi

info "Установка systemd-юнита"
install -m 0644 -o root -g root "$SCRIPT_DIR/nodedog-agent.service" "$SERVICE_FILE"
systemctl daemon-reload

# --- Ротация журнала -------------------------------------------------------
install_logrotate "$SCRIPT_DIR" "$LOG_PATH"

# --- Итог ------------------------------------------------------------------
echo
if [ "${NEEDS_CONFIG:-0}" = "1" ]; then
    info "Установка завершена. Осталось настроить агента:"
    echo
    echo "  1. Создайте ноду в панели: Ноды → Добавить ноду."
    echo "     Панель покажет UUID и токен — токен показывается один раз."
    echo
    echo "  2. Впишите их в $CONFIG_FILE:"
    echo "       NODEDOG_PANEL_URL=https://ваша-панель"
    echo "       NODEDOG_NODE_UUID=..."
    echo "       NODEDOG_TOKEN=..."
    echo
    echo "  3. Проверьте, что агент понимает журнал:"
    echo "       nodedog-agent --dry-run"
    echo
    echo "  4. Запустите:"
    echo "       systemctl enable --now nodedog-agent"
    echo "       systemctl status nodedog-agent"
else
    info "Обновление завершено, запускаем службу"
    systemctl enable --now nodedog-agent
    sleep 2
    systemctl --no-pager status nodedog-agent | head -12
fi
