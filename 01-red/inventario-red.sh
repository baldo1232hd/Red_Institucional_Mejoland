#!/bin/bash
# =====================================================================
#  Inventario de red de un servidor (solo lectura, ejecutar como root)
#  Muestra direcciones, rutas, DNS y las dependencias de Tailscale (IP 100.x, nombres *.ts.net, svc:mejoland)
#  que deben ajustarse entre modo-lab y modo-casa.
#  No muestra claves.  Uso:  bash inventario-red.sh > /tmp/red-$(hostname).txt 2>&1
# =====================================================================
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
echo "################ $(hostname) ################"
echo "== Interfaces";  ip -br addr | grep -v '^lo ' | sed 's/^/  /'
echo "== Ruta por defecto"; ip route | grep default | sed 's/^/  /'
echo "== Red configurada en"; for f in /etc/network/interfaces /etc/network/interfaces.d/* /etc/netplan/*.yaml /etc/NetworkManager/system-connections/*; do [ -f "$f" ] && echo "  $f"; done
nmcli -t -f NAME,DEVICE,TYPE con show --active 2>/dev/null | sed 's/^/  NetworkManager: /'
echo "== DNS"; grep -E '^(nameserver|search)' /etc/resolv.conf | sed 's/^/  /'
ls /root/proyecto/interfaces.* /usr/local/sbin/modo-* 2>/dev/null | sed 's/^/  ya existe: /'
echo "== Servicios escuchando (puerto, programa)"
ss -tlnpH 2>/dev/null | awk '{split($4,a,":"); p=a[length(a)]; match($0,/users:\(\("[^"]+/); u=substr($0,RSTART+9,RLENGTH-9); print p" "u}' | sort -n -u | awk '{printf "  %s/%s", $1,$2} END{print ""}'
echo "== Tailscale"; tailscale ip -4 2>/dev/null | sed 's/^/  IP: /'; tailscale serve status 2>/dev/null | grep -E '^https|proxy' | sed 's/^/  /'
echo "== Referencias a Tailscale en la configuracion (archivo:linea, valores de clave ocultos)"
grep -rnIE '100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]+\.[0-9]+|\.ts\.net|svc:mejoland|tailscale' \
  /etc /var/www /usr/local/sbin /usr/local/bin /root/proyecto/*.conf /var/lib/mejoland-ha 2>/dev/null \
  | grep -vE '/etc/(ssl|ca-certificates)|\.(bak|orig|dpkg-old|log)|backup|/apache-viejo/|/node_modules/|/vendor/|/3rdparty/|/data/|tailscaled\.state|/etc/default/tailscaled|/apt/' \
  | sed -E 's/((pass(word)?|secret|credentials)[^=:]*[=:][ "'"'"']*)[^ "'"'"',;]+/\1****/Ig' | cut -c1-170 | head -60 | sed 's/^/  /'
echo "== Referencias a IP del diseno 192.168.x"
grep -rlIE '192\.168\.(10|20|30|40|50|60)\.[0-9]+' /etc /var/www/lms-backend /usr/local/sbin 2>/dev/null | grep -vE 'backup|\.bak' | head -20 | sed 's/^/  /'
echo "== Fin de $(hostname)"
