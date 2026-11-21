#!/bin/bash
# =====================================================================
#  MAC - SRV-MONITOREO (root): Zabbix 7.0 LTS con su base en SRV-BD
#  - Nombres de Tailscale en /etc/hosts (mismo esquema que los demas)
#  - Repositorio oficial de Zabbix para Debian 13
#  - Zabbix server + pagina web (Apache) + agente propio
#  - Base "zabbix" en el MariaDB de SRV-BD (se replica sola a damian-1)
#  ANTES, en SRV-BD (root):  mysql -e "SET GLOBAL log_bin_trust_function_creators=1"
#  Uso:  bash 01-instalar-srv-monitoreo.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root (sudo -i)"; exit 1; }
paso() { echo; echo "=================== $1 ==================="; }
DBH=srv-bd.proyecto.local; DBN=zabbix; DBU=zabbix
BK=/root/proyecto/monitoreo-$(date +%Y%m%d-%H%M); mkdir -p $BK; chmod 700 $BK

paso "1 Nombres (Tailscale)"
cp -a /etc/hosts $BK/hosts
sed -i '/# >>> TAILSCALE/,/# <<< TAILSCALE/d' /etc/hosts
cat >> /etc/hosts <<'H'
# >>> TAILSCALE (solo en casa)
100.89.203.22   srv-bd.proyecto.local srv-bd
100.93.52.67    srv-bd-replica.proyecto.local srv-bd-replica
100.65.119.48   correo.proyecto.local correo
100.75.163.23   srv-aaa-1.proyecto.local srv-aaa-1
100.74.49.76    srv-aaa-2.proyecto.local srv-aaa-2
100.107.96.3    srv-apps.proyecto.local srv-apps
# <<< TAILSCALE
H
timeout 3 bash -c "</dev/tcp/$DBH/3306" 2>/dev/null && echo "  MariaDB de SRV-BD: OK" || { echo "  MariaDB de SRV-BD no responde en 3306. No se cambio nada mas."; exit 1; }

paso "2 Clave de la base zabbix"
apt-get install -y -q mariadb-client curl >/dev/null
read -rsp "  Clave del usuario zabbix de MariaDB (esta en /root/proyecto/claves.txt de SRV-BD): " PW; echo
CNF=$(mktemp); chmod 600 $CNF; trap 'rm -f $CNF' EXIT
printf '[client]\nhost=%s\nuser=%s\npassword=%s\ndefault-character-set=utf8mb4\n' "$DBH" "$DBU" "$PW" > $CNF
M() { mysql --defaults-extra-file=$CNF "$@"; }
M -N -e "SELECT 1" $DBN >/dev/null 2>&1 || { echo "  ERROR: esa clave no entra a la base zabbix en SRV-BD."; exit 1; }
echo "  Acceso a la base zabbix: OK"

paso "3 Repositorio y paquetes de Zabbix 7.0"
if ! dpkg -l zabbix-release >/dev/null 2>&1; then
  curl -fsSL -o /tmp/zabbix-release.deb https://repo.zabbix.com/zabbix/7.0/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.0+debian13_all.deb \
    || { echo "  ERROR descargando el repositorio de Zabbix"; exit 1; }
  dpkg -i /tmp/zabbix-release.deb >/dev/null
fi
apt-get update -q >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get install -y -q zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent2 php-mysql locales >/dev/null \
  || { echo "  ERROR instalando Zabbix"; exit 1; }
sed -i 's/^# *es_ES.UTF-8/es_ES.UTF-8/' /etc/locale.gen; locale-gen >/dev/null 2>&1
echo "  $(zabbix_server -V | head -1)"

paso "4 Tablas en SRV-BD"
N=$(M -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DBN'")
if [ "$N" -gt 0 ]; then
  echo "  La base ya tiene $N tablas: se conservan (no se importa de nuevo)."
else
  [ "$(M -N -e 'SELECT @@log_bin_trust_function_creators')" = "1" ] || {
    echo "  Falta en SRV-BD (root):  mysql -e \"SET GLOBAL log_bin_trust_function_creators=1\""
    echo "  Hazlo y vuelve a ejecutar este script."; exit 1; }
  M -e "ALTER DATABASE $DBN CHARACTER SET utf8mb4 COLLATE utf8mb4_bin" 2>/dev/null
  echo "  Importando el esquema de Zabbix (unos minutos)..."
  zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz | M $DBN || { echo "  ERROR importando el esquema"; exit 1; }
  echo "  Tablas creadas: $(M -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DBN'")"
  echo "  >>> Ahora en SRV-BD (root):  mysql -e \"SET GLOBAL log_bin_trust_function_creators=0\""
fi

paso "5 Configuracion"
C=/etc/zabbix/zabbix_server.conf; cp -a $C $BK/
for kv in "DBHost=$DBH" "DBName=$DBN" "DBUser=$DBU" "DBPassword=$PW"; do
  k=${kv%%=*}; sed -i "/^#\? *$k=/d" $C; echo "$kv" >> $C
done
chmod 640 $C; chown root:zabbix $C
W=/etc/zabbix/web/zabbix.conf.php
cat > $W <<P
<?php
\$DB['TYPE'] = 'MYSQL'; \$DB['SERVER'] = '$DBH'; \$DB['PORT'] = '0';
\$DB['DATABASE'] = '$DBN'; \$DB['USER'] = '$DBU'; \$DB['PASSWORD'] = '$PW';
\$DB['SCHEMA'] = ''; \$DB['ENCRYPTION'] = false; \$DB['KEY_FILE'] = ''; \$DB['CERT_FILE'] = '';
\$DB['CA_FILE'] = ''; \$DB['VERIFY_HOST'] = false; \$DB['CIPHER_LIST'] = ''; \$DB['VAULT'] = '';
\$DB['VAULT_URL'] = ''; \$DB['VAULT_DB_PATH'] = ''; \$DB['VAULT_TOKEN'] = ''; \$DB['VAULT_CERT_FILE'] = '';
\$DB['VAULT_KEY_FILE'] = ''; \$DB['DOUBLE_IEEE754'] = true;
\$ZBX_SERVER_NAME = 'Centro Educativo Mejoland';
\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
P
chown www-data:www-data $W; chmod 640 $W
A=/etc/zabbix/zabbix_agent2.conf; cp -a $A $BK/
sed -i 's/^Hostname=.*/Hostname=srv-monitoreo/' $A
unset PW
echo "  Servidor, pagina web y agente configurados"

paso "6 Arranque"
systemctl enable zabbix-server zabbix-agent2 apache2 >/dev/null 2>&1
systemctl restart zabbix-server zabbix-agent2 apache2; sleep 5
for s in zabbix-server zabbix-agent2 apache2; do printf '  %-14s %s\n' $s "$(systemctl is-active $s)"; done
echo -n "  Pagina web: "; curl -s -o /dev/null -w "%{http_code} (esperado 200)\n" http://127.0.0.1/zabbix/
grep -iE "cannot|error" /var/log/zabbix/zabbix_server.log | tail -3 | sed 's/^/  /'
IP=$(tailscale ip -4 2>/dev/null | head -1)
echo
echo "LISTO. Abre  http://$IP/zabbix/   usuario Admin, clave zabbix  -> CAMBIALA al entrar."
echo "Respaldo de la configuracion original en $BK"
