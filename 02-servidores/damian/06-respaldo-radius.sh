#!/bin/bash
# =====================================================================
#  Wi-Fi (srv-aaa-1): el nombre srv-bd-replica apunta a damian-1 (root)
#  FreeRADIUS usa en su modulo ldap los servidores srv-bd y srv-bd-replica.
#  Prueba: valida un usuario (radtest, PAP contra LDAP) normal y con el LDAP de
#  SRV-BD bloqueado 20 s solo desde este equipo.
#  Uso:  bash 06-respaldo-radius.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
SRV=100.89.203.22; REP=100.93.52.67; H=/etc/hosts; R=/etc/freeradius/3.0
command -v ldapsearch >/dev/null || apt-get install -y -q ldap-utils >/dev/null
ldapsearch -x -LLL -H ldap://$REP -b dc=proyecto,dc=local -s base dn >/dev/null 2>&1 || { echo "La replica $REP no responde. No se cambio nada."; exit 1; }
BK=/root/proyecto/respaldo-radius-$(date +%Y%m%d-%H%M); mkdir -p "$BK"; chmod 700 "$BK"; cp -a $H "$BK/hosts"
echo "Respaldo de /etc/hosts en $BK  (volver atras: cp -a $BK/hosts /etc/hosts; systemctl restart freeradius)"

python3 - "$H" "$REP" <<'PY'
import sys, re
p, rep = sys.argv[1], sys.argv[2]
out = []
for l in open(p).read().splitlines():
    if not l.strip().startswith('#'):
        l = re.sub(r'\s+srv-bd-replica\.proyecto\.local\b', '', l)
        l = re.sub(r'\s+srv-bd-replica\b', '', l)
    out.append(l)
out.append(f"{rep}   srv-bd-replica.proyecto.local srv-bd-replica   # replica LDAP/MariaDB (damian-1)")
open(p, 'w').write("\n".join(out) + "\n")
PY
grep -E "srv-bd" $H
freeradius -XC >/dev/null 2>&1 || { echo "La configuracion de FreeRADIUS no pasa la verificacion. Restaurando hosts."; cp -a "$BK/hosts" $H; exit 1; }
systemctl restart freeradius; sleep 2; echo "freeradius: $(systemctl is-active freeradius)"

# Secreto del cliente localhost (no se muestra)
SEC=$(awk '/^[[:space:]]*client[[:space:]]+localhost[[:space:]]*\{/{f=1} f&&/^[[:space:]]*secret[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/,""); gsub(/["[:space:]]/,""); print; exit} f&&/^[[:space:]]*}/{f=0}' $R/clients.conf)
[ -n "$SEC" ] || { echo "No encontre el secreto del cliente localhost en clients.conf; prueba omitida."; exit 0; }
echo; read -rp "Usuario de prueba (cuenta institucional): " U; read -rsp "Su contrasena: " P; echo
prueba() { radtest -t pap "$U" "$P" 127.0.0.1 0 "$SEC" 2>&1 | grep -oE "Access-(Accept|Reject)|no response" | head -1; }
echo "== Prueba normal:              $(prueba)"
if command -v nft >/dev/null; then
  nft add table inet prueba_ha; nft add chain inet prueba_ha out '{ type filter hook output priority 0 ; }'
  nft add rule inet prueba_ha out ip daddr $SRV tcp dport 389 reject
  trap 'nft delete table inet prueba_ha 2>/dev/null' EXIT
  systemctl restart freeradius; sleep 2
  echo "== Con SRV-BD (LDAP) bloqueado: $(prueba)"
  nft delete table inet prueba_ha; trap - EXIT
  systemctl restart freeradius; sleep 1
  echo "   Bloqueo retirado. SRV-BD vuelve a ser el principal."
fi
unset P SEC
echo; echo "LISTO. Si las dos pruebas dicen Access-Accept, el Wi-Fi valida usuarios aunque SRV-BD se caiga."
