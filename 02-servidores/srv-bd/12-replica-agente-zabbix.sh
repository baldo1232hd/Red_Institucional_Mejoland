#!/bin/bash
# =====================================================================
#  Alerta de replica - PARTE 1 (ejecutar en SRV-BD y en damian-1, root)
#  Le ensena al agente de Zabbix a leer el estado de la replica MariaDB:
#    mejoland.replica[estado]  1 = funcionando   0 = DETENIDA
#                              2 = este equipo no replica (normal en el principal)
#                             -1 = el agente no puede consultar MariaDB
#    mejoland.replica[atraso]  segundos de atraso (-1 si no aplica)
#  Usuario MariaDB de solo lectura 'zbxmon'@'localhost' creado SIN binlog (solo en este equipo).
#  Uso:  bash 12-replica-agente-zabbix.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
if dpkg -s zabbix-agent2 >/dev/null 2>&1; then SVC=zabbix-agent2; CONF=/etc/zabbix/zabbix_agent2.conf; D=/etc/zabbix/zabbix_agent2.d
elif dpkg -s zabbix-agent >/dev/null 2>&1; then SVC=zabbix-agent; CONF=/etc/zabbix/zabbix_agentd.conf; D=/etc/zabbix/zabbix_agentd.conf.d
else echo "Este equipo no tiene agente de Zabbix. Ejecutar primero: bash 02-agente-zabbix-en-cada-servidor.sh (carpeta srv-monitoreo)"; exit 1; fi
systemctl is-active -q $SVC || { systemctl enable --now $SVC >/dev/null 2>&1; sleep 2; }
systemctl is-active -q $SVC || { echo "$SVC no arranca. Revisa: systemctl status $SVC"; exit 1; }
echo "Agente: $SVC"
C=/etc/zabbix/zbxmon.cnf
echo "== 1 Usuario de monitoreo en MariaDB (solo este equipo)"
if [ -f $C ]; then
  echo "  ya existe $C (se reutiliza)"
else
  P=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)
  mysql -e "SET SESSION sql_log_bin=0; CREATE USER IF NOT EXISTS 'zbxmon'@'localhost' IDENTIFIED BY '$P'; ALTER USER 'zbxmon'@'localhost' IDENTIFIED BY '$P'; GRANT SLAVE MONITOR ON *.* TO 'zbxmon'@'localhost';" 2>/dev/null \
  || mysql -e "SET SESSION sql_log_bin=0; CREATE USER IF NOT EXISTS 'zbxmon'@'localhost' IDENTIFIED BY '$P'; ALTER USER 'zbxmon'@'localhost' IDENTIFIED BY '$P'; GRANT REPLICATION CLIENT ON *.* TO 'zbxmon'@'localhost';" \
  || { echo "  ERROR creando el usuario"; exit 1; }
  printf '[client]\nuser=zbxmon\npassword=%s\nhost=localhost\n' "$P" > $C
  chown root:zabbix $C; chmod 640 $C
  echo "  usuario zbxmon creado (clave guardada en $C, no se muestra)"
fi

echo "== 2 Script que consulta la replica"
cat > /usr/local/bin/mejoland-replica <<'R'
#!/bin/bash
# Uso: mejoland-replica estado|atraso
S=$(mysql --defaults-extra-file=/etc/zabbix/zbxmon.cnf -e "SHOW SLAVE STATUS\G" 2>/dev/null) || { echo -1; exit 0; }
v() { echo "$S" | sed -n "s/^ *$1: //p" | head -1; }
case "${1:-estado}" in
  estado) if [ -z "$S" ]; then echo 2
          elif [ "$(v Slave_IO_Running)" = Yes ] && [ "$(v Slave_SQL_Running)" = Yes ]; then echo 1
          else echo 0; fi ;;
  atraso) a=$(v Seconds_Behind_Master); [[ "$a" =~ ^[0-9]+$ ]] && echo "$a" || echo -1 ;;
  *) echo -1 ;;
esac
R
chmod 755 /usr/local/bin/mejoland-replica

echo "== 3 Parametro del agente"
grep -qE "^Include=.*$(basename $D)" $CONF || echo "Include=$D/*.conf" >> $CONF
mkdir -p $D
echo 'UserParameter=mejoland.replica[*],/usr/local/bin/mejoland-replica $1' > $D/mejoland-replica.conf
systemctl restart $SVC; sleep 2
E=$(runuser -u zabbix -- /usr/local/bin/mejoland-replica estado); A=$(runuser -u zabbix -- /usr/local/bin/mejoland-replica atraso)
case $E in 1) T="funcionando";; 0) T="DETENIDA";; 2) T="este equipo no replica (normal en el principal)";; *) T="ERROR: el agente no puede leer MariaDB";; esac
echo "  estado = $E ($T)   atraso = $A s"
echo; echo "LISTO en $(hostname). Haz lo mismo en el otro servidor y luego la PARTE 2 en srv-monitoreo."
