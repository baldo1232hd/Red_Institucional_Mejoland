#!/bin/bash
# =====================================================================
#  DNS secundario - PASO 1 (SRV-BD, root): permite que damian-1 copie la
#  zona mejoland.edu.ec y le avisa de cada cambio. Recarga sin reiniciar BIND.
#  Uso:  bash 06-dns-secundario-srvbd.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
REP=100.93.52.67; Z=mejoland.edu.ec; LOCAL=/etc/bind/named.conf.local; F=/etc/bind/db.$Z
grep -q "zone \"$Z\"" $LOCAL || { echo "No existe la zona $Z (ejecuta antes dns-mejoland.sh)."; exit 1; }
BK=/root/proyecto/dns-secundario-$(date +%Y%m%d-%H%M); mkdir -p "$BK"; chmod 700 "$BK"; cp -a $LOCAL $F "$BK/"
python3 - "$LOCAL" "$Z" "$REP" "$F" <<'PY'
import sys, re
p, z, rep, f = sys.argv[1:5]
s = open(p).read()
i = s.index(f'zone "{z}"')
j = i; depth = 0
while True:                       # fin del bloque: llave de cierre del nivel 0 seguida de ';'
    c = s[j]
    if c == '{': depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0: j = s.index(';', j) + 1; break
    j += 1
blk = s[i:j]
m = re.search(r'allow-transfer\s*\{([^}]*)\}', blk)
ips = [x.strip() for x in (m.group(1).split(';') if m else []) if x.strip()]
if f'{rep}/32' not in ips and rep not in ips: ips.append(f'{rep}/32')
nuevo = (f'zone "{z}" {{\n        type master;\n        file "{f}";\n'
         f'        allow-transfer {{ {"; ".join(ips)}; }};\n        also-notify {{ {rep}; }};\n        notify yes;\n}};')
open(p, 'w').write(s[:i] + nuevo + s[j:])
PY
# Registro del secundario en la zona (ns2) y serial nuevo
grep -q "^ns2 " $F || {
  sed -i "s/^@       IN NS   ns1.$Z./@       IN NS   ns1.$Z.\n@       IN NS   ns2.$Z./" $F
  sed -i "s/^ns1     IN A    \(.*\)$/ns1     IN A    \1\nns2     IN A    $REP\nreplica     IN A     $REP/" $F
}
S=$(grep -oE '[0-9]{10}' $F | head -1); N=$(( S + 1 )); sed -i "0,/$S/s//$N/" $F
named-checkzone $Z $F >/dev/null && named-checkconf || { echo "ERROR: restaurando"; cp -a "$BK/named.conf.local" $LOCAL; cp -a "$BK/db.$Z" $F; exit 1; }
rndc reconfig; rndc reload $Z >/dev/null
sed -n "/zone \"$Z\"/,/^};/p" $LOCAL
echo "Serial: $N  |  ns2.$Z -> $(dig +short @127.0.0.1 ns2.$Z)"
echo "LISTO en SRV-BD. Ahora en damian:  bash 03-dns-secundario-damian.sh"
echo "Volver atras: cp -a $BK/named.conf.local $LOCAL; cp -a $BK/db.$Z $F; rndc reconfig; rndc reload $Z"
