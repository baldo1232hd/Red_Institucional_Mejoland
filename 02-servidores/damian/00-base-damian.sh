#!/bin/bash
# =====================================================================
#  BASE DE DAMIAN (SRV-BD-REPLICA) - Centro Educativo Mejoland   (damian, root)
#  Prepara el servidor de respaldo de SRV-BD antes de crear las replicas:
#   - MariaDB con registro binario (server-id 2), solo lectura y conexion de replica
#     hacia SRV-BD por GTID (usuario repl).
#   - OpenLDAP instalado con una base propia de instalacion (dc=replica,dc=local); la base
#     dc=proyecto,dc=local se agrega despues como consumidora (02-replica-ldap-damian.sh).
#  Requisitos: Debian 13, Tailscale activo y SRV-BD configurado (srv-bd/01 y srv-bd/05).
#  La clave CLAVE_BD_REPL esta en /root/proyecto/claves.txt de SRV-BD.
#  Uso:  bash 00-base-damian.sh            (variable opcional PRINCIPAL=IP de SRV-BD)
#  Siguiente paso: srv-bd/05-replica-bd-srvbd.sh y luego damian/01-replica-bd-damian.sh
# =====================================================================
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
PRINCIPAL=${PRINCIPAL:-100.89.203.22}
paso() { echo; echo "=================== $* ==================="; }

paso "1 Paquetes"
read -rsp "Clave para el administrador de la base LDAP local de instalacion: " LPW </dev/tty; echo
cat <<DEB | debconf-set-selections
slapd slapd/no_configuration boolean false
slapd slapd/domain string replica.local
slapd shared/organization string Replica
slapd slapd/password1 password $LPW
slapd slapd/password2 password $LPW
slapd slapd/purge_database boolean false
slapd slapd/move_old_database boolean true
DEB
unset LPW
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q mariadb-server slapd ldap-utils rsync curl >/dev/null
hostnamectl set-hostname damian

paso "2 MariaDB como replica de SRV-BD"
cat > /etc/mysql/mariadb.conf.d/60-proyecto.cnf <<'CNF'
[mysqld]
bind-address      = 0.0.0.0
server-id         = 2
log_bin           = mysql-bin
binlog_format     = ROW
log_slave_updates = ON
expire_logs_days  = 7
read_only         = 1
log_bin_trust_function_creators = 1
character-set-server = utf8mb4
collation-server     = utf8mb4_unicode_ci
CNF
systemctl restart mariadb
read -rsp "CLAVE_BD_REPL (de /root/proyecto/claves.txt en SRV-BD): " RP </dev/tty; echo
mysql -h "$PRINCIPAL" -u repl -p"$RP" -e "SELECT 1" >/dev/null 2>&1 \
  || echo "  AVISO: el usuario repl aun no puede entrar a $PRINCIPAL (ejecutar srv-bd/05-replica-bd-srvbd.sh)."
mysql -e "STOP REPLICA; CHANGE MASTER TO MASTER_HOST='$PRINCIPAL', MASTER_USER='repl', MASTER_PASSWORD='$RP', MASTER_USE_GTID=slave_pos;" 2>/dev/null \
  || mysql -e "CHANGE MASTER TO MASTER_HOST='$PRINCIPAL', MASTER_USER='repl', MASTER_PASSWORD='$RP', MASTER_USE_GTID=slave_pos;"
unset RP
echo "  Conexion de replica configurada hacia $PRINCIPAL (se inicia con 01-replica-bd-damian.sh)"

paso "3 Estado"
systemctl is-active mariadb slapd | paste -sd' ' | sed 's/^/  mariadb, slapd: /'
mysql -N -e "SELECT @@server_id, @@read_only" | awk '{print "  server_id="$1"  read_only="$2}'
echo
echo "LISTO. Siguiente: en SRV-BD  bash 05-replica-bd-srvbd.sh   y aqui  bash 01-replica-bd-damian.sh CLAVE_TEMPORAL"
