#!/bin/bash
# =====================================================================
#  Mover la base de Zabbix a srv-monitoreo (ejecutar en srv-monitoreo, root)
#  Con la base remota en SRV-BD cada consulta tarda ~32 ms (pantallas y graficas lentas),
#  y su historial grande hace pesada la replica y los cambios de servidor de la alta disponibilidad.
#   1 Instala MariaDB local (solo escucha en este equipo)
#   2 Detiene zabbix-server (el monitoreo se pausa unos minutos; los agentes guardan y reenvian)
#   3 Copia la base desde SRV-BD y verifica tabla por tabla
#   4 Zabbix (servidor y web) pasa a usar la base local, con el mismo usuario y clave
#   5 Respaldo diario 03:10 de la configuracion de Zabbix (sin historial) en /root/respaldos-zabbix (7 dias)
#  La base en SRV-BD NO se borra. Vuelta atras: volver-a-srvbd.sh en la carpeta de respaldo.
#  Uso:  bash 03-mover-bd-zabbix.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
paso() { echo; echo "=================== $1 ==================="; }
SC=/etc/zabbix/zabbix_server.conf; WC=/etc/zabbix/web/zabbix.conf.php
[ -f $SC ] && [ -f $WC ] || { echo "No encuentro $SC o $WC"; exit 1; }
v() { sed -n "s/^$1=//p" $SC | tail -1; }
DBH=$(v DBHost); DBN=$(v DBName); DBU=$(v DBUser); DBP=$(v DBPassword); DBPORT=$(v DBPort)
DBN=${DBN:-zabbix}; DBU=${DBU:-zabbix}
echo "Base actual: '$DBN' en '${DBH:-localhost}' (usuario $DBU)"
[ -n "$DBH" ] && [ "$DBH" != localhost ] && [ "$DBH" != 127.0.0.1 ] || { echo "La base ya es local. No se cambio nada."; exit 1; }
[ -n "$DBP" ] || { echo "No encuentro DBPassword en $SC. No se cambio nada."; exit 1; }
TS=$(date +%Y%m%d-%H%M); BK=/root/proyecto/mover-bd-zabbix-$TS; S=/root/.mejoland; mkdir -p $BK $S; chmod 700 $BK $S
printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword="%s"\ndefault-character-set=utf8mb4\n' "$DBH" "${DBPORT:-3306}" "$DBU" "$DBP" > $S/remoto-zabbix.cnf; chmod 600 $S/remoto-zabbix.cnf
R="--defaults-extra-file=$S/remoto-zabbix.cnf"

paso "1 MariaDB local"
DEBIAN_FRONTEND=noninteractive apt-get install -y -q mariadb-server mariadb-client >/dev/null 2>&1 || { echo "  ERROR instalando MariaDB. No se cambio nada."; exit 1; }
RAM=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo); BP=$(( RAM / 4 )); [ $BP -lt 256 ] && BP=256
cat > /etc/mysql/mariadb.conf.d/60-mejoland-zabbix.cnf <<C
# Mejoland: base local de Zabbix
[mysqld]
bind-address                    = 127.0.0.1
innodb_buffer_pool_size         = ${BP}M
innodb_log_file_size            = 256M
innodb_flush_log_at_trx_commit  = 2
max_allowed_packet              = 64M
character-set-server            = utf8mb4
collation-server                = utf8mb4_bin
log_bin_trust_function_creators = 1
[client]
max_allowed_packet              = 64M
[mariadb-dump]
max_allowed_packet              = 64M
C
systemctl enable -q mariadb; systemctl restart mariadb || { echo "  ERROR: MariaDB no arranca"; exit 1; }
mariadb -e "SELECT 1" >/dev/null && echo "  MariaDB local: OK (buffer ${BP} MB)" || exit 1
mariadb $R -N -e "SELECT 1" "$DBN" >/dev/null || { echo "  ERROR: no conecto a la base de SRV-BD. No se cambio nada."; exit 1; }
MB=$(mariadb $R -N -e "SELECT ROUND(SUM(data_length+index_length)/1048576) FROM information_schema.tables WHERE table_schema='$DBN'")
echo "  Base en SRV-BD: ${MB} MB"
DUMP=$(command -v mariadb-dump || command -v mysqldump)

paso "2 Pausa del monitoreo"
cp -a $SC $BK/zabbix_server.conf; cp -a $WC $BK/zabbix.conf.php
cat > $BK/volver-a-srvbd.sh <<RB
#!/bin/bash
# Vuelve a usar la base de SRV-BD (lo guardado en la base local despues del cambio se pierde)
systemctl stop zabbix-server
cp -a $BK/zabbix_server.conf $SC; cp -a $BK/zabbix.conf.php $WC; chown --reference=$BK/zabbix.conf.php $WC
rm -f /etc/cron.d/respaldo-zabbix
systemctl start zabbix-server; systemctl reload apache2 2>/dev/null; echo "Listo: Zabbix vuelve a usar SRV-BD."
RB
chmod 700 $BK/volver-a-srvbd.sh
falla() { echo "  ERROR: $1"; echo "  Volviendo a como estaba..."; bash $BK/volver-a-srvbd.sh; exit 1; }
systemctl stop zabbix-server; echo "  zabbix-server detenido (los agentes guardan sus datos y los reenvian al volver)"

paso "3 Copia y verificacion (${MB} MB, puede tardar unos minutos)"
$DUMP $R --single-transaction --quick --skip-lock-tables --no-tablespaces --hex-blob --routines --triggers "$DBN" 2>$BK/dump.err | gzip > $BK/zabbix-desde-srvbd.sql.gz
[ "${PIPESTATUS[0]}" -eq 0 ] || { $DUMP $R --single-transaction --quick --skip-lock-tables --no-tablespaces --hex-blob --triggers "$DBN" 2>$BK/dump.err | gzip > $BK/zabbix-desde-srvbd.sql.gz; [ "${PIPESTATUS[0]}" -eq 0 ] || falla "no se pudo copiar ($(tail -1 $BK/dump.err))"; }
echo "  copia descargada: $(du -h $BK/zabbix-desde-srvbd.sql.gz | cut -f1) comprimida"
mariadb -e "DROP DATABASE IF EXISTS \`$DBN\`; CREATE DATABASE \`$DBN\` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
  CREATE USER IF NOT EXISTS '$DBU'@'localhost' IDENTIFIED BY '${DBP//\'/\'\'}'; ALTER USER '$DBU'@'localhost' IDENTIFIED BY '${DBP//\'/\'\'}';
  GRANT ALL PRIVILEGES ON \`$DBN\`.* TO '$DBU'@'localhost';" || falla "no se pudo crear la base local"
gunzip -c $BK/zabbix-desde-srvbd.sql.gz | mariadb "$DBN" || falla "no se pudo cargar la copia"
cuenta() { mariadb $1 -N -e "SELECT CONCAT('SELECT ''',table_name,''',COUNT(*) FROM \`',table_name,'\`') FROM information_schema.tables WHERE table_schema='$2' AND table_type='BASE TABLE' ORDER BY table_name" | sed 's/$/ UNION ALL/;$ s/ UNION ALL$//' | mariadb $1 -N "$2" 2>/dev/null; }
cuenta "$R" "$DBN" > $BK/remoto.txt; cuenta "" "$DBN" > $BK/local.txt
T=$(wc -l < $BK/local.txt)
if [ "$T" -gt 100 ] && diff -q $BK/remoto.txt $BK/local.txt >/dev/null; then echo "  $T tablas, filas identicas: OK"
else diff $BK/remoto.txt $BK/local.txt | head -5; falla "la copia no coincide"; fi

paso "4 Zabbix usa la base local"
sed -i -E 's/^DBHost=.*/DBHost=localhost/; /^DBPort=/d' $SC
sed -i -E "s/(\\\$DB\\['SERVER'\\][[:space:]]*=[[:space:]]*)'[^']*'/\1'localhost'/; s/(\\\$DB\\['PORT'\\][[:space:]]*=[[:space:]]*)'[^']*'/\1'0'/" $WC
grep -q "^DBHost=localhost" $SC && grep -q "\['SERVER'\].*'localhost'" $WC || falla "no se pudo cambiar la configuracion"
systemctl start zabbix-server || falla "zabbix-server no arranca"
systemctl reload apache2 2>/dev/null || systemctl restart apache2 2>/dev/null
sleep 8
systemctl is-active -q zabbix-server || falla "zabbix-server se detuvo (revisa /var/log/zabbix/zabbix_server.log)"
grep -iE "database is down|cannot connect" <(tail -30 /var/log/zabbix/zabbix_server.log) && falla "zabbix-server no conecta a la base local"
C=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/zabbix/index.php)
echo "  zabbix-server: activo   pagina: HTTP $C   tiempo: $(curl -o /dev/null -s -w '%{time_total}' http://127.0.0.1/zabbix/index.php) s"

paso "5 Respaldo diario de la configuracion"
cat > /usr/local/bin/respaldo-zabbix <<RZ
#!/bin/bash
# Configuracion de Zabbix (equipos, plantillas, alertas, usuarios, tableros), sin historial
D=/root/respaldos-zabbix; mkdir -p \$D; chmod 700 \$D; F=\$D/zabbix-config-\$(date +%Y%m%d-%H%M).sql.gz
IGN=\$(mariadb -N -e "SELECT CONCAT('--ignore-table=$DBN.',table_name) FROM information_schema.tables WHERE table_schema='$DBN' AND (table_name LIKE 'history%' OR table_name LIKE 'trends%' OR table_name IN ('events','event_recovery','problem','alerts','auditlog','sessions'))")
$DUMP --single-transaction --quick --hex-blob --triggers \$IGN "$DBN" | gzip > \$F && echo "\$(date '+%F %T') respaldo OK \$(du -h \$F | cut -f1)" || echo "\$(date '+%F %T') ERROR en el respaldo"
ls -1t \$D/zabbix-config-*.sql.gz | tail -n +8 | xargs -r rm -f
RZ
chmod 700 /usr/local/bin/respaldo-zabbix
echo "10 3 * * * root /usr/local/bin/respaldo-zabbix >> /var/log/respaldo-zabbix.log 2>&1" > /etc/cron.d/respaldo-zabbix
/usr/local/bin/respaldo-zabbix | sed 's/^/  /'
echo; echo "LISTO. Zabbix usa su base local. Si algo falla: bash $BK/volver-a-srvbd.sh"
