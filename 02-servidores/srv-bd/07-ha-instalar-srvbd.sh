#!/bin/bash
# =====================================================================
#  FAILOVER - PASO 1 (SRV-BD, root)
#  - Usuario ha_monitor en MariaDB (solo puede preguntar el estado; se replica a damian-1).
#  - SRV-BD ofrece svc:mejoland  ->  https://mejoland.tailae692e.ts.net/  (EduNova)
#  - Vigilante "cerco": si damian-1 tomo el control, SRV-BD se aparta solo.
#  - Arma /tmp/ha-paquete.tgz para damian-1 (EduNova y su configuracion).
#  Antes: copiar a /tmp  mejoland-ha-srvbd  mejoland-ha-damian
#  Uso:   bash 07-ha-instalar-srvbd.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
RESP=100.93.52.67; SVC=svc:mejoland
for f in mejoland-ha-srvbd mejoland-ha-damian; do [ -f /tmp/$f ] || { echo "Falta /tmp/$f"; exit 1; }; done
TAGS=$(tailscale status --self --json | python3 -c "import json,sys;print(' '.join(json.load(sys.stdin)['Self'].get('Tags') or []))")
case " $TAGS " in *" tag:servidor "*) ;; *) echo "SRV-BD no tiene la etiqueta tag:servidor en Tailscale (Machines -> Edit ACL tags). No se cambio nada."; exit 1;; esac
[ "$(mysql -N -e 'SELECT @@log_bin')" = 1 ] || { echo "MariaDB sin log_bin. No se cambio nada."; exit 1; }
paso() { echo; echo "=================== $1 ==================="; }

paso "1 Configuracion y usuario de monitoreo"
mkdir -p /etc/mejoland-ha /var/lib/mejoland-ha; chmod 700 /etc/mejoland-ha
if [ ! -f /etc/mejoland-ha/monitor.cnf ]; then
  MP=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
  mysql -e "CREATE USER IF NOT EXISTS 'ha_monitor'@'100.%' IDENTIFIED BY '$MP';" || exit 1
  printf '[client]\nuser=ha_monitor\npassword=%s\nconnect-timeout=3\n' "$MP" > /etc/mejoland-ha/monitor.cnf; chmod 600 /etc/mejoland-ha/monitor.cnf
fi
printf 'RESPALDO_TS=%s\nSVC=%s\n' "$RESP" "$SVC" > /etc/mejoland-ha/ha.conf
echo NORMAL > /var/lib/mejoland-ha/estado
echo "  ha_monitor creado (sin permisos sobre datos; solo consulta el estado)"

paso "2 Servicio de Tailscale $SVC en SRV-BD"
tailscale serve --service=$SVC --https=443 http://127.0.0.1:3001 >/dev/null || { echo "ERROR configurando el servicio"; exit 1; }
tailscale serve status 2>/dev/null | sed -n "/${SVC#svc:}/,/^$/p" | head -8

paso "3 Vigilante (cerco) cada 10 s"
install -m 750 /tmp/mejoland-ha-srvbd /usr/local/sbin/mejoland-ha
cat > /etc/systemd/system/mejoland-ha.service <<EOF
[Unit]
Description=Mejoland HA - vigilante de SRV-BD (cerco si damian-1 tomo el control)
After=network-online.target mariadb.service tailscaled.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mejoland-ha vigilar
EOF
cat > /etc/systemd/system/mejoland-ha.timer <<EOF
[Unit]
Description=Mejoland HA cada 10 s
[Timer]
OnBootSec=5s
OnUnitActiveSec=10s
AccuracySec=1s
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload; systemctl enable --now mejoland-ha.timer >/dev/null
echo "  Temporizador: $(systemctl is-active mejoland-ha.timer)"

paso "4 Paquete para damian-1"
P=$(mktemp -d); mkdir -p $P/sql
for H in localhost 127.0.0.1; do
  mysql -N -e "SHOW CREATE USER 'lms'@'$H'" 2>/dev/null | sed 's/$/;/' >> $P/sql/lms.sql
  mysql -N -e "SHOW GRANTS FOR 'lms'@'$H'" 2>/dev/null | sed 's/$/;/' >> $P/sql/lms.sql
done
cp -a /etc/mejoland-ha/monitor.cnf $P/monitor.cnf
cp /tmp/mejoland-ha-damian $P/mejoland-ha-damian
LISTA="var/www/lms-backend var/www/lms-frontend etc/edunova etc/systemd/system/lms.service"
[ -d /etc/systemd/system/lms.service.d ] && LISTA="$LISTA etc/systemd/system/lms.service.d"
U=$(logname 2>/dev/null || echo israel)
tar -C / -czpf $P/archivos.tgz $LISTA 2>/dev/null
tar -C $P -czf /tmp/ha-paquete.tgz archivos.tgz sql monitor.cnf mejoland-ha-damian
chown "$U" /tmp/ha-paquete.tgz; chmod 600 /tmp/ha-paquete.tgz; rm -rf $P
echo "  /tmp/ha-paquete.tgz ($(du -h /tmp/ha-paquete.tgz | cut -f1)) - contiene claves: no lo guardes en otro lado"
echo
echo "LISTO en SRV-BD. Prueba: https://mejoland.tailae692e.ts.net/plataforma/  (aprueba SRV-BD en Services si aparece 'Pending')"
echo "Copia el paquete directo a damian-1 (desde CMD, sin guardarlo en tu PC):"
echo "   scp -3 $U@100.89.203.22:/tmp/ha-paquete.tgz damian1@$RESP:/tmp/"
