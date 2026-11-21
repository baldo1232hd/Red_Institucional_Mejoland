#!/bin/bash
# =====================================================================
#  Replica MariaDB - PASO 2 (en damian-1, como root)
#  1. Detiene la replica.
#  2. Copia TODAS las bases de SRV-BD de forma consistente, con su posicion GTID.
#  3. Reanuda la replica desde ese punto exacto y comprueba que funcione.
#  Uso:  bash 01-replica-bd-damian.sh CLAVE_TEMPORAL
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
PRINCIPAL=100.89.203.22
CLAVE=${1:-}; [ -n "$CLAVE" ] || { echo "Uso: bash $0 CLAVE_TEMPORAL (la muestra el paso 1 en SRV-BD)"; exit 1; }
CNF=$(mktemp); chmod 600 "$CNF"; trap 'rm -f "$CNF"' EXIT
printf '[client]\nhost=%s\nuser=volcado\npassword=%s\n' "$PRINCIPAL" "$CLAVE" > "$CNF"
mysql --defaults-extra-file="$CNF" -N -e "SELECT 1" >/dev/null 2>&1 || { echo "No puedo conectarme a MariaDB de SRV-BD con el usuario volcado. Revisa la clave."; exit 1; }
DBS=$(mysql --defaults-extra-file="$CNF" -N -e "SHOW DATABASES" | grep -vE '^(mysql|information_schema|performance_schema|sys)$' | tr '\n' ' ')
echo "Bases a copiar: $DBS"

BK=/root/proyecto/replica-bd-$(date +%Y%m%d-%H%M); mkdir -p "$BK"; chmod 700 "$BK"
mysql -e "SHOW REPLICA STATUS\G" > "$BK/estado-antes.txt"
RO=$(mysql -N -e "SELECT @@read_only")

echo; echo "== 1 Detener la replica"
mysql -e "STOP REPLICA" ; mysql -e "SET GLOBAL read_only=0"

echo; echo "== 2 Copia consistente desde SRV-BD (puede tardar segun el tamano)"
T0=$(date +%s)
if ! mariadb-dump --defaults-extra-file="$CNF" --single-transaction --gtid --master-data=1 \
      --routines --triggers --events --databases $DBS 2>"$BK/volcado.err" | mysql; then
  echo "ERROR durante la copia:"; tail -5 "$BK/volcado.err"
  mysql -e "SET GLOBAL read_only=$RO"; exit 1
fi
echo "   Copia terminada en $(( $(date +%s) - T0 )) s"

echo; echo "== 3 Reanudar la replica desde la posicion de la copia"
mysql -e "SET GLOBAL read_only=$RO; START REPLICA"
sleep 5
mysql -e "SHOW REPLICA STATUS\G" | grep -E "Master_Host|IO_Running|SQL_Running:|Seconds_Behind|Using_Gtid|Gtid_IO_Pos|Last_.*Error:"
echo; echo "== Bases en damian-1:"; mysql -N -e "SHOW DATABASES" | grep -vE '^(information_schema|performance_schema|sys)$' | tr '\n' ' '; echo
echo
if mysql -e "SHOW REPLICA STATUS\G" | grep -q "Slave_SQL_Running: Yes"; then
  echo "LISTO: la replica MariaDB esta funcionando (IO y SQL en Yes)."
else
  echo "ATENCION: la replica no quedo en Yes. Revisar los errores mostrados arriba."
fi
echo "Ahora en SRV-BD:  bash 05-replica-bd-srvbd.sh --limpiar"
