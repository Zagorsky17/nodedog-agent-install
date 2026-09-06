#!/usr/bin/env bash
# Установка агента NodeDog на ноду Remnawave — основной, контейнерный вариант.
#
# Что скрипт делает на ноде:
#   - выдаёт доступ на ЧТЕНИЕ журнала Xray и узнаёт нужный GID;
#   - кладёт docker-compose.yml и .env в /opt/nodedog-agent;
#   - при необходимости ставит конфиг logrotate для журнала Xray;
#   - поднимает контейнер агента.
#
# Чего скрипт НЕ делает — и это важнее:
#   - не трогает конфигурацию Xray и ноды Remnawave;
#   - не заглядывает в compose-проект ноды и не перезапускает её контейнер;
#   - не меняет правила файрвола;
#   - не открывает ни одного входящего порта.
#
# Установка не прерывает работу ноды и не влияет на клиентов.
#
# Вариант с systemd, у которого песочница ещё жёстче, — ../install.sh.

set -euo pipefail

INSTALL_DIR="/opt/nodedog-agent"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
LOG_PATH="${NODEDOG_LOG_PATH:-/var/log/remnanode/access.log}"

# UID, от которого работает контейнер. Совпадает с владельцем каталога
# состояния внутри образа и с user: в docker-compose.yml — менять его
# можно только в трёх местах разом.
AGENT_UID=65532

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

info()  { printf '\033[0;36m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[0;33mВНИМАНИЕ:\033[0m %s\n' "$*"; }
error() { printf '\033[0;31mОШИБКА:\033[0m %s\n' "$*" >&2; }

# Права на журнал выдаёт общий с systemd-установщиком файл: это
# единственное место, где агент получает доступ к персональным данным,
# и расходиться двум его копиям нельзя.
# shellcheck source=../lib/log-access.sh
. "$DEPLOY_DIR/lib/log-access.sh"

# --- Проверки --------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || { error "Запустите с правами root."; exit 1; }
command -v docker >/dev/null || { error "Нужен docker."; exit 1; }
docker compose version >/dev/null 2>&1 || {
    error "Нужен плагин docker compose (docker compose version)."
    exit 1
}

# --- Журнал Xray -----------------------------------------------------------
check_log_present "$LOG_PATH"

# --- Доступ к журналу ------------------------------------------------------
# Контейнер работает не от root, поэтому доступ выдаётся его UID и группе
# журнала. Обоснование выбранного способа — в lib/log-access.sh.
grant_log_access "$LOG_PATH" "$AGENT_UID"

if [ -z "$LOG_ACCESS_GID" ]; then
    error "Не удалось определить группу журнала. Проверьте вручную:"
    error "    stat -c '%g %G' $(dirname "$LOG_PATH")"
    exit 1
fi
info "Контейнер запустится с GID $LOG_ACCESS_GID (${LOG_ACCESS_GROUP:-группа без имени})"

# --- Ротация журнала -------------------------------------------------------
install_logrotate "$DEPLOY_DIR" "$LOG_PATH"

# --- Файлы -----------------------------------------------------------------
info "Подготовка $INSTALL_DIR"
install -d -m 0750 -o root -g root "$INSTALL_DIR"

# compose-файл перезаписывается всегда: он часть поставки, править его
# на ноде незачем — всё, что настраивается, живёт в .env.
install -m 0644 -o root -g root "$SCRIPT_DIR/docker-compose.yml" "$COMPOSE_FILE"

if [ -f "$ENV_FILE" ]; then
    info "Настройки уже есть, не трогаем: $ENV_FILE"
else
    info "Создание $ENV_FILE из шаблона"
    # Права 0600: в файле лежит токен агента, читать его посторонним
    # незачем, а сам docker compose работает от root.
    install -m 0600 -o root -g root "$SCRIPT_DIR/.env.example" "$ENV_FILE"

    # Подставляем то, что знаем про эту ноду, чтобы человеку осталось
    # вписать только адрес панели, UUID и токен.
    # Каталог и имя файла задаются порознь, а путь для агента и точка
    # монтирования собираются из них в compose-файле. Так они не могут
    # разойтись: два независимых значения однажды разъезжаются, и агент
    # уходит ждать файл, которого в контейнере нет.
    sed -i "s|^AGENT_GID=.*|AGENT_GID=$LOG_ACCESS_GID|" "$ENV_FILE"
    sed -i "s|^AGENT_LOG_DIR=.*|AGENT_LOG_DIR=$(dirname "$LOG_PATH")|" "$ENV_FILE"
    sed -i "s|^AGENT_LOG_FILE=.*|AGENT_LOG_FILE=$(basename "$LOG_PATH")|" "$ENV_FILE"
    if TZ_NAME="$(timedatectl show -p Timezone --value 2>/dev/null)" && [ -n "$TZ_NAME" ]; then
        # Пояс контейнера иначе окажется UTC, и вся статистика уедет
        # на несколько часов, ничем себя не выдав.
        sed -i "s|^NODEDOG_LOG_TIMEZONE=.*|NODEDOG_LOG_TIMEZONE=$TZ_NAME|" "$ENV_FILE"
        info "Часовой пояс ноды: $TZ_NAME"
    else
        warn "Не удалось определить часовой пояс ноды."
        warn "Проверьте NODEDOG_LOG_TIMEZONE в $ENV_FILE — иначе метки"
        warn "времени будут разобраны как UTC."
    fi
    NEEDS_CONFIG=1
fi

# --- Образ -----------------------------------------------------------------
# Тянем сразу, а не оставляем это первому `docker compose up`. Версия в
# .env пинуется явно, и опечатка или ещё не опубликованный тег дают
# `manifest unknown` — на шаге, где оператор уже вписал токен и ждёт
# работающего агента. Здесь та же ошибка приходит с объяснением и до
# всякой настройки.
info "Скачиваем образ агента"
if ! docker compose -f "$COMPOSE_FILE" pull; then
    error "Образ агента не скачался."
    error "Проверьте AGENT_IMAGE_TAG в $ENV_FILE: там должна стоять уже"
    error "опубликованная версия — список в разделе Packages репозитория."
    exit 1
fi

# --- Запуск ----------------------------------------------------------------
echo
if [ "${NEEDS_CONFIG:-0}" = "1" ]; then
    info "Установка завершена. Осталось настроить агента:"
    echo
    echo "  1. Создайте ноду в панели: Ноды → Добавить ноду."
    echo "     Панель покажет UUID и токен — токен показывается один раз."
    echo
    echo "  2. Впишите их в $ENV_FILE:"
    echo "       NODEDOG_PANEL_URL=https://ваша-панель"
    echo "       NODEDOG_NODE_UUID=..."
    echo "       NODEDOG_TOKEN=..."
    echo
    echo "  3. Проверьте, что агент понимает журнал:"
    echo "       cd $INSTALL_DIR && docker compose run --rm agent --dry-run"
    echo
    echo "  4. Запустите:"
    echo "       cd $INSTALL_DIR && docker compose up -d"
    echo "       docker compose logs -f"
else
    info "Обновление: перезапускаем контейнер на скачанном образе"
    # Файл задаётся явно: `--project-directory` не влияет на то, где
    # compose ищет compose.yaml — он ищет его в текущем каталоге. Без
    # `-f` обновление шло бы по файлу из /tmp, а при запуске скрипта из
    # постороннего каталога и вовсе падало бы с «no configuration file».
    #
    # Только свой compose-проект: контейнер ноды эти команды не видят.
    docker compose -f "$COMPOSE_FILE" up -d
    sleep 2
    docker compose -f "$COMPOSE_FILE" ps
fi
