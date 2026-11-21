#!/bin/bash
# =====================================================================
#  Correo (HP): el nombre srv-bd-replica apunta a damian-1 (root en el HP)
#  Postfix y Dovecot usan srv-bd-replica como segundo servidor LDAP.
#  Incluye una prueba de conmutacion: bloquea por 20 s el LDAP de SRV-BD solo
#  desde este equipo y comprueba que el correo sigue encontrando a los usuarios.
#  Uso:  bash 05-respaldo-correo.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
SRV=100.89.203.22; REP=100.93.52.67; H=/etc/hosts
ldapsearch -x -LLL -H ldap://$REP -b dc=proyecto,dc=local -s base dn >/dev/null 2>&1 || { echo "La replica $REP no responde. No se cambio nada."; exit 1; }
BK=/root/proyecto/respaldo-correo-$(date +%Y%m%d-%H%M); mkdir -p "$BK"; chmod 700 "$BK"; cp -a $H "$BK/hosts"
echo "Respaldo de /etc/hosts en $BK  (volver atras: cp -a $BK/hosts /etc/hosts)"

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
systemctl reload postfix dovecot 2>/dev/null

U=$(ldapsearch -x -LLL -H ldap://$SRV -b ou=personas,dc=proyecto,dc=local "(mail=*@mejoland.edu.ec)" mail | sed -n 's/^mail: //p' | head -1)
echo; echo "== Prueba normal (usuario: $U)"
echo -n "  Postfix: "; postmap -q "$U" ldap:/etc/postfix/ldap-usuarios.cf || echo "NO ENCONTRADO"
echo -n "  Dovecot: "; doveadm user "$U" 2>&1 | grep -m1 home || echo "NO ENCONTRADO"

if command -v nft >/dev/null; then
  echo; echo "== Prueba de conmutacion: LDAP de SRV-BD bloqueado 20 s solo desde este equipo"
  nft add table inet prueba_ha; nft add chain inet prueba_ha out '{ type filter hook output priority 0 ; }'
  nft add rule inet prueba_ha out ip daddr $SRV tcp dport 389 reject
  trap 'nft delete table inet prueba_ha 2>/dev/null' EXIT
  systemctl reload postfix dovecot; sleep 2
  echo -n "  Postfix: "; timeout 20 postmap -q "$U" ldap:/etc/postfix/ldap-usuarios.cf || echo "NO ENCONTRADO"
  echo -n "  Dovecot: "; timeout 20 doveadm user "$U" 2>&1 | grep -m1 home || echo "NO ENCONTRADO"
  nft delete table inet prueba_ha; trap - EXIT
  systemctl reload postfix dovecot
  echo "  Bloqueo retirado. SRV-BD vuelve a ser el principal."
fi
echo; echo "LISTO. Si arriba salen los datos del usuario en las dos pruebas, el correo funciona aunque SRV-BD se caiga."
