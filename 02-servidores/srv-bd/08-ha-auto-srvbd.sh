#!/bin/bash
# =====================================================================
#  HA AUTOMATICO - PASO 1 (SRV-BD, root)
#  Configura el regreso automatico del servicio al servidor principal. Crea el usuario ha_sync
#  y la tabla de estado mejoland_ha. No toca OpenLDAP ni las ACL.
#  Uso: bash 08-ha-auto-srvbd.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
C=/etc/mejoland-ha/ha.conf
[ -f $C ] || { echo "No existe $C: primero hay que tener instalado el failover (v1)."; exit 1; }
. $C
RESP=${RESPALDO_TS:-100.93.52.67}
BK=/root/proyecto/ha-auto-respaldo-$(date +%Y%m%d-%H%M); mkdir -p $BK; chmod 700 $BK
cp -a /usr/local/sbin/mejoland-ha $C $BK/ 2>/dev/null
echo "Respaldo de la version anterior en $BK"

grep -q '^TESTIGOS=' $C   || echo 'TESTIGOS="100.65.119.48:993 100.65.119.48:25 100.75.163.23:22"' >> $C
grep -q '^FALLOS_MAX=' $C || echo 'FALLOS_MAX=3' >> $C

CL=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
mysql -e "SET SESSION sql_log_bin=0;
  CREATE DATABASE IF NOT EXISTS mejoland_ha;
  CREATE TABLE IF NOT EXISTS mejoland_ha.nodo (nombre VARCHAR(20) PRIMARY KEY, estado VARCHAR(20), epoca INT, ts DATETIME);
  DROP USER IF EXISTS 'ha_sync'@'$RESP';
  CREATE USER 'ha_sync'@'$RESP' IDENTIFIED BY '$CL';
  GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES, RELOAD, BINLOG MONITOR, PROCESS ON *.* TO 'ha_sync'@'$RESP';" \
  || { echo "ERROR creando usuario/tabla en MariaDB. No se cambio la herramienta."; exit 1; }
printf '[client]\nuser=ha_sync\npassword=%s\n' "$CL" > /etc/mejoland-ha/sync.cnf; chmod 600 /etc/mejoland-ha/sync.cnf

EST=$(cat /var/lib/mejoland-ha/estado 2>/dev/null || echo NORMAL)
[ -f /var/lib/mejoland-ha/epoca ] || echo 1 > /var/lib/mejoland-ha/epoca
mysql -e "SET SESSION sql_log_bin=0; REPLACE INTO mejoland_ha.nodo VALUES ('srv-bd','$EST',$(cat /var/lib/mejoland-ha/epoca),NOW())"

cat > /usr/local/sbin/mejoland-ha.nuevo <<'HERRAMIENTA_FIN'
#!/bin/bash
# =====================================================================
#  mejoland-ha (SRV-BD) - PRINCIPAL con conmutacion automatica en ambos sentidos
#    estado    muestra el estado
#    vigilar   (temporizador cada 10 s) gestiona la conmutacion:
#                NORMAL   -> si damian-1 tomo el control (epoca mayor): se aparta (CERCADO)
#                CERCADO  -> si damian-1 le entrega el mando: copia sus datos y vuelve a ser principal
#                            si damian-1 cae estando al mando: retoma el servicio sin esperar
# =====================================================================
set -u
. /etc/mejoland-ha/ha.conf   # RESPALDO_TS SVC TESTIGOS FALLOS_MAX
D=/var/lib/mejoland-ha; mkdir -p $D
exec 9>/run/mejoland-ha.lock
if [ "${1:-estado}" = vigilar ]; then flock -n 9 || exit 0; else flock -w 120 9 || { echo "Ocupado, reintenta"; exit 1; }; fi
ESTADO=$(cat $D/estado 2>/dev/null || echo NORMAL)
EPOCA=$(cat $D/epoca 2>/dev/null || echo 1)
log() { echo "$(date '+%F %T') $*" | tee -a /var/log/mejoland-ha.log; logger -t mejoland-ha "$*"; }
MON="--defaults-extra-file=/etc/mejoland-ha/monitor.cnf"
SYNC="--defaults-extra-file=/etc/mejoland-ha/sync.cnf"
EXCL='^(mysql|information_schema|performance_schema|sys|mejoland_ha)$'
num() { [[ "${1:-}" =~ ^[0-9]+$ ]] && echo "$1" || echo 0; }
marcar() { mysql -e "SET SESSION sql_log_bin=0; REPLACE INTO mejoland_ha.nodo VALUES ('srv-bd','$1',$2,NOW())"; }
leer_par() {
  read -r P_EST P_EPO < <(timeout 5 mysql $SYNC -h "$RESPALDO_TS" -N -B -e "SELECT estado,epoca FROM mejoland_ha.nodo WHERE nombre='damian'" 2>/dev/null) || true
  P_EST=${P_EST:-}; P_EPO=$(num "${P_EPO:-}")
  [ -n "$P_EST" ] && [ "$P_EPO" -gt "$(num "$(cat $D/epoca_par 2>/dev/null)")" ] && echo "$P_EPO" > $D/epoca_par
}
par_ro() { timeout 4 mysql $MON -h "$RESPALDO_TS" -N -e 'SELECT @@read_only' 2>/dev/null; }
par_vivo() { timeout 4 mysql $MON -h "$RESPALDO_TS" -N -e "SELECT 1" >/dev/null 2>&1 || timeout 3 bash -c "</dev/tcp/$RESPALDO_TS/22" 2>/dev/null; }
testigo_visible() { for t in $TESTIGOS; do timeout 3 bash -c "</dev/tcp/${t%:*}/${t#*:}" 2>/dev/null && return 0; done; return 1; }
poner() { echo "$1" > $D/estado; ESTADO=$1; }

cercar() {
  log "CERCO: damian-1 esta al mando (epoca $P_EPO); SRV-BD deja de atender"
  tailscale serve drain "$SVC" >/dev/null 2>&1; systemctl stop lms
  mysql -e "SET GLOBAL read_only=1"
  marcar CERCADO $EPOCA; poner CERCADO; echo 0 > $D/fallos
}
retomar() {   # $1 = con-datos | sin-datos
  local UP; UP=$(num "$(cat $D/epoca_par 2>/dev/null)"); [ "$P_EPO" -gt "$UP" ] && UP=$P_EPO
  local N=$(( (UP > EPOCA ? UP : EPOCA) + 1 ))
  if [ "$1" = con-datos ]; then
    local DBS; DBS=$(timeout 10 mysql $SYNC -h "$RESPALDO_TS" -N -e "SHOW DATABASES" 2>/dev/null | grep -vE "$EXCL" | tr '\n' ' ')
    [ -n "$DBS" ] || { log "No puedo leer damian-1 con ha_sync; sigo cercado"; return 1; }
    local BK=/root/proyecto/antes-de-regresar-$(date +%Y%m%d-%H%M%S); mkdir -p "$BK"; chmod 700 "$BK"
    mariadb-dump --single-transaction --routines --triggers --events --databases $DBS > "$BK/srvbd-antes.sql" 2>/dev/null
    log "REGRESO: copiando a SRV-BD los datos de damian-1 (respaldo previo en $BK)"
    mariadb-dump $SYNC -h "$RESPALDO_TS" --single-transaction --routines --triggers --events --databases $DBS | mysql \
      || { log "ERROR copiando desde damian-1; SRV-BD sigue cercado"; return 1; }
    leer_par
    [ "$P_EST" = PRINCIPAL ] && { log "damian-1 volvio a tomar el mando durante la copia; sigo cercado"; return 1; }
  else
    log "damian-1 (al mando) no responde y los testigos si: SRV-BD retoma SIN poder copiar sus ultimos cambios"
  fi
  echo $N > $D/epoca; EPOCA=$N
  marcar NORMAL $N
  mysql -e "SET GLOBAL read_only=0"; systemctl start lms
  tailscale serve advertise "$SVC" >/dev/null 2>&1
  poner NORMAL; echo 0 > $D/fallos
  log "SRV-BD vuelve a ser el PRINCIPAL (epoca $N)"
}

case "${1:-estado}" in
  estado)
    leer_par
    echo "SRV-BD:   $ESTADO (epoca $EPOCA)"
    echo "  MariaDB read_only=$(mysql -N -e 'SELECT @@read_only')   EduNova: $(systemctl is-active lms)"
    echo "damian-1: ${P_EST:-no responde} $( [ -n "$P_EST" ] && echo "(epoca $P_EPO)")"
    tail -6 /var/log/mejoland-ha.log 2>/dev/null ;;
  vigilar)
    leer_par
    case "$ESTADO" in
      CERCADO)
        systemctl is-active -q lms && { tailscale serve drain "$SVC" >/dev/null 2>&1; systemctl stop lms; }
        [ "$(mysql -N -e 'SELECT @@read_only')" = 1 ] || mysql -e "SET GLOBAL read_only=1"
        marcar CERCADO $EPOCA
        if [ "$P_EST" = ENTREGANDO ] || [ "$P_EST" = ESPERA ]; then
          [ "$(par_ro)" = 1 ] && retomar con-datos
        elif ! par_vivo; then
          F=$(( $(num "$(cat $D/fallos 2>/dev/null)") + 1 )); echo $F > $D/fallos
          log "damian-1 (al mando) no responde ($F/$FALLOS_MAX)"
          [ "$F" -ge "$FALLOS_MAX" ] && testigo_visible && retomar sin-datos
        else echo 0 > $D/fallos; fi ;;
      *)   # NORMAL
        marcar NORMAL $EPOCA
        [ "$(mysql -N -e 'SELECT @@read_only')" = 0 ] || mysql -e "SET GLOBAL read_only=0"
        if [ "$P_EST" = PRINCIPAL ] && [ "$P_EPO" -gt "$EPOCA" ]; then cercar; fi ;;
    esac ;;
  *) sed -n '3,9p' "$0"; exit 1 ;;
esac
HERRAMIENTA_FIN
chmod 755 /usr/local/sbin/mejoland-ha.nuevo; mv /usr/local/sbin/mejoland-ha.nuevo /usr/local/sbin/mejoland-ha
echo; mejoland-ha estado
echo
echo "================================================================"
echo " LISTO en SRV-BD. Ahora en damian-1 (root) ejecuta:"
echo "     bash 08-ha-auto-damian.sh $CL"
echo " (esa clave es interna entre los dos servidores: no la mandes en capturas)"
echo "================================================================"
