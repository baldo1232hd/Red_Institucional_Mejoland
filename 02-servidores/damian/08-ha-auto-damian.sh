#!/bin/bash
# =====================================================================
#  HA AUTOMATICO - PASO 2 (damian-1, root)
#  Uso: bash 08-ha-auto-damian.sh CLAVE     (CLAVE = la que mostro el paso 1 en SRV-BD)
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
CL=${1:-}; [[ "$CL" =~ ^[A-Za-z0-9]{24}$ ]] || { echo "Uso: bash $0 CLAVE (la muestra SRV-BD)"; exit 1; }
C=/etc/mejoland-ha/ha.conf
[ -f $C ] || { echo "No existe $C: primero hay que tener instalado el failover (v1)."; exit 1; }
. $C
PRIN=${PRINCIPAL_TS:-100.89.203.22}
BK=/root/proyecto/ha-auto-respaldo-$(date +%Y%m%d-%H%M); mkdir -p $BK; chmod 700 $BK
cp -a /usr/local/sbin/mejoland-ha $C $BK/ 2>/dev/null
echo "Respaldo de la version anterior en $BK"

printf '[client]\nuser=ha_sync\npassword=%s\n' "$CL" > /etc/mejoland-ha/sync.cnf; chmod 600 /etc/mejoland-ha/sync.cnf
echo -n "Prueba de acceso a SRV-BD con ha_sync: "
R=$(timeout 8 mysql --defaults-extra-file=/etc/mejoland-ha/sync.cnf -h $PRIN -N -B -e "SELECT estado,epoca FROM mejoland_ha.nodo WHERE nombre='srv-bd'" 2>&1) \
  || { echo "FALLA"; echo "$R"; echo "Revisa que copiaste bien la clave. No se cambio la herramienta."; exit 1; }
echo "OK (SRV-BD dice: $R)"

mysql -e "SET SESSION sql_log_bin=0;
  CREATE DATABASE IF NOT EXISTS mejoland_ha;
  CREATE TABLE IF NOT EXISTS mejoland_ha.nodo (nombre VARCHAR(20) PRIMARY KEY, estado VARCHAR(20), epoca INT, ts DATETIME);
  DROP USER IF EXISTS 'ha_sync'@'$PRIN';
  CREATE USER 'ha_sync'@'$PRIN' IDENTIFIED BY '$CL';
  GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES, RELOAD, BINLOG MONITOR, PROCESS ON *.* TO 'ha_sync'@'$PRIN';" \
  || { echo "ERROR creando usuario/tabla en MariaDB."; exit 1; }

grep -q '^REGRESO_AUTO=' $C       || echo 'REGRESO_AUTO=si' >> $C
grep -q '^ESPERA_REGRESO=' $C     || echo 'ESPERA_REGRESO=120' >> $C
grep -q '^TIEMPO_MAX_ENTREGA=' $C || echo 'TIEMPO_MAX_ENTREGA=600' >> $C

D=/var/lib/mejoland-ha
EST=$(cat $D/estado 2>/dev/null || echo ESPERA)
[ "$EST" = REGRESANDO ] && { EST=ENTREGANDO; echo ENTREGANDO > $D/estado; date +%s > $D/entrega_desde; }
if [ ! -f $D/epoca ]; then [ "$EST" = ESPERA ] && echo 1 > $D/epoca || echo 2 > $D/epoca; fi
echo 1 > $D/epoca_par
mysql -e "SET SESSION sql_log_bin=0; REPLACE INTO mejoland_ha.nodo VALUES ('damian','$EST',$(cat $D/epoca),NOW())"
mysql -e "SET SESSION sql_log_bin=0; DROP USER IF EXISTS 'ha_volcado'@'$PRIN'" 2>/dev/null
systemctl disable lms >/dev/null 2>&1   # EduNova la arranca el vigilante, no el arranque del equipo

cat > /usr/local/sbin/mejoland-ha.nuevo <<'HERRAMIENTA_FIN'
#!/bin/bash
# =====================================================================
#  mejoland-ha (damian-1) - RESPALDO con conmutacion automatica en ambos sentidos
#    estado     muestra el estado
#    vigilar    (temporizador cada 10 s) gestiona la conmutacion:
#                 ESPERA     -> si SRV-BD cae 3 veces seguidas: toma el control (PRINCIPAL)
#                 PRINCIPAL  -> si SRV-BD vuelve y esta estable ESPERA_REGRESO s: le devuelve el mando
#                 ENTREGANDO -> cuando SRV-BD retoma: se copia sus datos y vuelve a ser replica (ESPERA)
#    devolver   devuelve el mando a SRV-BD ya, sin esperar
#    promover   toma el control a mano (solo si SRV-BD esta caido)
#  Cada toma de control sube la "epoca": si los dos creen mandar, gana la epoca mayor.
# =====================================================================
set -u
. /etc/mejoland-ha/ha.conf   # PRINCIPAL_TS PRINCIPAL_URL TESTIGOS SVC FALLOS_MAX REGRESO_AUTO ESPERA_REGRESO TIEMPO_MAX_ENTREGA
REGRESO_AUTO=${REGRESO_AUTO:-si}; ESPERA_REGRESO=${ESPERA_REGRESO:-120}; TIEMPO_MAX_ENTREGA=${TIEMPO_MAX_ENTREGA:-600}
D=/var/lib/mejoland-ha; mkdir -p $D
exec 9>/run/mejoland-ha.lock
if [ "${1:-estado}" = vigilar ]; then flock -n 9 || exit 0; else flock -w 120 9 || { echo "Ocupado, reintenta"; exit 1; }; fi
ESTADO=$(cat $D/estado 2>/dev/null || echo ESPERA)
EPOCA=$(cat $D/epoca 2>/dev/null || echo 1)
log() { echo "$(date '+%F %T') $*" | tee -a /var/log/mejoland-ha.log; logger -t mejoland-ha "$*"; }
MON="--defaults-extra-file=/etc/mejoland-ha/monitor.cnf"
SYNC="--defaults-extra-file=/etc/mejoland-ha/sync.cnf"
EXCL='^(mysql|information_schema|performance_schema|sys|mejoland_ha)$'
num() { [[ "${1:-}" =~ ^[0-9]+$ ]] && echo "$1" || echo 0; }

marcar() { mysql -e "SET SESSION sql_log_bin=0; REPLACE INTO mejoland_ha.nodo VALUES ('damian','$1',$2,NOW())"; }
leer_par() {   # P_EST P_EPO de SRV-BD (vacio si no se puede leer)
  read -r P_EST P_EPO < <(timeout 5 mysql $SYNC -h "$PRINCIPAL_TS" -N -B -e "SELECT estado,epoca FROM mejoland_ha.nodo WHERE nombre='srv-bd'" 2>/dev/null) || true
  P_EST=${P_EST:-}; P_EPO=$(num "${P_EPO:-}")
  [ -n "$P_EST" ] && [ "$P_EPO" -gt "$(num "$(cat $D/epoca_par 2>/dev/null)")" ] && echo "$P_EPO" > $D/epoca_par
}
par_ro() { timeout 4 mysql $MON -h "$PRINCIPAL_TS" -N -e 'SELECT @@read_only' 2>/dev/null; }
principal_vivo() {
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$PRINCIPAL_URL")" = "200" ] && return 0
  timeout 4 mysql $MON -h "$PRINCIPAL_TS" -N -e "SELECT 1" >/dev/null 2>&1
}
testigo_visible() { for t in $TESTIGOS; do timeout 3 bash -c "</dev/tcp/${t%:*}/${t#*:}" 2>/dev/null && return 0; done; return 1; }
poner() { echo "$1" > $D/estado; ESTADO=$1; }

promover() {
  local N=$(( $(num "$(cat $D/epoca_par 2>/dev/null)") > EPOCA ? $(num "$(cat $D/epoca_par 2>/dev/null)") : EPOCA ))
  N=$((N+1)); echo $N > $D/epoca; EPOCA=$N
  log "PROMOCION (epoca $N): damian-1 toma el control - $1"
  marcar PRINCIPAL $N
  mysql -e "STOP REPLICA; SET GLOBAL read_only=0;" || { log "ERROR: no se pudo promover MariaDB"; return 1; }
  systemctl start lms
  tailscale serve advertise "$SVC" >/dev/null 2>&1 && log "Anunciando $SVC: los usuarios llegan a damian-1"
  poner PRINCIPAL; date '+%F %T' > $D/desde; echo 0 > $D/fallos; rm -f $D/estable_desde
}
dejar_de_atender() {
  tailscale serve drain "$SVC" >/dev/null 2>&1; systemctl stop lms
  mysql -e "SET GLOBAL read_only=1"
  marcar ENTREGANDO $EPOCA; poner ENTREGANDO; date +%s > $D/entrega_desde; echo 0 > $D/fallos; rm -f $D/estable_desde
}
resincronizar() {   # copia todo desde SRV-BD y vuelve a ser replica
  local DBS; DBS=$(timeout 10 mysql $SYNC -h "$PRINCIPAL_TS" -N -e "SHOW DATABASES" 2>/dev/null | grep -vE "$EXCL" | tr '\n' ' ')
  [ -n "$DBS" ] || { log "No puedo leer SRV-BD con ha_sync; reintento luego"; return 1; }
  log "Copiando datos de SRV-BD y volviendo a ser replica"
  mysql -e "STOP REPLICA"
  mariadb-dump $SYNC -h "$PRINCIPAL_TS" --single-transaction --gtid --master-data=1 --routines --triggers --events --databases $DBS | mysql \
    || { log "ERROR copiando desde SRV-BD; reintento luego"; return 1; }
  mysql -e "SET GLOBAL read_only=1; START REPLICA"; sleep 3
  local R; R=$(mysql -e "SHOW REPLICA STATUS\G" | awk '/Slave_IO_Running:|Slave_SQL_Running:/{printf "%s ",$2}')
  marcar ESPERA $EPOCA; poner ESPERA; rm -f $D/desde $D/entrega_desde; echo 0 > $D/fallos
  log "damian-1 de nuevo EN ESPERA, replica de SRV-BD (IO/SQL: $R)"
}

case "${1:-estado}" in
  estado)
    leer_par
    echo "damian-1: $ESTADO (epoca $EPOCA) $( [ -f $D/desde ] && echo "al mando desde $(cat $D/desde)")"
    echo "  MariaDB read_only=$(mysql -N -e 'SELECT @@read_only')  replica: $(mysql -e 'SHOW REPLICA STATUS\G' | awk '/Slave_IO_Running:|Slave_SQL_Running:/{printf "%s ",$2}')  EduNova: $(systemctl is-active lms)"
    echo "SRV-BD:   ${P_EST:-no responde} $( [ -n "$P_EST" ] && echo "(epoca $P_EPO)")"
    echo "Regreso automatico: $REGRESO_AUTO (tras ${ESPERA_REGRESO}s estable)"
    tail -6 /var/log/mejoland-ha.log 2>/dev/null ;;

  vigilar)
    leer_par
    case "$ESTADO" in
      PRINCIPAL)
        if [ "$P_EST" = NORMAL ] && [ "$P_EPO" -gt "$EPOCA" ]; then
          mkdir -p /root/proyecto; B=/root/proyecto/damian-antes-de-ceder-$(date +%Y%m%d-%H%M%S).sql
          DBS=$(mysql -N -e "SHOW DATABASES" | grep -vE "$EXCL" | tr '\n' ' ')
          mariadb-dump --single-transaction --routines --triggers --events --databases $DBS > "$B" 2>/dev/null
          log "SRV-BD retomo el mando (epoca $P_EPO > $EPOCA). damian-1 cede (copia de sus datos en $B)"
          dejar_de_atender; resincronizar; exit 0
        fi
        if [ "$(mysql -N -e 'SELECT @@read_only')" != "0" ]; then
          mysql -e "STOP REPLICA; SET GLOBAL read_only=0"; tailscale serve advertise "$SVC" >/dev/null 2>&1
          log "Reafirmado como principal tras reinicio"
        fi
        systemctl is-active -q lms || systemctl start lms
        marcar PRINCIPAL $EPOCA
        [ "$REGRESO_AUTO" = si ] || exit 0
        if [ "$P_EST" = CERCADO ]; then
          [ -f $D/estable_desde ] || { date +%s > $D/estable_desde; log "SRV-BD volvio (cercado). Le devuelvo el mando si sigue estable ${ESPERA_REGRESO}s"; }
          if [ $(( $(date +%s) - $(cat $D/estable_desde) )) -ge "$ESPERA_REGRESO" ]; then
            log "REGRESO AUTOMATICO: SRV-BD estable; damian-1 deja de atender y le entrega el mando"
            dejar_de_atender
          fi
        else
          [ -f $D/estable_desde ] && { rm -f $D/estable_desde; log "SRV-BD ya no esta listo para retomar; regreso pospuesto"; }
        fi ;;
      ENTREGANDO)
        if [ "$P_EST" = NORMAL ] && [ "$P_EPO" -gt "$EPOCA" ]; then resincronizar; exit 0; fi
        if ! principal_vivo; then
          F=$(( $(num "$(cat $D/fallos 2>/dev/null)") + 1 )); echo $F > $D/fallos
          log "SRV-BD no responde durante el regreso ($F/$FALLOS_MAX)"
          [ "$F" -ge "$FALLOS_MAX" ] && testigo_visible && promover "SRV-BD cayo durante el regreso"
          exit 0
        fi
        echo 0 > $D/fallos
        if [ $(( $(date +%s) - $(num "$(cat $D/entrega_desde 2>/dev/null)") )) -ge "$TIEMPO_MAX_ENTREGA" ]; then
          promover "SRV-BD no retomo en ${TIEMPO_MAX_ENTREGA}s"
        fi ;;
      *)   # ESPERA
        marcar ESPERA $EPOCA
        if principal_vivo; then echo 0 > $D/fallos; exit 0; fi
        if ! testigo_visible; then log "SRV-BD no responde, pero tampoco veo a los testigos: el aislado puedo ser yo. No promuevo."; exit 0; fi
        F=$(( $(num "$(cat $D/fallos 2>/dev/null)") + 1 )); echo $F > $D/fallos
        log "SRV-BD no responde ($F/$FALLOS_MAX)"
        [ "$F" -ge "$FALLOS_MAX" ] && promover "SRV-BD caido $F veces seguidas" ;;
    esac ;;

  devolver)
    [ "$ESTADO" = PRINCIPAL ] || { echo "damian-1 no esta al mando ($ESTADO)."; exit 1; }
    leer_par; [ "$P_EST" = CERCADO ] || { echo "SRV-BD no esta listo para retomar (estado: ${P_EST:-no responde})."; exit 1; }
    log "REGRESO MANUAL pedido"; dejar_de_atender; echo "Hecho. SRV-BD retomara en unos segundos; damian-1 se resincroniza solo." ;;
  promover)
    [ "$ESTADO" = PRINCIPAL ] && { echo "Ya es principal."; exit 0; }
    principal_vivo && { echo "SRV-BD esta respondiendo: no se promueve (evita dos principales)."; exit 1; }
    promover "manual" ;;
  *) sed -n '3,12p' "$0"; exit 1 ;;
esac
HERRAMIENTA_FIN
chmod 755 /usr/local/sbin/mejoland-ha.nuevo; mv /usr/local/sbin/mejoland-ha.nuevo /usr/local/sbin/mejoland-ha
echo; mejoland-ha estado
echo
echo "================================================================"
echo " LISTO. El cambio maestro <-> esclavo ya es automatico en los dos sentidos."
[ "$EST" = PRINCIPAL ] && echo " damian-1 esta al mando y SRV-BD cercado: en ~2 min le devolvera el mando solo."
echo " Para verlo en vivo:  tail -f /var/log/mejoland-ha.log"
echo "================================================================"
