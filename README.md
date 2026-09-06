<!-- Файл собирается автоматически: правки в репозитории-зеркале затираются
     при следующем релизе. Оригинал — deploy/agent/README.md. -->

# Установщик агента NodeDog

[NodeDog](https://github.com/Zagorsky17/NodeDog) собирает историю «кто,
с какого IP, куда ходил» с нод Remnawave. Здесь лежит только то, что
ставится **на ноду**: установщик агента, compose-файл и шаблоны настроек.
Исходный код панели и агента живёт в закрытом репозитории, а на ноду
приезжает готовый результат — образ из GHCR или собранный бинарник.

Содержимое обновляется автоматически при каждом релизе. Править файлы
здесь бессмысленно: следующая публикация их перезапишет.

## Что агент делает и чего не делает

Делает: читает `/var/log/remnanode/access.log`, схлопывает его, снимает
метрики сервера и отправляет в панель.

**Не делает:** не пишет в журнал и не усекает его, не трогает
конфигурацию Xray, не обращается к API ноды, не управляет файрволом, не
разрывает соединения, не открывает входящих портов, не работает от root
и не имеет ни одной capability.

Установка не прерывает работу ноды и не влияет на клиентов.

## Перед установкой

Нужен включённый access-лог Xray — он включается **в панели Remnawave**,
в конфигурации Xray для этой ноды, а не на самой ноде:

```json
"log": { "access": "/var/log/remnanode/access.log" }
```

Каталог журнала должен быть проброшен томом в `docker-compose.yml` ноды,
а в inbound'ах включён `sniffing` — без него в журнал попадут только
адреса назначения, без доменов.

Ещё понадобятся UUID ноды и токен агента: панель показывает их при
создании ноды, токен — **один раз**.

## Установка в контейнере (основной способ)

Нужен docker с плагином `compose` (`apt-get install -y docker-compose-plugin`,
если его нет).

```bash
curl -fsSL https://github.com/Zagorsky17/nodedog-agent-install/releases/latest/download/nodedog-agent-install.tar.gz | tar -xz
cd nodedog-agent-install/docker && sudo ./install.sh
```

Установщик выдаёт доступ к журналу **на чтение**, определяет нужный GID,
кладёт `docker-compose.yml` и `.env` в `/opt/nodedog-agent`, подставляет
путь журнала и часовой пояс ноды, при необходимости предлагает конфиг
logrotate и скачивает образ. Останется вписать адрес панели, UUID и
токен в `/opt/nodedog-agent/.env` и выполнить `docker compose up -d`.

## Установка systemd-юнитом

Способ для тех, кому важна максимальная изоляция: песочница у юнита
жёстче, чем у контейнера, и с нодой не остаётся ни одного общего
компонента, включая сам демон docker. Бинарники обеих архитектур лежат
в том же архиве.

```bash
curl -fsSL https://github.com/Zagorsky17/nodedog-agent-install/releases/latest/download/nodedog-agent-install.tar.gz | tar -xz
cd nodedog-agent-install && sudo ./install.sh
```

Настройки — в `/etc/nodedog/agent.env`, запуск —
`systemctl enable --now nodedog-agent`.

## Обновление

**Контейнер:** поменять `AGENT_IMAGE_TAG` в `/opt/nodedog-agent/.env`
и выполнить `docker compose pull && docker compose up -d`.

**systemd:** скачать новый архив и запустить `./install.sh` ещё раз —
настройки в `/etc/nodedog/agent.env` он не трогает.

## Проверка

```bash
# контейнер
cd /opt/nodedog-agent && docker compose run --rm agent --dry-run
docker compose logs -f

# systemd
nodedog-agent --dry-run
systemctl status nodedog-agent
```

`--dry-run` показывает, понял ли агент формат журнала, и ничего никуда
не отправляет. Это первое, что стоит выполнить на новой ноде.

## Удаление

```bash
# контейнер
cd /opt/nodedog-agent && docker compose down -v && rm -rf /opt/nodedog-agent

# systemd
systemctl disable --now nodedog-agent
rm -f /etc/systemd/system/nodedog-agent.service /usr/local/bin/nodedog-agent
rm -rf /etc/nodedog /var/lib/nodedog
userdel nodedog
```

Ни то, ни другое не затрагивает ноду: агент не менял ни её конфигурацию,
ни правила файрвола. Конфиг ротации `/etc/logrotate.d/remnanode`, если
его ставил установщик, лучше оставить — без ротации журнал Xray
заполнит раздел.
