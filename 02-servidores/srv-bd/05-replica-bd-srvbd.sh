#!/bin/bash
# =====================================================================
#  Replica MariaDB - PASO 1 (en SRV-BD, como root)
#  Crea un usuario TEMPORAL "volcado" (solo lectura) para que damian-1 copie
#  las bases una vez. No reinicia MariaDB ni toca la replicacion existente.
#  Uso:          bash 05-replica-bd-srvbd.sh
#  Al terminar:  bash 05-replica-bd-srvbd.sh --limpiar   (borra el usuario temporal)
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
REPLICA=100.93.52.67
if [ "${1:-}" = "--limpiar" ]; then
  mysql -e "DROP USER IF EXISTS 'volcado'@'$REPLICA'" && echo "Usuario temporal 'volcado' eliminado."
  rm -f /root/proyecto/volcado-clave.txt; exit 0
fi
[ "$(mysql -N -e 'SELECT @@log_bin')" = "1" ] || { echo "El registro binario (log_bin) no esta activo. No se cambio nada."; exit 1; }

echo "== Bases que se copiaran a damian-1 (tamano aproximado)"
mysql -N -e "SELECT table_schema, CONCAT(ROUND(SUM(data_length+index_length)/1024/1024,1),' MB')
  FROM information_schema.tables WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys')
  GROUP BY table_schema ORDER BY table_schema" | awk '{printf "   %-18s %s %s\n",$1,$2,$3}'
echo "   Total: $(mysql -N -e "SELECT CONCAT(ROUND(SUM(data_length+index_length)/1024/1024,1),' MB') FROM information_schema.tables WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys')")"

# Usuario de replicacion para damian (clave CLAVE_BD_REPL generada por 01-configurar-srv-bd.sh)
. /root/proyecto/claves.txt 2>/dev/null || true
if [ -n "${CLAVE_BD_REPL:-}" ]; then
  mysql -e "CREATE USER IF NOT EXISTS 'repl'@'$REPLICA' IDENTIFIED BY '$CLAVE_BD_REPL';
    GRANT REPLICATION SLAVE, SLAVE MONITOR ON *.* TO 'repl'@'$REPLICA';" && echo "== Usuario repl@$REPLICA listo"
fi

CLAVE=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
mysql -e "DROP USER IF EXISTS 'volcado'@'$REPLICA';
  CREATE USER 'volcado'@'$REPLICA' IDENTIFIED BY '$CLAVE';
  GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES, RELOAD, BINLOG MONITOR, PROCESS ON *.* TO 'volcado'@'$REPLICA';" \
  || { echo "ERROR creando el usuario temporal."; exit 1; }
mkdir -p /root/proyecto; umask 077; echo "$CLAVE" > /root/proyecto/volcado-clave.txt
echo
echo "== Usuario temporal creado: volcado@$REPLICA (solo lectura, solo desde damian-1)"
echo "   Clave temporal: $CLAVE"
echo
echo "AHORA, en damian (como root):  bash 01-replica-bd-damian.sh $CLAVE"
echo "Al terminar, en SRV-BD:  bash 05-replica-bd-srvbd.sh --limpiar"
