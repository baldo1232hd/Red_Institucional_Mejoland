#!/bin/bash
# =====================================================================
#  Respaldos que no se pierden aunque el equipo este apagado (srv-apps y srv-monitoreo, root)
#  Cambia el cron diario por un temporizador de systemd con Persistent=true:
#   - si a la hora programada el equipo estaba encendido, se hace a esa hora;
#   - si estaba apagado, se hace unos minutos despues de encenderlo (una sola vez al dia).
#  srv-apps:      respaldo-apps-bd (GLPI + Nextcloud)  02:40
#  srv-monitoreo: respaldo-zabbix (configuracion)      03:10
#  Uso:  bash 05-respaldos-persistentes.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
hecho=0
crear() {  # nombre hora descripcion
  local N=$1 H=$2 DSC=$3
  [ -x /usr/local/bin/$N ] || return 0
  cat > /etc/systemd/system/$N.service <<U
[Unit]
Description=$DSC
Wants=network-online.target
After=network-online.target mariadb.service

[Service]
Type=oneshot
# al arrancar el equipo espera 3 min para que la red y Tailscale esten listos
ExecStartPre=/bin/sleep 180
ExecStart=/bin/sh -c '/usr/local/bin/$N >> /var/log/$N.log 2>&1'
U
  cat > /etc/systemd/system/$N.timer <<U
[Unit]
Description=$DSC (diario, se recupera si el equipo estaba apagado)

[Timer]
OnCalendar=*-*-* $H:00
Persistent=true

[Install]
WantedBy=timers.target
U
  rm -f /etc/cron.d/$N
  systemctl daemon-reload; systemctl enable -q --now $N.timer
  echo "  $N: temporizador diario $H (persistente). Cron anterior quitado."
  systemctl list-timers $N.timer --no-pager | sed -n '1,2p' | sed 's/^/    /'
  hecho=1
}
crear respaldo-apps-bd 02:40 "Respaldo de las bases de GLPI y Nextcloud"
crear respaldo-zabbix 03:10 "Respaldo de la configuracion de Zabbix"
[ $hecho = 1 ] || { echo "No hay respaldos de Mejoland en este equipo (respaldo-apps-bd / respaldo-zabbix)."; exit 1; }
echo; echo "LISTO en $(hostname). Para ver el ultimo resultado: tail /var/log/respaldo-*.log"
