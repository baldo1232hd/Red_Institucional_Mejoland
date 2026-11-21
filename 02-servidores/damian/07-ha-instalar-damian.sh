#!/bin/bash
# =====================================================================
#  FAILOVER - PASO 2 (damian-1, root): deja damian-1 EN ESPERA
#  - Instala EduNova (apagada) usando su replica de MariaDB y LDAP.
#  - MariaDB: read_only=1 fijo y escucha en Tailscale (SRV-BD necesita ver su estado).
#  - Configura svc:mejoland en pausa (drain): solo se anuncia si SRV-BD cae.
#  - Vigilante cada 10 s con testigos (HP de correo y srv-aaa-1).
#  Antes: /tmp/ha-paquete.tgz (lo arma el paso 1)   Uso: bash 07-ha-instalar-damian.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
PRIN=100.89.203.22; SVC=svc:mejoland
[ -f /tmp/ha-paquete.tgz ] || { echo "Falta /tmp/ha-paquete.tgz"; exit 1; }
TAGS=$(tailscale status --self --json | python3 -c "import json,sys;print(' '.join(json.load(sys.stdin)['Self'].get('Tags') or []))")
case " $TAGS " in *" tag:servidor "*) ;; *) echo "damian-1 no tiene la etiqueta tag:servidor en Tailscale. No se cambio nada."; exit 1;; esac
mysql -e "SHOW REPLICA STATUS\G" | grep -q "Slave_SQL_Running: Yes" || { echo "La replica MariaDB no esta funcionando. No se cambio nada."; exit 1; }
paso() { echo; echo "=================== $1 ==================="; }
P=$(mktemp -d); trap 'rm -rf $P' EXIT; tar -C $P -xzf /tmp/ha-paquete.tgz

mysql -N -e "SELECT COUNT(*) FROM mysql.user WHERE user='ha_monitor'" | grep -q '^[1-9]' || { echo "Aun no llega el usuario ha_monitor por la replica (ejecuta primero el paso 1 en SRV-BD)."; exit 1; }

paso "1 MariaDB de damian-1: solo lectura fija y visible para SRV-BD"
C=/etc/mysql/mariadb.conf.d/60-mejoland-ha.cnf
if [ ! -f $C ]; then
  printf '[mysqld]\n# Respaldo de SRV-BD: solo lectura salvo que mejoland-ha lo promueva\nread_only = 1\nbind-address = 0.0.0.0\n' > $C
  systemctl restart mariadb; sleep 3
  mysql -e "START REPLICA" 2>/dev/null
fi
echo "  read_only=$(mysql -N -e 'SELECT @@read_only')  escucha: $(ss -tlnH 'sport = :3306' | awk '{print $4}' | tr '\n' ' ')"
mysql -e "SHOW REPLICA STATUS\G" | grep -E "IO_Running|SQL_Running:" | sed 's/^ */  /'

paso "2 Node.js"
apt-get install -y -q nodejs curl >/dev/null || { echo "ERROR instalando Node.js"; exit 1; }
echo "  node $(node -v)"

paso "3 EduNova (apagada, en espera)"
id lms >/dev/null 2>&1 || useradd --system --home-dir /var/www/lms-backend --shell /usr/sbin/nologin lms
tar -C / -xzpf $P/archivos.tgz
E=/var/www/lms-backend/.env
sed -i 's/^DB_HOST=.*/DB_HOST=127.0.0.1/' $E
sed -i '/^LDAP_URL=/d' $E; echo "LDAP_URL=\"ldap://127.0.0.1:389 ldap://$PRIN:389\"" >> $E
install -d -m 750 -o lms -g lms /var/lib/edunova /var/lib/edunova/impresiones
mysql -e "SET SESSION sql_log_bin=0; $(cat $P/sql/lms.sql)" 2>/dev/null && echo "  usuario lms de MariaDB: OK"
systemctl daemon-reload
systemctl start lms; sleep 3
echo -n "  Prueba EduNova en damian-1: "; curl -s -o /dev/null -w "%{http_code} (esperado 200)\n" http://127.0.0.1:3001/
systemctl stop lms; systemctl disable lms >/dev/null 2>&1
echo "  EduNova queda APAGADA (solo arranca si damian-1 toma el control)"

paso "4 Servicio $SVC en pausa"
tailscale serve --service=$SVC --https=443 http://127.0.0.1:3001 >/dev/null || { echo "ERROR configurando el servicio"; exit 1; }
tailscale serve drain $SVC >/dev/null 2>&1
echo "  Configurado y en pausa (drain): no recibe usuarios mientras SRV-BD funcione"

paso "5 Vigilante cada 10 s"
mkdir -p /etc/mejoland-ha /var/lib/mejoland-ha; chmod 700 /etc/mejoland-ha
install -m 600 $P/monitor.cnf /etc/mejoland-ha/monitor.cnf
cat > /etc/mejoland-ha/ha.conf <<EOF
PRINCIPAL_TS=$PRIN
PRINCIPAL_URL=https://srv-bd.tailae692e.ts.net/plataforma/
TESTIGOS="100.65.119.48:993 100.65.119.48:25 100.75.163.23:22"
SVC=$SVC
FALLOS_MAX=3
EOF
install -m 750 $P/mejoland-ha-damian /usr/local/sbin/mejoland-ha
echo ESPERA > /var/lib/mejoland-ha/estado; echo 0 > /var/lib/mejoland-ha/fallos
cat > /etc/systemd/system/mejoland-ha.service <<EOF
[Unit]
Description=Mejoland HA - vigilante de damian-1 (toma el control si SRV-BD cae)
After=network-online.target mariadb.service tailscaled.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mejoland-ha vigilar
EOF
cat > /etc/systemd/system/mejoland-ha.timer <<EOF
[Unit]
Description=Mejoland HA cada 10 s
[Timer]
OnBootSec=30s
OnUnitActiveSec=10s
AccuracySec=1s
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload; systemctl enable --now mejoland-ha.timer >/dev/null
rm -f /tmp/ha-paquete.tgz
echo; mejoland-ha estado
echo; echo "LISTO: damian-1 EN ESPERA. Si SRV-BD cae ~30 s, toma el control solo."
echo "Ver en cualquier momento:  mejoland-ha estado     Log: /var/log/mejoland-ha.log"
