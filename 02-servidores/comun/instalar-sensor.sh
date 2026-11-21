#!/bin/bash
# =====================================================================
#  INSTALAR SENSOR CENTINELA - Centro Educativo Mejoland  (en los 7 servidores, root)
#  Cada minuto envia a Centinela (TUF) lo que paso por IP: fallos SSH, conexiones, pings, escaneos.
#  Solo cuenta; no bloquea nada.  Uso: bash instalar-sensor.sh   (con /tmp/sensor-centinela.py)
#  Despues:  sensor-centinela          (ejecutarlo a mano y ver lo que envia)
#            systemctl status mejoland-sensor.timer
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root (sudo -i)"; exit 1; }
[ -f /tmp/sensor-centinela.py ] || { echo "Falta /tmp/sensor-centinela.py"; exit 1; }
E=/etc/mejoland; mkdir -p $E
echo "################ SENSOR CENTINELA: $(hostname -s) ################"

URL_DEF="http://100.124.36.19:8800"
[ -f $E/centinela.conf ] && . <(grep -E '^(URL|TOKEN)=' $E/centinela.conf)
read -r -p "  Direcciones de Centinela, separadas por coma [${URL:-$URL_DEF}]: " u </dev/tty; URL=${u:-${URL:-$URL_DEF}}
if [ -z "${TOKEN:-}" ]; then
  read -r -s -p "  Token de Centinela (contenido de C:\\centinela\\centinela\\token.txt en la TUF): " TOKEN </dev/tty; echo
fi
printf 'URL=%s\nTOKEN=%s\n' "$URL" "$TOKEN" > $E/centinela.conf; chmod 600 $E/centinela.conf
BUENA=0
for u in ${URL//,/ }; do
  echo -n "  Prueba de conexion con $u: "
  c=$(curl -s -o /dev/null -w '%{http_code}' -m 6 -X POST "$u/analizar?explicar_llm=false" -H 'Content-Type: application/json' \
      -H "X-Token: $TOKEN" -d '{"servidor":"prueba","ip":"192.0.2.1"}')
  case $c in 200) echo "OK"; BUENA=1;; 401) echo "TOKEN INCORRECTO"; exit 1;; 000) echo "sin respuesta (ese sistema de la TUF esta apagado)";; *) echo "respuesta $c";; esac
done
[ $BUENA -eq 1 ] || { echo "  Ninguna direccion respondio: enciende la TUF y abre Centinela"; exit 1; }

install -m 755 /tmp/sensor-centinela.py /usr/local/sbin/sensor-centinela

# Tabla nftables que solo CUENTA por IP (pings y conexiones web nuevas). No descarta nada.
cat > $E/sensor.nft <<'EOF'
table inet mejoland_sensor
delete table inet mejoland_sensor
table inet mejoland_sensor {
  set s_ping   { type ipv4_addr; size 65535; flags dynamic,timeout; timeout 2m; counter; }
  set s_nuevas { type ipv4_addr; size 65535; flags dynamic,timeout; timeout 2m; counter; }
  chain entrada {
    type filter hook input priority -20; policy accept;
    icmp type echo-request update @s_ping { ip saddr }
    tcp dport { 80, 443, 3001, 8443 } ct state new update @s_nuevas { ip saddr }
  }
}
EOF
cat > /etc/systemd/system/mejoland-sensor.service <<'EOF'
[Unit]
Description=Sensor Centinela (envia estadisticas por IP a Centinela)
After=network-online.target
[Service]
Type=oneshot
ExecStartPre=-/bin/sh -c 'nft list table inet mejoland_sensor >/dev/null 2>&1 || nft -f /etc/mejoland/sensor.nft'
ExecStart=/usr/local/sbin/sensor-centinela
TimeoutStartSec=55
Nice=10
EOF
cat > /etc/systemd/system/mejoland-sensor.timer <<'EOF'
[Unit]
Description=Sensor Centinela cada minuto
[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=5
[Install]
WantedBy=timers.target
EOF
nft -f $E/sensor.nft && echo "  [OK] tabla de conteo cargada"
ufw status 2>/dev/null | grep -q "Status: active" && ufw logging low >/dev/null 2>&1 && echo "  [OK] cortafuegos registra intentos bloqueados (para detectar escaneos)"
systemctl daemon-reload; systemctl enable --now mejoland-sensor.timer >/dev/null 2>&1 && echo "  [OK] sensor cada minuto"
echo "== Primera ejecucion"
/usr/local/sbin/sensor-centinela
rm -f /tmp/sensor-centinela.py
echo "LISTO. Ver envios: journalctl -u mejoland-sensor -n 20 --no-pager"
