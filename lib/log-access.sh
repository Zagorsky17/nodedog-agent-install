# Выдача доступа к журналу Xray. Подключается обоими установщиками:
# и systemd-вариантом (../install.sh), и контейнерным (../docker/install.sh).
#
# Вынесено в общий файл намеренно. Это единственное место, где агент
# получает доступ к персональным данным, и два разошедшихся во времени
# варианта одной и той же логики прав — верный способ однажды выдать
# лишнего в одном из них и не заметить.
#
# Подключающий скрипт обязан определить info(), warn() и error().

# Группа, через которую выдаётся доступ, когда своей у каталога ещё нет.
LOG_ROTATE_GROUP="adm"

# Имя, под которым в /etc/group заводится безымянный GID каталога журнала.
LOG_UNNAMED_GROUP="nodedog-log"

# Куда ставится конфиг ротации. Вынесено в переменные, чтобы logrotate
# можно было проверить, не имея под рукой ноды: на боевой машине значения
# всегда эти.
LOGROTATE_DIR="${LOGROTATE_DIR:-/etc/logrotate.d}"
LOGROTATE_MAIN="${LOGROTATE_MAIN:-/etc/logrotate.conf}"
LOGROTATE_CONFIG="$LOGROTATE_DIR/remnanode"

# Заполняются grant_log_access. Контейнерному варианту GID нужен, чтобы
# запустить контейнер от группы, которой журнал читается. Имя группы
# может остаться пустым: у GID не обязана быть запись в /etc/group.
LOG_ACCESS_GROUP=""
LOG_ACCESS_GID=""

# check_log_present ПУТЬ — предупреждает, если журнала ещё нет.
#
# Не ошибка: агент штатно стартует раньше, чем Xray создаст файл, и
# умеет его дожидаться. Но причина почти всегда одна из двух, и назвать
# обе дешевле, чем потом разбираться по пустым отчётам.
#
# Порядок пунктов здесь — не оформление. Включённый access-лог с
# каталогом, которого внутри контейнера ноды нет, не даёт Xray
# запуститься: каталог под журнал Xray не создаёт. Совет «включите
# access-лог», выданный раньше совета про том, кладёт ноду — то есть
# ровно то, чего этот проект не должен допускать ни при каких условиях.
check_log_present() {
    local log_path="$1"
    local log_dir
    log_dir="$(dirname "$log_path")"

    [ -f "$log_path" ] && return 0

    warn "Журнала $log_path нет."
    warn "Обычно причин две, и делать их нужно строго в этом порядке:"
    warn "  1. Каталог не проброшен на хост. В docker-compose.yml ноды:"
    warn "         volumes:"
    warn "           - '$log_dir:$log_dir'"
    warn "     затем на ноде: mkdir -p $log_dir && docker compose up -d"
    warn "  2. Access-лог не включён в конфигурации Xray. Включается он"
    warn "     в ПАНЕЛИ REMNAWAVE, в конфигурации Xray для этой ноды:"
    warn "         \"log\": { \"access\": \"$log_path\" }"
    warn "     Там же в inbound'ах включается sniffing — без него в журнал"
    warn "     попадут только адреса назначения, без доменов."
    warn "ПОРЯДОК ВАЖЕН. Xray не создаёт каталог под журнал: access-лог,"
    warn "включённый раньше тома, не даёт Xray запуститься и роняет ноду."
    warn "Блок \"log\" добавляется в существующий конфиг Xray — конфиг,"
    warn "заменённый одним этим блоком, остаётся без inbounds, и нода"
    warn "не поднимется уже по этой причине."
    warn "Если нода не поднялась, причина видна не в docker logs remnanode:"
    warn "он печатает лишь факт отказа. Полный журнал Xray — внутри:"
    warn "    docker exec remnanode tail -50 /var/log/xray/current"
    warn "Агент запустится и будет ждать появления файла."
}

# ensure_rotate_group — создаёт группу доступа, если её ещё нет.
ensure_rotate_group() {
    if ! getent group "$LOG_ROTATE_GROUP" >/dev/null; then
        info "Создание группы $LOG_ROTATE_GROUP"
        groupadd --system "$LOG_ROTATE_GROUP"
    fi
}

# group_name_by_gid GID — печатает имя группы; пусто, если записи нет.
#
# Именно так, а не `stat -c '%G'`: для GID без записи в /etc/group stat
# печатает слово UNKNOWN, неотличимое от настоящего имени. Дальше с этим
# «именем» шли usermod и chgrp — и роняли установщик под `set -e` посреди
# работы, уже создав пользователя, но ещё не поставив ни бинарник, ни юнит.
# Каталог с безымянным GID — не экзотика: так выглядит каталог, созданный
# контейнером с собственным отображением пользователей.
group_name_by_gid() {
    # `|| true` не украшение: у getent нет записи — значит выход 1, а под
    # `set -o pipefail` из установщиков это уронило бы присваивание
    # результата вместе со всем скриптом.
    getent group "$1" 2>/dev/null | cut -d: -f1 || true
}

# name_unnamed_group GID — заводит имя для безымянного GID, печатает его.
#
# Саму группу мы не создаём: она уже существует в виде числа на каталоге.
# Появляется только запись с именем — она нужна usermod и logrotate,
# которые с голым числом не работают. Пусто, если завести не вышло.
name_unnamed_group() {
    local gid="$1" existing

    existing="$(getent group "$LOG_UNNAMED_GROUP" 2>/dev/null | cut -d: -f3 || true)"
    if [ -n "$existing" ]; then
        # Имя занято чужим GID — молча переиспользовать его нельзя.
        [ "$existing" = "$gid" ] && printf '%s' "$LOG_UNNAMED_GROUP"
        return 0
    fi

    if groupadd --system --gid "$gid" "$LOG_UNNAMED_GROUP" 2>/dev/null; then
        printf '%s' "$LOG_UNNAMED_GROUP"
    fi
    return 0
}

# group_mode_digit ПУТЬ — восьмеричная цифра прав группы (0..7).
group_mode_digit() {
    local mode
    mode="$(stat -c '%a' "$1")"
    # stat печатает три цифры, а для setgid/sticky — четыре.
    mode="${mode: -3}"
    printf '%s' "${mode:1:1}"
}

# has_acl_for ПУТЬ ИДЕНТИЧНОСТЬ ПРАВА — есть ли у идентичности ACL с правами.
#
# ПРАВА — буквы вроде `rx`. Для UID без записи в /etc/passwd (контейнерный
# вариант) getfacl печатает само число, поэтому сравнение идёт с тем же
# значением, что уходило в setfacl.
has_acl_for() {
    local path="$1" identity="$2" want="$3" entry i

    command -v getfacl >/dev/null 2>&1 || return 1

    entry="$(getfacl --absolute-names -- "$path" 2>/dev/null |
        grep "^user:$identity:" | head -n 1)"
    [ -n "$entry" ] || return 1
    entry="${entry##*:}"

    for (( i = 0; i < ${#want}; i++ )); do
        case "$entry" in
            *"${want:i:1}"*) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# path_reachable ПУТЬ ПРАВА ИДЕНТИЧНОСТЬ — доступен ли путь агенту.
#
# Права засчитываются, только если группа пути совпадает с той, которую
# мы выдали: биты `g+r` на файле с чужой группой агенту ничего не дают,
# а выглядят в выводе `ls` точно так же.
path_reachable() {
    local path="$1" want="$2" identity="$3"
    local gid bits mask=0 i

    for (( i = 0; i < ${#want}; i++ )); do
        case "${want:i:1}" in
            r) mask=$(( mask | 4 )) ;;
            w) mask=$(( mask | 2 )) ;;
            x) mask=$(( mask | 1 )) ;;
        esac
    done

    gid="$(stat -c '%g' "$path")"
    bits="$(group_mode_digit "$path")"
    if [ "$gid" = "$LOG_ACCESS_GID" ] && [ $(( bits & mask )) -eq "$mask" ]; then
        return 0
    fi

    has_acl_for "$path" "$identity" "$want"
}

# verify_log_access ПУТЬ ИДЕНТИЧНОСТЬ — убеждается, что журнал реально читается.
#
# Раньше установщик считал успехом сам факт того, что группа найдена, и
# печатал «Журнал читается группой …» для каталога 0700 root:somegroup,
# из которого агент получал EACCES. Выход был нулевой, и узнавали об этом
# по пустым отчётам в панели. Здесь проверка на дело: путь либо доступен
# по группе, которую мы выдали, либо по ACL, либо установка обрывается.
verify_log_access() {
    local log_path="$1" identity="$2" log_dir

    log_dir="$(dirname "$log_path")"

    if ! path_reachable "$log_dir" "rx" "$identity"; then
        error "Каталог $log_dir агенту недоступен."
        error "Права: $(stat -c '%A %U:%G' "$log_dir"), выданная группа:"
        error "  ${LOG_ACCESS_GROUP:-без имени} (GID ${LOG_ACCESS_GID:-неизвестен})."
        error "Поставьте пакет acl и повторите установку либо откройте каталог"
        error "группе: chgrp ${LOG_ACCESS_GROUP:-<группа>} $log_dir && chmod g+rx $log_dir"
        exit 1
    fi

    if [ -f "$log_path" ] && ! path_reachable "$log_path" "r" "$identity"; then
        error "Журнал $log_path агенту недоступен."
        error "Права: $(stat -c '%A %U:%G' "$log_path"), выданная группа:"
        error "  ${LOG_ACCESS_GROUP:-без имени} (GID ${LOG_ACCESS_GID:-неизвестен})."
        error "Файл создаёт Xray, и без ACL на каталоге доступ к нему не"
        error "переживает пересоздание. Поставьте пакет acl и повторите установку."
        exit 1
    fi

    info "Доступ к журналу проверен: ${LOG_ACCESS_GROUP:-GID $LOG_ACCESS_GID}"
}

# grant_log_access ПУТЬ ИДЕНТИЧНОСТЬ [ИМЯ_ПОЛЬЗОВАТЕЛЯ]
#
# ИДЕНТИЧНОСТЬ — то, кому выдаётся ACL: имя пользователя (systemd-вариант)
# или числовой UID (контейнер, где пользователя на хосте нет вовсе).
# ИМЯ_ПОЛЬЗОВАТЕЛЯ, если задано, дополнительно включается в группу.
#
# Мировое чтение (chmod o+r) здесь недопустимо. В access.log лежит поле
# email вместе с адресом источника и назначением — то есть ровно те
# персональные данные, ради защиты которых панель закрыта аутентификацией
# и пишет в журнал каждый просмотр карточки пользователя. Открыв файл
# всем, мы отдали бы их любому непривилегированному процессу и любому
# соседнему контейнеру на этой же ноде.
#
# Второе требование — доступ обязан пережить ротацию. logrotate создаёт
# новый файл по шаблону `create`, и любые права, выставленные на текущий
# файл руками, после первой же ротации исчезают. Поэтому доступ выдаётся
# через группу, а не через chmod по месту, а install_logrotate подставляет
# в свой конфиг ту самую группу, которую выдали здесь.
grant_log_access() {
    local log_path="$1"
    local identity="$2"
    local username="${3:-}"
    local log_dir log_group log_gid

    log_dir="$(dirname "$log_path")"

    if [ ! -d "$log_dir" ]; then
        # Каталога нет — выдавать нечего. Группу называем ожидаемую:
        # когда каталог появится, logrotate создаст файл именно с ней.
        # Создаём её прямо сейчас: контейнерному варианту GID нужен
        # обязательно, а «каталога ещё нет» — это как раз свежая нода,
        # то есть самый вероятный первый запуск установщика.
        ensure_rotate_group
        LOG_ACCESS_GROUP="$LOG_ROTATE_GROUP"
        LOG_ACCESS_GID="$(getent group "$LOG_ROTATE_GROUP" | cut -d: -f3)"
        # Пользователя включаем в группу сразу: второй раз установщик
        # никто не запустит, а каталог появится сам — вместе с первым
        # запуском Xray, уже после того как мы отсюда ушли.
        if [ -n "$username" ]; then
            usermod -aG "$LOG_ROTATE_GROUP" "$username"
        fi
        return 0
    fi

    log_gid="$(stat -c '%g' "$log_dir")"
    log_group="$(group_name_by_gid "$log_gid")"

    if [ "$log_gid" != "0" ] && [ "$log_group" != "$username" ]; then
        # У каталога уже есть непривилегированная группа — берём её как
        # есть. Менять группу чужого каталога нельзя: в него пишет
        # контейнер ноды, и трогать его настройки ради статистики —
        # ровно то, чего агент делать не должен.
        if [ -z "$log_group" ]; then
            log_group="$(name_unnamed_group "$log_gid")"
        fi

        if [ -n "$username" ]; then
            if [ -n "$log_group" ]; then
                info "Добавляем $username в группу $log_group для чтения журнала"
                usermod -aG "$log_group" "$username"
            else
                warn "У группы каталога $log_dir (GID $log_gid) нет имени,"
                warn "и включить в неё $username нечем. Доступ остаётся только"
                warn "за ACL — без пакета acl установка сейчас оборвётся."
            fi
        else
            info "Журнал уже принадлежит группе ${log_group:-GID $log_gid}, ничего не меняем"
        fi
        LOG_ACCESS_GROUP="$log_group"
        LOG_ACCESS_GID="$log_gid"
    else
        # Каталог принадлежит root:root. Отдаём его группе, которую
        # проставляет logrotate, — тогда и текущий файл, и все будущие
        # останутся читаемыми ровно для того, кому мы выдали доступ.
        ensure_rotate_group
        if [ -n "$username" ]; then
            info "Выдаём $username доступ к журналу через группу $LOG_ROTATE_GROUP"
            usermod -aG "$LOG_ROTATE_GROUP" "$username"
        else
            info "Отдаём каталог журнала группе $LOG_ROTATE_GROUP"
        fi
        chgrp "$LOG_ROTATE_GROUP" "$log_dir"
        chmod 0750 "$log_dir"
        if [ -f "$log_path" ]; then
            chgrp "$LOG_ROTATE_GROUP" "$log_path"
            chmod 0640 "$log_path"
        fi
        LOG_ACCESS_GROUP="$LOG_ROTATE_GROUP"
        LOG_ACCESS_GID="$(getent group "$LOG_ROTATE_GROUP" | cut -d: -f3)"
    fi

    # Xray в контейнере ноды создаёт файл заново после каждого своего
    # перезапуска, уже со своей группой. ACL переживает и это: он
    # наследуется от каталога, а не от того, кто создал файл.
    if command -v setfacl >/dev/null 2>&1; then
        info "Закрепляем доступ ACL (переживает пересоздание файла)"
        setfacl -m "u:$identity:rx" "$log_dir" 2>/dev/null || true
        setfacl -d -m "u:$identity:r" "$log_dir" 2>/dev/null || true
        [ -f "$log_path" ] && setfacl -m "u:$identity:r" "$log_path" 2>/dev/null || true
    else
        warn "Утилиты setfacl нет (пакет acl)."
        warn "Если Xray пересоздаст журнал со своей группой, агент потеряет"
        warn "к нему доступ. Поставьте acl и перезапустите установку."
    fi

    verify_log_access "$log_path" "$identity"
}

# logrotate_config_for КАТАЛОГ — печатает конфиг, уже покрывающий каталог.
#
# logrotate отказывается обрабатывать один и тот же путь дважды: второе
# вхождение он отбрасывает с `duplicate log entry`, целиком — вместе с той
# ротацией, которую мы и хотели добавить. Ошибка при этом приходит каждый
# день и с каждой ноды, куда rollout.sh поставил свой конфиг.
logrotate_config_for() {
    local log_dir="$1" file

    for file in "$LOGROTATE_MAIN" "$LOGROTATE_DIR"/*; do
        [ -f "$file" ] || continue
        # Комментарии пропускаем: в них путь упоминают, а не ротируют.
        if grep -v '^[[:space:]]*#' "$file" 2>/dev/null | grep -qF "$log_dir/"; then
            printf '%s' "$file"
            return 0
        fi
    done
    return 0
}

# install_logrotate КАТАЛОГ_СКРИПТА ПУТЬ_К_ЖУРНАЛУ — ставит конфиг ротации.
#
# Без ротации access.log заполнит раздел и остановит ноду — то есть
# именно то, чего агент не должен допустить ни при каких условиях.
install_logrotate() {
    local script_dir="$1"
    local log_path="$2"
    local log_dir covered answer tmp

    log_dir="$(dirname "$log_path")"

    [ -f "$LOGROTATE_CONFIG" ] && return 0
    [ -d "$LOGROTATE_DIR" ] || return 0

    covered="$(logrotate_config_for "$log_dir")"
    if [ -n "$covered" ]; then
        info "Ротация $log_dir уже настроена в $covered — свой конфиг не ставим"
        return 0
    fi

    warn "Ротация журнала Xray не настроена."
    warn "Без неё access.log заполнит раздел и остановит ноду."

    # Без терминала спрашивать некого, а `read` при EOF возвращает 1 и
    # под `set -e` роняет весь установщик молча — именно так это и
    # выглядело при запуске через ssh из rollout.sh или из cron.
    # Ставим конфиг сам: непоставленная ротация однажды останавливает
    # ноду, а лишний файл в /etc/logrotate.d не ломает ничего.
    if [ ! -t 0 ]; then
        info "Терминала нет — ставим конфиг ротации по умолчанию"
    else
        read -r -p "Установить готовый конфиг logrotate? [Y/n] " answer
        [ "${answer:-Y}" = "n" ] && return 0
    fi

    # Группа в `create` — та же, которую выдал grant_log_access. Оставить
    # здесь жёстко прошитую `adm`, приняв при этом группу каталога, значило
    # бы отдать первый же созданный ротацией файл группе, которой у агента
    # нет: сутки данные идут, потом тишина без единой ошибки с обеих сторон.
    # Заглушки заменяются только в начале строки: те же имена стоят и в
    # шапке шаблона, в примере для ручной установки, и подстановка внутри
    # комментария превратила бы объяснение в бессмыслицу.
    tmp="$(mktemp)"
    sed -e "s|^@LOG_PATTERN@|$log_dir/*.log|" \
        "$script_dir/logrotate-remnanode" > "$tmp"
    if [ -n "$LOG_ACCESS_GROUP" ]; then
        sed -i -e "s|^\( *\)@CREATE@|\1create 0640 root $LOG_ACCESS_GROUP|" \
            -e "s|^\( *\)@SU@|\1su root $LOG_ACCESS_GROUP|" "$tmp"
    else
        # Имени у группы нет, а числом logrotate не оперирует: сохраняем
        # владельца исходного файла и держимся на ACL, унаследованном
        # от каталога.
        sed -i -e "s|^\( *\)@CREATE@|\1create 0640|" -e "/^ *@SU@$/d" "$tmp"
    fi
    install -m 0644 "$tmp" "$LOGROTATE_CONFIG"
    rm -f "$tmp"

    info "Конфиг ротации установлен: $LOGROTATE_CONFIG"
}
