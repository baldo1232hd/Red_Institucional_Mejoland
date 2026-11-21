#!/bin/bash
# =====================================================================
#  Acelerar GLPI y Nextcloud (ejecutar en srv-apps, root)
#  Con las bases en SRV-BD cada consulta tarda ~32 ms. Esto reduce las consultas repetidas:
#   1 OPcache de PHP ajustado (el codigo PHP queda compilado en memoria)
#   2 Redis + APCu (caches en memoria, solo escuchan en este equipo)
#   3 Nextcloud: cache local (APCu), cache y bloqueos en Redis, tareas de fondo por cron del sistema
#   4 GLPI: cache en Redis
#  No cambia datos, usuarios ni la base. Respaldo en /root/proyecto/acelerar-apps-<fecha>/
#  Uso:  bash 03-acelerar-apps.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
paso() { echo; echo "=================== $1 ==================="; }
PV=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null) || { echo "No encuentro PHP"; exit 1; }
NC=$(dirname "$(find /var/www -maxdepth 3 -name occ -path '*nextcloud*' 2>/dev/null | head -1)" 2>/dev/null)
GL=$(dirname "$(dirname "$(find /var/www -maxdepth 4 -path '*glpi*/bin/console' 2>/dev/null | head -1)")" 2>/dev/null)
[ -f "$NC/occ" ] || NC=""; [ -f "$GL/bin/console" ] || GL=""
echo "PHP $PV   Nextcloud: ${NC:-no encontrado}   GLPI: ${GL:-no encontrado}"
medir() { printf '  GLPI: %s s   Nube: %s s\n' "$(curl -o /dev/null -s -w '%{time_total}' http://127.0.0.1/glpi/)" "$(curl -o /dev/null -s -w '%{time_total}' -L http://127.0.0.1/nube/)"; }
echo "Antes:"; medir; medir

BK=/root/proyecto/acelerar-apps-$(date +%Y%m%d-%H%M); mkdir -p $BK; chmod 700 $BK
[ -n "$NC" ] && cp -a "$NC/config/config.php" $BK/nextcloud-config.php
crontab -u www-data -l > $BK/crontab-www-data.txt 2>/dev/null || true

paso "1 Paquetes (Redis, APCu, extension Redis de PHP)"
DEBIAN_FRONTEND=noninteractive apt-get install -y -q redis-server php$PV-redis php$PV-apcu >/dev/null 2>&1 \
  || DEBIAN_FRONTEND=noninteractive apt-get install -y -q redis-server php-redis php-apcu >/dev/null 2>&1 \
  || { echo "  ERROR instalando paquetes (revisa apt). No se cambio la configuracion."; exit 1; }
sed -i 's/^#\? *bind .*/bind 127.0.0.1 ::1/' /etc/redis/redis.conf
grep -q '^maxmemory ' /etc/redis/redis.conf || printf '\n# Mejoland: limite de memoria para caches\nmaxmemory 256mb\nmaxmemory-policy allkeys-lru\n' >> /etc/redis/redis.conf
systemctl enable -q redis-server; systemctl restart redis-server
redis-cli ping | grep -q PONG && echo "  Redis: OK (solo local, max 256 MB)" || { echo "  ERROR: Redis no responde"; exit 1; }

paso "2 OPcache y APCu de PHP"
for SAPI in apache2 cli; do
  D=/etc/php/$PV/$SAPI/conf.d; [ -d $D ] || continue
  cat > $D/90-mejoland-rendimiento.ini <<'INI'
; Mejoland: rendimiento GLPI / Nextcloud
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=256
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=20000
opcache.revalidate_freq=60
opcache.save_comments=1
apc.enabled=1
apc.enable_cli=1
apc.shm_size=128M
INI
done
echo "  OK (Apache y linea de comandos)"
systemctl reload apache2 2>/dev/null || systemctl restart apache2

paso "3 Nextcloud"
if [ -n "$NC" ]; then
  occ() { runuser -u www-data -- php "$NC/occ" "$@"; }
  occ config:system:set memcache.local --value '\OC\Memcache\APCu' >/dev/null \
  && occ config:system:set memcache.distributed --value '\OC\Memcache\Redis' >/dev/null \
  && occ config:system:set memcache.locking --value '\OC\Memcache\Redis' >/dev/null \
  && occ config:system:set redis host --value '127.0.0.1' >/dev/null \
  && occ config:system:set redis port --value 6379 --type integer >/dev/null \
  && occ config:system:set redis dbindex --value 0 --type integer >/dev/null \
  && echo "  Caches APCu + Redis: OK" \
  || { echo "  ERROR configurando caches: restaurando config.php"; cp -a $BK/nextcloud-config.php "$NC/config/config.php"; }
  occ background:cron >/dev/null && echo "  Tareas de fondo: cron del sistema"
  ( crontab -u www-data -l 2>/dev/null | grep -v "$NC/cron.php"; echo "*/5 * * * * php -f $NC/cron.php --define apc.enable_cli=1" ) | crontab -u www-data -
  occ status 2>&1 | grep -E "installed|version:|maintenance" | sed 's/^/  /'
else echo "  (no encontrado, se omite)"; fi

paso "4 GLPI"
if [ -n "$GL" ]; then
  if runuser -u www-data -- php "$GL/bin/console" cache:configure --dsn=redis://127.0.0.1:6379/1 --no-interaction >/tmp/glpi-cache.log 2>&1; then
    echo "  Cache de GLPI en Redis: OK"
  else
    echo "  AVISO: GLPI no acepto la cache Redis (sigue con su cache normal). Detalle:"; tail -3 /tmp/glpi-cache.log | sed 's/^/    /'
  fi
  runuser -u www-data -- php "$GL/bin/console" cache:clear --no-interaction >/dev/null 2>&1 || true
else echo "  (no encontrado, se omite)"; fi

systemctl reload apache2 2>/dev/null || systemctl restart apache2
paso "Medicion"
sleep 2; curl -s -o /dev/null http://127.0.0.1/glpi/; curl -s -o /dev/null -L http://127.0.0.1/nube/
echo "Despues:"; medir; medir
echo; echo "LISTO. Respaldo en $BK"
echo "Prueba ahora en el navegador (la primera carga calienta la cache; desde la segunda debe ir mas rapido)."
