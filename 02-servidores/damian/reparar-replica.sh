#!/bin/bash
# =====================================================================
#  Reparar la replica SRV-BD -> damian-1 (ejecutar SOLO en damian-1, root)
#  Caso: Slave_SQL_Running = No con "Operation ALTER USER failed for 'x'@'h'"
#  (el usuario existe en SRV-BD pero no en damian). Se crea ese usuario SOLO
#  en damian (sin binlog), copiando los permisos del mismo usuario en otro host,
#  y se reanuda la replica: el ALTER USER de SRV-BD le pone la misma clave.
#  No se salta ningun evento: damian queda identico a SRV-BD.
#  Uso:  bash reparar-replica.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
grep -q '^PRINCIPAL_TS=' /etc/mejoland-ha/ha.conf 2>/dev/null || { echo "Esto es solo para damian-1."; exit 1; }
st() { mysql -e "SHOW SLAVE STATUS\G" | sed -n "s/^ *$1: //p"; }
for i in $(seq 1 20); do
  sleep 2
  if [ "$(st Slave_SQL_Running)" = Yes ]; then echo "Replica funcionando."; break; fi
  ERR=$(st Last_SQL_Error)
  UH=$(echo "$ERR" | grep -oE "Operation [A-Z ]+ failed for '[^']+'@'[^']+'" | head -1 | grep -oE "'[^']+'@'[^']+'")
  if [ -z "$UH" ]; then echo "Error distinto, no lo toco. Mandame captura:"; echo "  $ERR"; exit 1; fi
  U=$(echo "$UH" | cut -d"'" -f2); H=$(echo "$UH" | cut -d"'" -f4)
  echo "Falta el usuario $U@$H en damian: creandolo (solo aqui)..."
  T=$(mysql -N -e "SELECT host FROM mysql.user WHERE user='$U' AND host<>'$H' LIMIT 1")
  if [ -n "$T" ]; then
    G=$(mysql -N -e "SHOW GRANTS FOR '$U'@'$T'" | grep -v "^GRANT USAGE ON \*\.\*" | sed "s/@\`$T\`/@\`$H\`/; s/@'$T'/@'$H'/" | sed 's/$/;/')
    echo "  permisos copiados de $U@$T"
  else
    G="GRANT ALL PRIVILEGES ON \`$U\`.* TO '$U'@'$H';"; echo "  sin plantilla: ALL en la base $U"
  fi
  mysql -e "SET SESSION sql_log_bin=0; CREATE USER IF NOT EXISTS '$U'@'$H'; $G" || { echo "No se pudo crear $U@$H"; exit 1; }
  mysql -e "START SLAVE"
done
sleep 3
echo; mysql -e "SHOW SLAVE STATUS\G" | grep -E "Slave_IO_Running:|Slave_SQL_Running:|Seconds_Behind|Last_SQL_Error"
echo -n "Tablas de la biblioteca en damian: "; mysql -N institucion -e "SHOW TABLES LIKE 'lms_bib%'" | tr '\n' ' '; echo
echo "Si aparecen las 2 tablas, la replica de la biblioteca esta completa."
