#!/bin/sh
# Called through a verified SSH connection. Arguments contain no credentials.
set -eu
test "$(id -u)" = 0 || { echo 'Требуется root или sudo.' >&2; exit 1; }
host=$1
port=$2
binary=$3
expected=$4
case "$port" in ''|*[!0-9]*) exit 1;; esac
test "$port" -ge 1 && test "$port" -le 65535
. /etc/os-release
case "$ID" in debian|ubuntu) ;; *) echo 'Поддерживаются Ubuntu и Debian с systemd.' >&2; exit 1;; esac
command -v systemctl >/dev/null
test -d /run/systemd/system
test "$(sha256sum "$binary" | cut -d ' ' -f 1)" = "$expected"
listeners=$(ss -H -ltnp "sport = :$port")
if test -n "$listeners"; then
  service_pid=$(systemctl show -p MainPID --value yggvion.service 2>/dev/null || true)
  case "$service_pid" in ''|0|*[!0-9]*) echo 'HTTPS-порт уже занят.' >&2; exit 1;; esac
  # Reinstall may reuse this service's port, never another process's listener.
  if printf '%s\n' "$listeners" | grep -v "pid=$service_pid," | read -r line; then
    echo 'Порт занят другим сервисом. Выберите другой HTTPS-порт.' >&2
    exit 1
  fi
fi
if ! id yggvion >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/yggvion --shell /usr/sbin/nologin yggvion
fi
install -d -m 0755 /opt/yggvion
install -d -m 0700 -o yggvion -g yggvion /var/lib/yggvion
# Reinstalling keeps the current identity, database and backups.
install -m 0755 "$binary" /opt/yggvion/yggvion.next
if test -x /opt/yggvion/yggvion; then
  runuser -u yggvion -- env YGGVION_DATA_DIR=/var/lib/yggvion /opt/yggvion/yggvion.next backup
  cp /opt/yggvion/yggvion /opt/yggvion/yggvion.previous
  cp -p /etc/systemd/system/yggvion.service /opt/yggvion/service.previous
  cp -p /var/lib/yggvion/server.json /opt/yggvion/server.previous.json
fi
# Roll back the configuration as well as the executable if any installation
# step fails. This also covers systemctl restart returning nonzero immediately.
rollback() {
  trap - EXIT
  set +e
  if test -x /opt/yggvion/yggvion.previous; then
    mv /opt/yggvion/yggvion.previous /opt/yggvion/yggvion
    cp -p /opt/yggvion/service.previous /etc/systemd/system/yggvion.service
    cp -p /opt/yggvion/server.previous.json /var/lib/yggvion/server.json
    systemctl daemon-reload
    if systemctl restart yggvion; then
      echo 'Обновление остановлено. Восстановлены предыдущий бинарник и настройки; данные сохранены.' >&2
    else
      echo 'Откат восстановил бинарник и настройки, но сервис не запустился. Проверьте журнал; данные сохранены.' >&2
    fi
  else
    echo 'Установка не завершена. Проверьте журнал сервиса; данные сохранены.' >&2
  fi
  exit 1
}
trap rollback EXIT
mv /opt/yggvion/yggvion.next /opt/yggvion/yggvion
cat > /etc/systemd/system/yggvion.service <<'UNIT'
[Unit]
Description=Yggvion private sync server
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=yggvion
Group=yggvion
WorkingDirectory=/var/lib/yggvion
Environment=YGGVION_DATA_DIR=/var/lib/yggvion
ExecStart=/opt/yggvion/yggvion
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
ReadWritePaths=/var/lib/yggvion
[Install]
WantedBy=multi-user.target
UNIT
runuser -u yggvion -- /opt/yggvion/yggvion bootstrap --data-dir /var/lib/yggvion --host "$host" --port "$port"
systemctl daemon-reload
systemctl enable yggvion >/dev/null
systemctl restart yggvion
if command -v ufw >/dev/null 2>&1 && ufw status | head -n 1 | grep -q 'Status: active'; then
  ufw allow "$port/tcp" >/dev/null
fi
sleep 2
if ! systemctl is-active --quiet yggvion; then
  exit 1
fi
trap - EXIT
