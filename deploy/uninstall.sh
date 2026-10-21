#!/bin/sh
# This script is uploaded through verified SSH and requires explicit UI confirmation.
set -eu
test "$(id -u)" = 0 || { echo 'Требуется root или sudo.' >&2; exit 1; }
umask 077
exec 9>/run/yggvion-maintenance.lock
flock -n 9 || { echo 'Другая операция с сервером уже выполняется.' >&2; exit 1; }
mode=${1:-keep-data}
case "$mode" in keep-data|purge) ;; *) exit 1;; esac
if test "$mode" = purge; then
  test "${2:-}" = DELETE-YGGVION || { echo 'Не подтверждено удаление данных.' >&2; exit 1; }
fi
for path in /opt/yggvion /var/lib/yggvion /etc/systemd/system/yggvion.service; do
  test ! -L "$path" || { echo 'Небезопасный путь установки.' >&2; exit 1; }
done
test -f /etc/systemd/system/yggvion.service || { echo 'Сервис Yggvion не найден.' >&2; exit 1; }
grep -q '^ExecStart=/opt/yggvion/yggvion$' /etc/systemd/system/yggvion.service || {
  echo 'Нестандартная установка: автоматическое удаление остановлено.' >&2; exit 1;
}
systemctl stop yggvion
systemctl disable yggvion
rm -f /etc/systemd/system/yggvion.service
systemctl daemon-reload
rm -rf -- /opt/yggvion
if test "$mode" = purge; then
  rm -rf -- /var/lib/yggvion
  if id yggvion >/dev/null 2>&1; then userdel yggvion; fi
fi
printf 'Сервер Yggvion удалён.\n'
