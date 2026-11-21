#!/bin/bash
# =====================================================================
#  Mover las bases de GLPI y Nextcloud a srv-apps (ejecutar en srv-apps, root)
#  Con la base remota en SRV-BD cada consulta tarda ~32 ms; con la base local, menos de 1 ms.
#   1 Instala MariaDB en srv-apps (solo escucha en este equipo)
#   2 Pone GLPI y Nextcloud en mantenimiento (~1-3 minutos sin servicio)
#   3 Copia las dos bases desde SRV-BD y VERIFICA tabla por tabla que coincidan
#   4 Cambia GLPI y Nextcloud para usar la base local (mismos usuarios y claves)
#   5 Respaldo automatico cada noche (02:40): copia local de 7 dias + la copia en SRV-BD se
#     actualiza (y por la replica llega a damian-1)
#  Las bases en SRV-BD NO se borran: quedan como respaldo. Vuelta atras: el script volver-a-srvbd.sh
#  que queda en la carpeta de respaldo.
#  Uso:  bash 04-mover-bd-apps.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
paso() { echo; echo "=================== $1 ==================="; }
NC=/var/www/nextcloud; GL=/var/www/glpi
[ -f $NC/occ ] && [ -f $GL/bin/console ] || { echo "No encuentro $NC/occ o $GL/bin/console"; exit 1; }
GCF=$(grep -ls "extends DBmysql" /etc/glpi/config_db.php $GL/config/config_db.php 2>/dev/null | head -1)
[ -n "$GCF" ] || { echo "No encuentro config_db.php de GLPI"; exit 1; }
occ() { runuser -u www-data -- php $NC/occ "$@"; }
TS=$(date +%Y%m%d-%H%M); BK=/root/proyecto/mover-bd-apps-$TS; S=/root/.mejoland; mkdir -p $BK $S; chmod 700 $BK $S

# --- Datos de conexion actuales (sin mostrarlos) ---
cat > $BK/leer-glpi.php <<'PHP'
<?php $s = file_get_contents($argv[1]);
foreach (['dbhost', 'dbuser', 'dbpassword', 'dbdefault', 'dbport'] as $k) {
  $v = preg_match('/\$' . $k . '\s*=\s*\'((?:[^\'\\\\]|\\\\.)*)\'/', $s, $m) ? stripslashes($m[1]) : '';
  if ($k === 'dbpassword') $v = rawurldecode($v);
  echo $v, "\n"; }
PHP
mapfile -t G < <(php $BK/leer-glpi.php "$GCF")
G_HOST=${G[0]}; G_USER=${G[1]}; G_PASS=${G[2]}; G_DB=${G[3]}; G_PORT=${G[4]:-}
N_HOST=$(occ config:system:get dbhost); N_USER=$(occ config:system:get dbuser); N_PASS=$(occ config:system:get dbpassword); N_DB=$(occ config:system:get dbname)
echo "GLPI:      base '$G_DB' en '$G_HOST' (usuario $G_USER)"
echo "Nextcloud: base '$N_DB' en '$N_HOST' (usuario $N_USER)"
for v in "$G_HOST" "$G_USER" "$G_PASS" "$G_DB" "$N_HOST" "$N_USER" "$N_PASS" "$N_DB"; do [ -n "$v" ] || { echo "No pude leer todos los datos de conexion. No se cambio nada."; exit 1; }; done
case "$G_HOST$N_HOST" in *localhost*|*127.0.0.1*) echo "Alguna base ya es local. No se cambio nada."; exit 1;; esac
rcnf() { local h=${1%%:*} p=3306; [[ "$1" == *:* ]] && p=${1##*:}; printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword="%s"\ndefault-character-set=utf8mb4\n' "$h" "$p" "$2" "$3"; }
rcnf "$G_HOST${G_PORT:+:$G_PORT}" "$G_USER" "$G_PASS" > $S/remoto-glpi.cnf
rcnf "$N_HOST" "$N_USER" "$N_PASS" > $S/remoto-nextcloud.cnf
chmod 600 $S/*.cnf
mariadb --defaults-extra-file=$S/remoto-glpi.cnf -e "SELECT 1" "$G_DB" >/dev/null 2>&1 || mysql --defaults-extra-file=$S/remoto-glpi.cnf -e "SELECT 1" "$G_DB" >/dev/null 2>&1 || true

paso "1 MariaDB local"
DEBIAN_FRONTEND=noninteractive apt-get install -y -q mariadb-server mariadb-client >/dev/null 2>&1 || { echo "  ERROR instalando MariaDB. No se cambio nada."; exit 1; }
cat > /etc/mysql/mariadb.conf.d/60-mejoland-apps.cnf <<'C'
# Mejoland: bases locales de GLPI y Nextcloud
[mysqld]
bind-address            = 127.0.0.1
innodb_buffer_pool_size = 768M
max_allowed_packet      = 64M
transaction_isolation   = READ-COMMITTED
character-set-server    = utf8mb4
collation-server        = utf8mb4_general_ci
[client]
max_allowed_packet      = 64M
[mariadb-dump]
max_allowed_packet      = 64M
C
systemctl enable -q mariadb; systemctl restart mariadb || { echo "  ERROR: MariaDB no arranca"; exit 1; }
mariadb -e "SELECT 1" >/dev/null && echo "  MariaDB local: OK" || exit 1
mariadb-dump --version >/dev/null 2>&1 && DUMP=mariadb-dump || DUMP=mysqldump
for c in G N; do
  cf=$([ $c = G ] && echo glpi || echo nextcloud); db=$([ $c = G ] && echo "$G_DB" || echo "$N_DB")
  mariadb --defaults-extra-file=$S/remoto-$cf.cnf -N -e "SELECT 1" "$db" >/dev/null || { echo "  ERROR: no conecto a la base remota de $cf. No se cambio nada."; exit 1; }
done
echo "  Conexion a las bases de SRV-BD: OK"

paso "2 Mantenimiento (GLPI y Nextcloud fuera de servicio unos minutos)"
cp -a "$GCF" $BK/config_db.php; cp -a $NC/config/config.php $BK/nextcloud-config.php
crontab -u www-data -l > $BK/crontab-www-data.txt 2>/dev/null || true
crontab -u www-data -r 2>/dev/null || true
occ maintenance:mode --on >/dev/null 2>&1
systemctl stop apache2
cat > $BK/volver-a-srvbd.sh <<R
#!/bin/bash
# Vuelve a usar las bases de SRV-BD (los cambios hechos en la base local despues del ultimo respaldo nocturno se pierden)
systemctl stop apache2
cp -a $BK/config_db.php "$GCF"; cp -a $BK/nextcloud-config.php $NC/config/config.php
chown www-data:www-data "$GCF" $NC/config/config.php
[ -s $BK/crontab-www-data.txt ] && crontab -u www-data $BK/crontab-www-data.txt
rm -f /etc/cron.d/respaldo-apps-bd
runuser -u www-data -- php $NC/occ maintenance:mode --off >/dev/null 2>&1
systemctl start apache2; echo "Listo: GLPI y Nextcloud vuelven a usar SRV-BD."
R
chmod 700 $BK/volver-a-srvbd.sh
falla() { echo "  ERROR: $1"; echo "  Volviendo a como estaba..."; bash $BK/volver-a-srvbd.sh; exit 1; }
echo "  Servicio detenido. Respaldo de configuracion en $BK"

paso "3 Copia y verificacion"
OPT="--single-transaction --quick --skip-lock-tables --no-tablespaces --hex-blob --routines --triggers --default-character-set=utf8mb4"
cuenta() { mariadb $1 -N -e "SELECT CONCAT('SELECT ''',table_name,''',COUNT(*) FROM \`',table_name,'\`') FROM information_schema.tables WHERE table_schema='$2' AND table_type='BASE TABLE' ORDER BY table_name" | paste -sd'\n' | sed 's/$/ UNION ALL/;$ s/ UNION ALL$//' | mariadb $1 -N "$2" 2>/dev/null; }
for app in glpi nextcloud; do
  if [ $app = glpi ]; then db=$G_DB; u=$G_USER; p=$G_PASS; else db=$N_DB; u=$N_USER; p=$N_PASS; fi
  R="--defaults-extra-file=$S/remoto-$app.cnf"
  echo "  $app: copiando..."
  $DUMP $R $OPT "$db" 2>$BK/$app-dump.err | gzip > $BK/$app-desde-srvbd.sql.gz
  [ "${PIPESTATUS[0]}" -eq 0 ] || { $DUMP $R ${OPT/--routines /} "$db" 2>$BK/$app-dump.err | gzip > $BK/$app-desde-srvbd.sql.gz; [ "${PIPESTATUS[0]}" -eq 0 ] || falla "no se pudo copiar $app ($(tail -1 $BK/$app-dump.err))"; }
  mariadb -e "DROP DATABASE IF EXISTS \`$db\`; CREATE DATABASE \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
    CREATE USER IF NOT EXISTS '$u'@'localhost' IDENTIFIED BY '${p//\'/\'\'}'; ALTER USER '$u'@'localhost' IDENTIFIED BY '${p//\'/\'\'}';
    GRANT ALL PRIVILEGES ON \`$db\`.* TO '$u'@'localhost';" || falla "no se pudo crear la base local $db"
  gunzip -c $BK/$app-desde-srvbd.sql.gz | mariadb "$db" || falla "no se pudo cargar $app en la base local"
  cuenta "$R" "$db" > $BK/$app-remoto.txt; cuenta "" "$db" > $BK/$app-local.txt
  T=$(wc -l < $BK/$app-local.txt)
  if [ "$T" -gt 0 ] && diff -q $BK/$app-remoto.txt $BK/$app-local.txt >/dev/null; then echo "  $app: $T tablas, filas identicas: OK"
  else diff $BK/$app-remoto.txt $BK/$app-local.txt | head -5; falla "la copia de $app no coincide"; fi
done
# GLPI usa las zonas horarias de MariaDB
mariadb-tzinfo-to-sql /usr/share/zoneinfo 2>/dev/null | mariadb mysql 2>/dev/null || mysql_tzinfo_to_sql /usr/share/zoneinfo 2>/dev/null | mariadb mysql 2>/dev/null
mariadb -e "GRANT SELECT ON mysql.time_zone_name TO '$G_USER'@'localhost'" 2>/dev/null

paso "4 GLPI y Nextcloud usan la base local"
sed -i -E "s/(\\\$dbhost[[:space:]]*=[[:space:]]*)'[^']*'/\1'localhost'/" "$GCF"
sed -i -E "s/(\\\$dbport[[:space:]]*=[[:space:]]*)'[^']*'/\1''/" "$GCF"
grep -q "dbhost *= *'localhost'" "$GCF" || falla "no se pudo cambiar config_db.php"
chown --reference=$BK/config_db.php "$GCF"; chmod --reference=$BK/config_db.php "$GCF"
occ config:system:set dbhost --value localhost >/dev/null || falla "no se pudo cambiar Nextcloud"
[ -s $BK/crontab-www-data.txt ] && crontab -u www-data $BK/crontab-www-data.txt
occ maintenance:mode --off >/dev/null
systemctl start apache2 || falla "Apache no arranca"
sleep 2
for i in 1 2; do curl -s -o /dev/null http://127.0.0.1/glpi/; curl -s -o /dev/null -L http://127.0.0.1/nube/; done
CG=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/glpi/); CN=$(curl -s -o /dev/null -L -w '%{http_code}' http://127.0.0.1/nube/)
[ "$CG" = 200 ] && [ "$CN" = 200 ] || falla "las paginas no responden bien (GLPI $CG, Nube $CN)"
occ status 2>&1 | grep -E "maintenance" | sed 's/^/  Nextcloud /'
printf '  Ahora:  GLPI %s s   Nube %s s\n' "$(curl -o /dev/null -s -w '%{time_total}' http://127.0.0.1/glpi/)" "$(curl -o /dev/null -s -L -w '%{time_total}' http://127.0.0.1/nube/)"

paso "5 Respaldo automatico cada noche"
cat > /usr/local/bin/respaldo-apps-bd <<RB
#!/bin/bash
# Respaldo de las bases de GLPI y Nextcloud: copia local (7 dias) y actualiza la copia en SRV-BD
D=/root/respaldos-apps; mkdir -p \$D; chmod 700 \$D; F=\$(date +%Y%m%d-%H%M)
for a in glpi:$G_DB nextcloud:$N_DB; do app=\${a%%:*}; db=\${a#*:}
  if $DUMP --single-transaction --quick --hex-blob --routines --triggers "\$db" | gzip > \$D/\$app-\$F.sql.gz && [ \${PIPESTATUS[0]} -eq 0 ]; then
    echo "\$(date '+%F %T') \$app: respaldo local OK"
    gunzip -c \$D/\$app-\$F.sql.gz | mariadb --defaults-extra-file=$S/remoto-\$app.cnf "\$db" \
      && echo "\$(date '+%F %T') \$app: copia en SRV-BD actualizada" || echo "\$(date '+%F %T') \$app: ERROR actualizando SRV-BD"
  else echo "\$(date '+%F %T') \$app: ERROR en el respaldo local"; fi
  ls -1t \$D/\$app-*.sql.gz | tail -n +8 | xargs -r rm -f
done
RB
chmod 700 /usr/local/bin/respaldo-apps-bd
echo "40 2 * * * root /usr/local/bin/respaldo-apps-bd >> /var/log/respaldo-apps-bd.log 2>&1" > /etc/cron.d/respaldo-apps-bd
echo "  Todos los dias 02:40 -> /root/respaldos-apps (7 dias) y copia en SRV-BD (llega a damian por la replica)"
echo "  Para hacerlo a mano: /usr/local/bin/respaldo-apps-bd"
rm -f $BK/leer-glpi.php
echo; echo "LISTO. GLPI y Nextcloud usan su base local."
echo "Si algo falla: bash $BK/volver-a-srvbd.sh"
