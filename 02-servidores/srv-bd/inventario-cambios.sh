#!/bin/bash
# =====================================================================
#  Inventario: que se instalo o cambio en este servidor (solo LECTURA).
#  Uso (root):  bash inventario-cambios.sh [dias]     (por defecto 14)
#  Genera /tmp/inventario-<equipo>.txt  (no muestra contrasenas)
# =====================================================================
D=${1:-14}
OUT=/tmp/inventario-$(hostname)-$(date +%Y%m%d-%H%M).txt
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
t() { echo; echo "=================== $1 ==================="; }
{
echo "Inventario de $(hostname) - $(date '+%d/%m/%Y %H:%M') - cambios de los ultimos $D dias"

t "1 Inicios de sesion recientes (quien entro)"
last -n 30 -w 2>/dev/null | grep -v '^$' | head -30

t "2 Paquetes instalados / quitados"
zgrep -hE ' (install|remove|purge) ' /var/log/dpkg.log* 2>/dev/null | sort | \
  awk -v lim="$(date -d "-$D days" +%F)" '$1>=lim' | grep -v ':all\b.*<none>' | tail -80

t "3 Servicios activos y servicios creados a mano"
systemctl list-units --type=service --state=running --no-pager --no-legend | awk '{print $1}'
echo "-- unidades en /etc/systemd/system modificadas:"
find /etc/systemd/system -maxdepth 1 -name '*.service' -mtime -$D -printf '%TY-%Tm-%Td %TH:%TM  %p\n' 2>/dev/null | sort

t "4 Puertos escuchando"
ss -tlnpH 2>/dev/null | awk '{print $4, $6}' | sed 's/users:((//; s/,pid=[0-9]*,fd=[0-9]*//g; s/))//' | sort -u

t "5 Publicado por Tailscale"
tailscale serve status 2>/dev/null || echo "(sin tailscale serve)"
tailscale funnel status 2>/dev/null | head -5

t "6 Apache: sitios y configuraciones"
ls -l /etc/apache2/sites-enabled/ /etc/apache2/conf-enabled/ 2>/dev/null | grep -- '->' | awk '{print $9, $10, $11}'
grep -hE '^\s*(Alias|ProxyPass|DocumentRoot|ServerName)\b' /etc/apache2/sites-enabled/* /etc/apache2/conf-enabled/* 2>/dev/null | sed 's/^\s*//' | sort -u

t "7 Archivos nuevos o modificados (web, apps, /etc)"
for d in /var/www /opt /srv /usr/local /etc; do
  find $d -xdev -type f -mtime -$D \
    -not -path '*/node_modules/*' -not -path '*/.git/*' -not -path '*/cache/*' \
    -not -path '/etc/ssl/*' -not -name '*.log' \
    -printf '%TY-%Tm-%Td %TH:%TM  %u:%g  %s B  %p\n' 2>/dev/null
done | sort -r | head -150

t "8 Carpetas personales (home) con cambios"
find /home -xdev -type f -mtime -$D -not -path '*/.cache/*' -not -name '.bash_history' -not -path '*/node_modules/*' \
  -printf '%TY-%Tm-%Td %TH:%TM  %p\n' 2>/dev/null | sort -r | head -60

t "9 Usuarios del sistema (UID >= 1000) y sudo"
getent passwd | awk -F: '$3>=1000 && $3<65000 {print $1, $3, $6, $7}'
echo "-- grupo sudo: $(getent group sudo | cut -d: -f4)"

t "10 Tareas programadas"
ls -l /etc/cron.d 2>/dev/null | tail -n +2
for u in $(getent passwd | awk -F: '$3==0 || ($3>=1000 && $3<65000) {print $1}'); do
  c=$(crontab -l -u $u 2>/dev/null | grep -v '^#' | grep -v '^$'); [ -n "$c" ] && { echo "-- crontab de $u:"; echo "$c"; }
done
systemctl list-timers --no-pager --no-legend 2>/dev/null | awk '{print $NF}' | head -20

t "11 Bases de datos (MariaDB)"
if command -v mysql >/dev/null; then
  mysql -N -e "SELECT CONCAT(table_schema,'.',table_name,'  creada ',IFNULL(create_time,'?')) FROM information_schema.tables
               WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys')
               ORDER BY create_time DESC LIMIT 60" 2>/dev/null
  echo "-- usuarios de MariaDB:"; mysql -N -e "SELECT CONCAT(user,'@',host) FROM mysql.user ORDER BY user" 2>/dev/null
fi

t "12 Contenedores (si hay Docker)"
command -v docker >/dev/null && docker ps -a --format '{{.Names}}  {{.Image}}  {{.Status}}  {{.Ports}}' || echo "(sin docker)"

t "13 Ultimos comandos de administrador (root y sudo)"
grep -hE 'sudo: .*COMMAND=' /var/log/auth.log* 2>/dev/null | tail -40 | sed 's/.*sudo: *//'
journalctl _COMM=sudo --since "-${D}d" --no-pager 2>/dev/null | grep COMMAND= | tail -40 | sed 's/.*sudo\[[0-9]*\]: *//'
} > "$OUT" 2>&1
chmod 600 "$OUT"
echo "Listo: $OUT ($(wc -l < "$OUT") lineas)"
echo "Copialo a tu PC desde CMD con:  scp $(logname 2>/dev/null || echo israel)@<IP>:$OUT ."
