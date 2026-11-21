#!/bin/bash
# =====================================================================
#  MAC - PASO 1 (SRV-BD, root): permite que las 3 VMs de la Mac entren a sus
#  bases de datos por Tailscale. Copia cada usuario (misma clave y permisos) de su
#  IP de laboratorio a la IP de Tailscale de la VM. No cambia claves ni borra nada.
#  Uso:  bash 13-permisos-mac-srvbd.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
# usuario  IP-de-laboratorio  IP-Tailscale
PLAN="radius 192.168.40.12 100.74.49.76
zabbix 192.168.40.20 100.123.222.5
glpi 192.168.40.21 100.107.96.3
nextcloud 192.168.40.21 100.107.96.3"
BK=/root/proyecto/permisos-mac-$(date +%Y%m%d-%H%M); mkdir -p $BK; chmod 700 $BK
echo "#!/bin/bash" > $BK/deshacer.sh; chmod 700 $BK/deshacer.sh
while read -r U LAB TS; do
  if mysql -N -e "SELECT 1 FROM mysql.user WHERE user='$U' AND host='$TS'" | grep -q 1; then
    echo "  $U@$TS ya existe"; continue; fi
  SRC=$(mysql -N -e "SELECT host FROM mysql.user WHERE user='$U' ORDER BY host='$LAB' DESC, host LIKE '100.%' DESC LIMIT 1")
  [ -n "$SRC" ] || { echo "  AVISO: no existe ningun usuario '$U' en MariaDB (revisa /root/proyecto/claves.txt)"; continue; }
  { mysql -N -e "SHOW CREATE USER '$U'@'$SRC'"; mysql -N -e "SHOW GRANTS FOR '$U'@'$SRC'"; } \
    | sed "s/@\`$SRC\`/@\`$TS\`/; s/@'$SRC'/@'$TS'/; s/\$/;/" | mysql \
    && { echo "  OK  $U@$TS  (copiado de $U@$SRC)"; echo "mysql -e \"DROP USER '$U'@'$TS'\"" >> $BK/deshacer.sh; } \
    || echo "  ERROR creando $U@$TS"
done <<< "$PLAN"
echo; mysql -e "SELECT user, host FROM mysql.user WHERE user IN ('radius','zabbix','glpi','nextcloud') ORDER BY user, host"
echo; echo "LISTO. Se replica solo a damian-1. Deshacer: bash $BK/deshacer.sh"
