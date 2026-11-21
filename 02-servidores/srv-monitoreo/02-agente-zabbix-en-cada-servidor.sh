#!/bin/bash
# =====================================================================
#  Agente de Zabbix (root) - se ejecuta en CADA servidor a vigilar:
#  srv-bd, damian-1, correo, srv-aaa-1, srv-aaa-2, srv-apps
#  - Si ya tiene zabbix-agent (correo, aaa-1) lo reconfigura; si no, instala zabbix-agent2.
#  - Modo ACTIVO: el agente envia los datos a SRV-MONITOREO (no hay que abrir puertos).
#  - Se registra solo en Zabbix (autorregistro con HostMetadata=mejoland).
#  - Funciona en casa (Tailscale 100.123.222.5) y en el laboratorio (192.168.40.20).
#  Uso:  bash 02-agente-zabbix-en-cada-servidor.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
H=$(hostname -s)
if dpkg -s zabbix-agent >/dev/null 2>&1; then
  SVC=zabbix-agent; C=/etc/zabbix/zabbix_agentd.conf
else
  SVC=zabbix-agent2; C=/etc/zabbix/zabbix_agent2.conf
  if ! dpkg -s zabbix-agent2 >/dev/null 2>&1; then
    apt-get install -y -q curl >/dev/null
    if ! dpkg -s zabbix-release >/dev/null 2>&1; then
      curl -fsSL -o /tmp/zabbix-release.deb https://repo.zabbix.com/zabbix/7.0/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.0+debian13_all.deb \
        && dpkg -i /tmp/zabbix-release.deb >/dev/null || { echo "ERROR descargando el repositorio de Zabbix"; exit 1; }
      apt-get update -q >/dev/null
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q zabbix-agent2 >/dev/null || { echo "ERROR instalando zabbix-agent2"; exit 1; }
  fi
fi
[ -f "$C" ] || { echo "No encuentro $C"; exit 1; }
mkdir -p /root/proyecto; cp -a $C /root/proyecto/$(basename $C).antes-$(date +%Y%m%d-%H%M)
for kv in "Server=127.0.0.1,192.168.40.20,100.123.222.5" \
          "ServerActive=192.168.40.20;100.123.222.5" \
          "Hostname=$H" "HostMetadata=mejoland-linux"; do
  k=${kv%%=*}; sed -i "/^$k=/d" $C; echo "$kv" >> $C
done
systemctl enable $SVC >/dev/null 2>&1; systemctl restart $SVC; sleep 3
echo "Agente: $SVC ($(systemctl is-active $SVC))   Nombre en Zabbix: $H"
timeout 3 bash -c "</dev/tcp/100.123.222.5/10051" 2>/dev/null && echo "Conexion con SRV-MONITOREO: OK" || echo "AVISO: no llego a SRV-MONITOREO (100.123.222.5:10051)"
tail -3 /var/log/zabbix/$SVC*.log 2>/dev/null | grep -iE "error|cannot|denied" || true
echo "LISTO. En unos minutos aparece en Zabbix: Recopilacion de datos -> Equipos."
