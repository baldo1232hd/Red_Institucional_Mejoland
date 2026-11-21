#!/bin/bash
# =====================================================================
#  INVENTARIO DE CLAVES (solo lectura, ejecutar como root en cada servidor)
#  Lista donde hay usuarios y claves configurados, para cambiarlos sin afectar los servicios.
#  No muestra ninguna clave: los valores salen como ****.
#  Uso:  bash inventario-claves.sh
# =====================================================================
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
m() { sed -E 's/((pass(word)?|passwd|pw|secret|bindpw|credentials|dbpassword|db_password|password_hash)[^=:]*[=:][[:space:]]*["'"'"']?)[^"'"'"'[:space:],;)]+/\1****/Ig; s#(mysql://[^:]+:)[^@]+@#\1****@#g; s#(credentials=)[^ ]+#\1****#g'; }
echo "################ $(hostname) ($(hostname -I | tr ' ' '\n' | grep -E '^100\.' | head -1)) ################"
echo; echo "== Usuarios del sistema con clave"
awk -F: '$2 ~ /^\$/ {print "  " $1}' /etc/shadow
echo; echo "== Servicios activos relevantes"
for s in mariadb slapd lms apache2 nginx postfix dovecot freeradius zabbix-server zabbix-agent zabbix-agent2 redis-server named bind9 cups; do systemctl is-active -q $s 2>/dev/null && printf '  %s' $s; done; echo
if command -v mysql >/dev/null && mysql -e "SELECT 1" >/dev/null 2>&1; then
  echo; echo "== MariaDB: usuarios"
  mysql -N -e "SELECT CONCAT('  ',user,'@',host,'  (',IF(plugin='' OR plugin='mysql_native_password','clave',plugin),')') FROM mysql.user WHERE user<>'' ORDER BY user,host"
  echo "== MariaDB: bases"; mysql -N -e "SHOW DATABASES" | grep -vE '^(mysql|information_schema|performance_schema|sys)$' | sed 's/^/  /' | paste -sd' '
  mysql -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep -E "Master_Host|Master_User" | sed 's/^ */  replica: /'
fi
if command -v ldapsearch >/dev/null && systemctl is-active -q slapd; then
  echo; echo "== OpenLDAP (cn=config)"
  ldapsearch -LLL -Y EXTERNAL -H ldapi:/// -b cn=config "(|(olcRootDN=*)(olcSyncrepl=*))" olcSuffix olcRootDN olcSyncrepl 2>/dev/null | m | sed 's/^/  /' | grep -vE '^  dn: (cn=config|olcDatabase=\{0\}config)'
  echo "== OpenLDAP: cuentas de servicio y administradores"
  B=$(ldapsearch -LLL -Y EXTERNAL -H ldapi:/// -b cn=config "(olcSuffix=*)" olcSuffix 2>/dev/null | sed -n 's/^olcSuffix: //p' | head -1)
  ldapsearch -LLL -Y EXTERNAL -H ldapi:/// -b "$B" "(&(userPassword=*)(!(objectClass=posixAccount)))" dn 2>/dev/null | sed -n 's/^dn: /  /p'
  echo "  cuentas de personas con clave: $(ldapsearch -LLL -Y EXTERNAL -H ldapi:/// -b "$B" "(&(userPassword=*)(objectClass=posixAccount))" dn 2>/dev/null | grep -c '^dn:')"
fi
echo; echo "== Archivos con usuarios/claves (valores ocultos)"
P="(cn=lector|cn=admin,dc=|cn=radius|cn=roundcube|bind_?dn|bindpw|ldap_bind|dn *=|DB_PASSWORD|DB_USER|DBPassword|DBUser|db_dsnw|password *=|passwd *=|\\\$DB\\['(USER|PASSWORD)'\\]|dbuser|dbpassword|LDAP_BIND|identity *=|secret *=)"
for f in /var/www/lms-backend/.env /etc/postfix/*.cf /etc/postfix/ldap* /etc/dovecot/dovecot-ldap*.conf* /etc/dovecot/conf.d/*ldap* /etc/dovecot/conf.d/auth-* \
         /etc/roundcube/config.inc.php /etc/freeradius/3.0/mods-enabled/ldap /etc/freeradius/3.0/mods-enabled/sql /etc/freeradius/3.0/clients.conf \
         /etc/zabbix/zabbix_server.conf /etc/zabbix/web/zabbix.conf.php /etc/zabbix/zbxmon.cnf /var/www/glpi/config/config_db.php /etc/glpi/config_db.php \
         /var/www/nextcloud/config/config.php /etc/mejoland-ha/*.cnf /etc/mejoland-ha/ha.conf /root/.mejoland/*.cnf /root/.my.cnf /etc/mysql/debian.cnf \
         /etc/nslcd.conf /etc/sssd/sssd.conf /etc/ldap/ldap.conf /etc/edunova/*.json /etc/lam/*.conf /usr/share/ldap-account-manager/config/*.conf \
         /var/www/html/*/config*.php /var/www/html/*/*.env /var/www/secretaria/*.php /etc/oxidized/config /root/proyecto/claves*.txt; do
  [ -f "$f" ] || continue
  L=$(grep -niE "$P" "$f" 2>/dev/null | grep -v '^\s*#' | head -8)
  [ -n "$L" ] && { echo "  -- $f"; echo "$L" | m | cut -c1-150 | sed 's/^/     /'; }
done
echo; echo "== Otras referencias a cn=lector / cn=admin en /etc y /var/www (solo nombres de archivo)"
grep -rlsE "cn=lector|cn=admin,dc=proyecto" /etc /var/www 2>/dev/null | grep -vE '\.(bak|orig|dpkg-old)|/backup|ldap/slapd.d' | head -25 | sed 's/^/  /'
echo; echo "== Fin de $(hostname)"
