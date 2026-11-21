#!/bin/bash
# =====================================================================
#  CAMBIO DE CLAVES DE SERVICIO (ejecutar como root, en este orden y de forma consecutiva):
#     1 srv-bd   2 damian   3 correo   4 srv-aaa-1   5 srv-aaa-2   6 srv-apps   7 srv-monitoreo
#  El script detecta el servidor y cambia a la vez la clave en el servicio y en
#  cada archivo que la usa. Respaldo previo en /root/proyecto/claves-<fecha>/.
#  NO cambia: los secretos RADIUS de clients.conf (deben coincidir con los routers/AP del laboratorio),
#  root@localhost de MariaDB (entra por socket), ni las cuentas de personas creadas por secretaria.
#  Entre el servidor 1 y el 5, correo, RADIUS, GLPI y la nube no autentican: ejecutarlos seguidos.
#  Uso:  bash cambiar-claves.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
NEW=${CLAVE_NUEVA:-}   # se pide al ejecutar (o: CLAVE_NUEVA=... bash cambiar-claves.sh)
[ -n "$NEW" ] || { read -rsp "Nueva clave comun de servicios: " NEW; echo; }
[ ${#NEW} -ge 10 ] || { echo "La clave debe tener al menos 10 caracteres"; exit 1; }
BASE=dc=proyecto,dc=local; ADM=cn=admin,$BASE; LEC=cn=lector,$BASE
H=$(hostname); TS=$(date +%Y%m%d-%H%M%S); BK=/root/proyecto/claves-$TS; mkdir -p $BK; chmod 700 $BK
ok() { echo "  OK  $*"; }; mal() { echo "  ERROR  $*"; ERR=1; }; ERR=0
paso() { echo; echo "== $*"; }
bk() { for f in "$@"; do [ -e "$f" ] && cp -a "$f" "$BK/$(echo "$f" | tr / _)"; done; }
# cambia el valor de una linea clave=valor (conserva comillas si las tenia)
fija() { # archivo  regex-de-la-clave  (ej: '^DB_PASSWORD=')
  local f=$1 k=$2
  [ -f "$f" ] || return 1
  python3 - "$f" "$k" "$NEW" <<'PY'
import re, sys
f, k, new = sys.argv[1:4]
s = open(f).read(); n = 0
def r(m):
    global n; n += 1
    q = m.group(2) or ''
    return m.group(1) + q + new + q
s2 = re.sub(r'(' + k + r'[ \t]*)(["\']?)[^"\'\n]*\2', r, s, flags=re.M)
open(f, 'w').write(s2); print(n)
PY
}
sql_claves() { # usuarios...  -> ALTER en este servidor SIN binlog (cada servidor se cambia por separado)
  local u h
  for u in "$@"; do
    for h in $(mysql -N -e "SELECT host FROM mysql.user WHERE user='$u'"); do
      mysql -e "SET SESSION sql_log_bin=0; ALTER USER '$u'@'$h' IDENTIFIED BY '$NEW';" && ok "MariaDB $u@$h" || mal "MariaDB $u@$h"
    done
  done
}
sistema() { # usuarios del sistema con clave
  for u in $(awk -F: '$2 ~ /^\$/ {print $1}' /etc/shadow); do echo "$u:$NEW" | chpasswd && ok "usuario del sistema $u"; done
}
ha_pausa() { systemctl list-timers --all --no-legend 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^mejoland-ha.*\.timer$/) print $i}' | sort -u; }

echo "Servidor: $H   Nueva clave para todo: $NEW"
read -r -p "Escribe SI para continuar: " R; [ "$R" = SI ] || { echo "Cancelado."; exit 1; }

if systemctl is-active -q slapd && [ -f /var/www/lms-backend/.env ]; then
  # ======================= SRV-BD o damian =======================
  SYNC=$(ldapsearch -LLL -o ldif-wrap=no -Y EXTERNAL -H ldapi:/// -b cn=config "(olcSyncrepl=*)" olcSyncrepl 2>/dev/null | sed -n 's/^olcSyncrepl: //p')
  DBDN=$(ldapsearch -LLL -Y EXTERNAL -H ldapi:/// -b cn=config "(olcSuffix=$BASE)" dn 2>/dev/null | sed -n 's/^dn: //p')
  TIM=$(ha_pausa); [ -n "$TIM" ] && { systemctl stop $TIM; ok "vigilante HA en pausa ($TIM)"; }
  bk /var/www/lms-backend/.env /etc/mejoland-ha/monitor.cnf /etc/mejoland-ha/sync.cnf /etc/zabbix/zbxmon.cnf
  slapcat -n 0 > $BK/cn-config.ldif 2>/dev/null
  HASH=$(slappasswd -s "$NEW")

  paso "LDAP: clave del administrador (olcRootPW)"
  printf 'dn: %s\nchangetype: modify\nreplace: olcRootPW\nolcRootPW: %s\n' "$DBDN" "$HASH" | ldapmodify -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1 \
    && ok "$ADM" || mal "olcRootPW"

  if [ -z "$SYNC" ]; then
    paso "LDAP: cuentas (se replican solas a damian)"
    for dn in "$ADM" "$LEC" "cn=svc-secretaria,$BASE" $(ldapsearch -LLL -x -H ldap://127.0.0.1 -D "$ADM" -w "$NEW" -b "$BASE" "(|(uid=acabezas)(uid=dlara))" dn 2>/dev/null | sed -n 's/^dn: //p'); do
      ldapsearch -LLL -x -H ldap://127.0.0.1 -D "$ADM" -w "$NEW" -b "$dn" -s base dn >/dev/null 2>&1 || continue
      ldappasswd -x -H ldap://127.0.0.1 -D "$ADM" -w "$NEW" -s "$NEW" "$dn" >/dev/null 2>&1 && ok "$dn" || mal "$dn"
    done
    ldapwhoami -x -H ldap://127.0.0.1 -D "$LEC" -w "$NEW" >/dev/null 2>&1 && ok "cn=lector entra con la nueva clave" || mal "cn=lector no entra"
  else
    paso "LDAP (damian): credenciales de la replica hacia SRV-BD"
    NS=$(echo "$SYNC" | sed -E "s/credentials=(\"[^\"]*\"|[^ ]+)/credentials=\"$NEW\"/")
    printf 'dn: %s\nchangetype: modify\nreplace: olcSyncrepl\nolcSyncrepl: %s\n' "$DBDN" "$NS" | ldapmodify -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1 \
      && ok "olcSyncrepl actualizado" || mal "olcSyncrepl"
    sleep 8
    ldapwhoami -x -H ldap://127.0.0.1 -D "$LEC" -w "$NEW" >/dev/null 2>&1 && ok "la replica LDAP ya trae la nueva clave de cn=lector" \
      || echo "  AVISO  la replica LDAP aun no trae la clave nueva (reintenta: ldapwhoami -x -H ldap://127.0.0.1 -D $LEC -w '$NEW')"
  fi

  paso "MariaDB (cada servidor por separado, sin pasar por la replica)"
  sql_claves lms ha_monitor ha_sync zbxmon glpi nextcloud zabbix radius repl replica replicator roundcube app_institucion cups_log
  if [ -n "$SYNC" ]; then
    mysql -e "STOP SLAVE; CHANGE MASTER TO MASTER_PASSWORD='$NEW'; START SLAVE;" && ok "replica MariaDB con la nueva clave de repl"
  fi

  paso "Archivos"
  echo "  .env DB_PASSWORD: $(fija /var/www/lms-backend/.env '^DB_PASSWORD=')  LDAP_BIND_PASSWORD: $(fija /var/www/lms-backend/.env '^LDAP_BIND_PASSWORD=')"
  for f in /etc/mejoland-ha/monitor.cnf /etc/mejoland-ha/sync.cnf /etc/zabbix/zbxmon.cnf; do echo "  $f: $(fija $f '^password[ \t]*=' 2>/dev/null || echo no-existe)"; done
  systemctl is-active -q lms && { systemctl restart lms; sleep 3; echo -n "  EduNova: "; curl -s -o /dev/null -w "%{http_code} (esperado 200)\n" http://127.0.0.1:3001/; }
  mysql -u lms -p"$NEW" -h 127.0.0.1 -e "SELECT 1" >/dev/null 2>&1 && ok "lms entra a MariaDB" || mal "lms no entra a MariaDB"

  if [ -n "$SYNC" ]; then
    sleep 3; mysql -e "SHOW SLAVE STATUS\G" | grep -E "Slave_IO_Running:|Slave_SQL_Running:|Last_IO_Error:" | sed 's/^ */  /'
    grep -q ha_monitor /etc/mejoland-ha/monitor.cnf 2>/dev/null; mysql --defaults-extra-file=/etc/mejoland-ha/monitor.cnf -h 100.89.203.22 -e "SELECT 1" >/dev/null 2>&1 && ok "damian ve a SRV-BD con ha_monitor" || mal "ha_monitor hacia SRV-BD"
  fi
  [ -n "$TIM" ] && { systemctl start $TIM; ok "vigilante HA reanudado"; }
  echo; grep -nE "getenv|file_get_contents|parse_ini|SVC_|secret" /var/www/secretaria/index.php 2>/dev/null | sed -E 's/=.*/= ****/' | head -5 | sed 's/^/  (panel secretaria) /'

elif systemctl is-active -q postfix; then
  # ======================= correo =======================
  bk /etc/postfix/ldap-usuarios.cf /etc/dovecot/local.conf
  paso "Postfix y Dovecot (cn=lector)"
  echo "  postfix bind_pw: $(fija /etc/postfix/ldap-usuarios.cf '^bind_pw[ \t]*=')"
  echo "  dovecot: $(fija /etc/dovecot/local.conf '^[ \t]*(ldap_auth_dn_password|dnpass)[ \t]*=')"
  systemctl reload postfix; systemctl restart dovecot
  postmap -q "acabezas@mejoland.edu.ec" ldap:/etc/postfix/ldap-usuarios.cf >/dev/null && ok "Postfix encuentra usuarios en LDAP" || mal "Postfix no consulta LDAP (revisa bind_pw)"
  doveadm auth test acabezas "$NEW" 2>&1 | grep -q "succeeded" && ok "Dovecot: acabezas entra con la nueva clave" || mal "Dovecot no autentica a acabezas"

elif systemctl is-active -q freeradius; then
  # ======================= srv-aaa-1 / srv-aaa-2 =======================
  L=$(readlink -f /etc/freeradius/3.0/mods-enabled/ldap); S=$(readlink -f /etc/freeradius/3.0/mods-enabled/sql)
  bk "$L" "$S"
  paso "FreeRADIUS: LDAP (cn=lector) y SQL (radius)"
  echo "  ldap: $(fija "$L" '^[ \t]*password[ \t]*=')   sql: $(fija "$S" '^[ \t]*password[ \t]*=')"
  if freeradius -XC >$BK/check.log 2>&1; then systemctl restart freeradius; ok "configuracion valida, FreeRADIUS reiniciado"
  else mal "configuracion invalida: restaurando"; cp -a "$BK/$(echo "$L" | tr / _)" "$L"; cp -a "$BK/$(echo "$S" | tr / _)" "$S"; fi
  radtest acabezas "$NEW" 127.0.0.1 0 testing123 2>/dev/null | grep -q Access-Accept && ok "radtest acabezas: Access-Accept" \
    || echo "  (prueba radtest con el secreto de localhost:  radtest acabezas '$NEW' 127.0.0.1 0 <secreto>)"

elif [ -f /var/www/glpi/config/config_db.php ]; then
  # ======================= srv-apps =======================
  NC=/var/www/nextcloud; occ() { runuser -u www-data -- php $NC/occ "$@"; }
  bk /var/www/glpi/config/config_db.php $NC/config/config.php /root/.mejoland/remoto-glpi.cnf /root/.mejoland/remoto-nextcloud.cnf
  paso "Bases locales de GLPI y Nextcloud"
  sql_claves glpi nextcloud
  echo "  config_db.php: $(fija /var/www/glpi/config/config_db.php 'public \$dbpassword = ')"
  occ config:system:set dbpassword --value "$NEW" >/dev/null && ok "Nextcloud dbpassword"
  for f in /root/.mejoland/remoto-glpi.cnf /root/.mejoland/remoto-nextcloud.cnf; do echo "  $f: $(fija $f '^password[ \t]*=')"; done
  paso "Nextcloud: LDAP (cn=lector) y administradores"
  for c in $(occ ldap:show-config --output=json 2>/dev/null | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin).keys()))' 2>/dev/null); do
    occ ldap:set-config "$c" ldapAgentPassword "$NEW" >/dev/null && ok "LDAP de Nextcloud ($c)"; done
  for u in $(occ group:list --output=json 2>/dev/null | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin).get("admin",[])))' 2>/dev/null); do
    OC_PASS="$NEW" runuser -u www-data -- env OC_PASS="$NEW" php $NC/occ user:resetpassword --password-from-env "$u" >/dev/null 2>&1 && ok "admin de Nextcloud: $u"; done
  paso "GLPI: cuenta glpi y cuentas de fabrica"
  HG=$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$NEW")
  GDB=$(sed -n "s/.*dbdefault *= *'\([^']*\)'.*/\1/p" /var/www/glpi/config/config_db.php); GDB=${GDB:-glpi}
  mysql "$GDB" -e "UPDATE glpi_users SET password='$HG' WHERE name='glpi'; UPDATE glpi_users SET is_active=0 WHERE name IN ('tech','normal','post-only');" \
    && ok "glpi con la nueva clave; tech, normal y post-only desactivadas"
  systemctl reload apache2
  for p in glpi nube; do echo -n "  $p: "; curl -s -o /dev/null -L -w "%{http_code}\n" http://127.0.0.1/$p/; done
  echo "  FALTA a mano en GLPI: Configuracion > Autenticacion > Directorios LDAP > LDAP Mejoland > contrasena del usuario cn=lector"

elif systemctl is-active -q zabbix-server; then
  # ======================= srv-monitoreo =======================
  bk /etc/zabbix/zabbix_server.conf /etc/zabbix/web/zabbix.conf.php /root/.mejoland/remoto-zabbix.cnf
  paso "Zabbix: base local y usuario Admin"
  sql_claves zabbix
  echo "  zabbix_server.conf: $(fija /etc/zabbix/zabbix_server.conf '^DBPassword=')   web: $(fija /etc/zabbix/web/zabbix.conf.php "\\\$DB\\['PASSWORD'\\] = ")   remoto: $(fija /root/.mejoland/remoto-zabbix.cnf '^password=' 2>/dev/null)"
  HZ=$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "$NEW")
  mysql zabbix -e "UPDATE users SET passwd='$HZ' WHERE username='Admin';" && ok "Admin de Zabbix"
  systemctl restart zabbix-server; sleep 5
  systemctl is-active -q zabbix-server && ! tail -20 /var/log/zabbix/zabbix_server.log | grep -qi "access denied" && ok "zabbix-server conecta a su base" || mal "zabbix-server (revisa /var/log/zabbix/zabbix_server.log)"
  systemctl reload apache2
fi

paso "Usuarios del sistema (SSH, sudo, su)"
sistema
echo; [ $ERR = 0 ] && echo "LISTO en $H sin errores." || echo "TERMINO en $H CON ERRORES (arriba). Respaldo de archivos: $BK"
echo "Respaldo: $BK"
