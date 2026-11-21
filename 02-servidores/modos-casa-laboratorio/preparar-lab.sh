#!/bin/bash
# =====================================================================
#  PREPARAR LABORATORIO - Centro Educativo Mejoland  (ejecutar en los 7 servidores, root)
#
#  Se ejecuta con acceso remoto por Tailscale y no interrumpe los servicios.
#  Prepara el despliegue en el laboratorio:
#    - Las configuraciones usan nombres (srv-bd.proyecto.local...) en lugar de IP de Tailscale.
#      En modo casa los nombres apuntan a Tailscale; en el laboratorio, a las IP del diseno.
#    - Instala modo-lab / modo-casa (iguales en los 7 servidores): red, /etc/hosts, DNS y servicios propios.
#    - srv-bd y damian: IP virtual 192.168.40.100 para EduNova (la toma el servidor activo).
#    - correo: proxy inverso de la DMZ con certificado propio (lo que se publica a Internet).
#    - MariaDB: replica los usuarios "@IP de Tailscale" como "@IP del laboratorio" (sin tocar la replicacion).
#  No reinicia OpenLDAP, no modifica ACL ni la red. Guarda respaldo de todo lo que modifica.
#
#  Uso:  bash preparar-lab.sh            (en srv-bd y damian copiar tambien /tmp/server.js)
#  modo-lab cambia la red y corta el acceso remoto: ejecutarlo solo en el laboratorio, desde la consola.
#  Si /tmp/corregir-modos.sh existe, se ejecuta al final para instalar los modos de red.
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root (sudo -i)"; exit 1; }
H=$(hostname -s | tr 'A-Z' 'a-z')
case "$H" in
  srv-bd)        ROL=srv-bd;        LAB_IP=192.168.40.10; LAB_GW=192.168.40.1 ;;
  damian*)       ROL=damian;        LAB_IP=192.168.40.13; LAB_GW=192.168.40.1 ;;
  correo*)       ROL=correo;        LAB_IP=192.168.60.10; LAB_GW=192.168.60.1 ;;
  srv-aaa-1)     ROL=srv-aaa-1;     LAB_IP=192.168.40.11; LAB_GW=192.168.40.1 ;;
  srv-aaa-2)     ROL=srv-aaa-2;     LAB_IP=192.168.40.12; LAB_GW=192.168.40.1 ;;
  srv-monitoreo) ROL=srv-monitoreo; LAB_IP=192.168.40.20; LAB_GW=192.168.40.1 ;;
  srv-apps)      ROL=srv-apps;      LAB_IP=192.168.40.21; LAB_GW=192.168.40.1 ;;
  *) echo "No reconozco este equipo ($H)."; exit 1 ;;
esac
R=/etc/mejoland/red; mkdir -p $R
BK=/root/proyecto/antes-de-preparar-lab-$(date +%Y%m%d-%H%M%S); mkdir -p $BK; chmod 700 $BK
paso() { echo; echo "== $*"; }
ok()   { echo "  [OK] $*"; }
av()   { echo "  [AVISO] $*"; }
resp() { for f in "$@"; do [ -e "$f" ] && { mkdir -p "$BK$(dirname "$f")"; cp -a "$f" "$BK$f"; }; done; }
echo "################ PREPARAR LABORATORIO: $ROL ($H) ################"

# Tabla de equipos: nombre | IP Tailscale | IP laboratorio
TABLA="srv-bd 100.89.203.22 192.168.40.10
srv-bd-replica 100.93.52.67 192.168.40.13
correo 100.65.119.48 192.168.60.10
srv-aaa-1 100.75.163.23 192.168.40.11
srv-aaa-2 100.74.49.76 192.168.40.12
srv-monitoreo 100.123.222.5 192.168.40.20
srv-apps 100.107.96.3 192.168.40.21"
echo "$TABLA" > $R/tabla.txt
# Reemplaza IP de Tailscale por nombres dentro de archivos (con respaldo)
a_nombres() { for f in "$@"; do [ -f "$f" ] || continue; resp "$f"
  python3 - "$f" "$R/tabla.txt" <<'PY'
import sys, re
f, t = sys.argv[1], sys.argv[2]; s = open(f, encoding='utf-8', errors='surrogateescape').read(); o = s
for l in open(t):
    n, ts, lab = l.split()
    s = re.sub(r'(?<![\d.])' + re.escape(ts) + r'(?![\d])', n + '.proyecto.local', s)
if s != o:
    open(f, 'w', encoding='utf-8', errors='surrogateescape').write(s); print(f"  [OK] {f}: IP de Tailscale -> nombres")
PY
done; }

# ---------------------------------------------------------------------
paso "1 Interfaz cableada del laboratorio"
IF=$(ip -o link | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -E '^(en|eth)' | head -1)
[ -n "$IF" ] || { echo "  No encuentro una interfaz cableada. No se cambio nada."; exit 1; }
ok "Interfaz: $IF  ->  en el lab: $LAB_IP/24 puerta $LAB_GW"
grep -q '100.100.100.100' /etc/resolv.conf && TS_DNS=1 || TS_DNS=0
cat > $R/rol.conf <<EOF
ROL=$ROL
IF=$IF
LAB_IP=$LAB_IP
LAB_GW=$LAB_GW
TS_DNS=$TS_DNS
VIP=192.168.40.100
EOF
[ -f $R/interfaces.casa ] || cp -a /etc/network/interfaces $R/interfaces.casa
[ -f $R/resolv.casa ] || cp -L /etc/resolv.conf $R/resolv.casa
DNS_LAB="192.168.40.10 192.168.40.13"; [ "$ROL" = srv-bd ] && DNS_LAB="127.0.0.1 192.168.40.13"; [ "$ROL" = damian ] && DNS_LAB="127.0.0.1 192.168.40.10"
cat > $R/interfaces.lab <<EOF
# Red del LABORATORIO (la instala modo-lab; modo-casa vuelve a interfaces.casa)
auto lo
iface lo inet loopback

auto $IF
iface $IF inet static
    address $LAB_IP/24
    gateway $LAB_GW
EOF
{ for d in $DNS_LAB; do echo "nameserver $d"; done; echo "search proyecto.local"; } > $R/resolv.lab
ok "Guardadas: interfaces.casa (la actual), interfaces.lab, resolv.casa, resolv.lab en $R"

# ---------------------------------------------------------------------
paso "2 Nombres de los servidores (/etc/hosts por modo)"
{ echo "# >>> MEJOLAND-RED casa (lo administran modo-lab / modo-casa)"
  while read -r n ts lab; do [ "$n" = srv-bd-replica ] && x=" damian.proyecto.local" || x=""; echo "$ts  $n.proyecto.local $n$x"; done < $R/tabla.txt
  echo "# <<< MEJOLAND-RED"; } > $R/hosts.casa
{ echo "# >>> MEJOLAND-RED laboratorio (lo administran modo-lab / modo-casa)"
  while read -r n ts lab; do [ "$n" = srv-bd-replica ] && x=" damian.proyecto.local" || x=""; echo "$lab  $n.proyecto.local $n$x"; done < $R/tabla.txt
  echo "192.168.40.100  plataforma.proyecto.local plataforma"
  [ "$ROL" = correo ] || echo "192.168.60.10  mejoland.edu.ec www.mejoland.edu.ec"
  echo "# <<< MEJOLAND-RED"; } > $R/hosts.lab

cat > $R/funciones.sh <<'FUN'
# Funciones comunes de modo-lab / modo-casa (Centro Educativo Mejoland)
. /etc/mejoland/red/rol.conf
R=/etc/mejoland/red
modo_actual() { cat /etc/mejoland/modo 2>/dev/null || echo casa; }
poner_hosts() {   # $1 = casa | lab
  python3 - "$R/hosts.$1" <<'PY'
import sys, re
nombres = {'srv-bd','srv-bd-replica','damian','correo','srv-aaa-1','srv-aaa-2','srv-apps','srv-monitoreo','plataforma','mejoland.edu.ec','www.mejoland.edu.ec'}
out, salta = [], False
for l in open('/etc/hosts').read().splitlines():
    if re.match(r'#\s*>>>\s*(TAILSCALE|MEJOLAND-RED)', l): salta = True; continue
    if re.match(r'#\s*<<<\s*(TAILSCALE|MEJOLAND-RED)', l): salta = False; continue
    if salta: continue
    c = l.split('#')[0].split()
    if c and not re.match(r'^(127\.|::1|fe|ff)', c[0]) and any(x in nombres or (x.endswith('.proyecto.local') and x.split('.')[0] in nombres) for x in c[1:]):
        continue
    out.append(l)
while out and not out[-1].strip(): out.pop()
open('/etc/hosts', 'w').write('\n'.join(out) + '\n\n' + open(sys.argv[1]).read())
PY
}
cambiar_serial() {   # sube el serial de una zona DNS (formato AAMMDDHHMM, siempre mayor)
  python3 - "$1" <<'PY'
import sys, re, time
f = sys.argv[1]; s = open(f).read(); nuevo = int(time.strftime('%y%m%d%H%M'))
m = re.search(r'(\d{6,10})(\s*;\s*[Ss]erial)', s)
if not m: print("  [AVISO] no encontre el serial en", f); sys.exit(0)
v = max(nuevo, int(m.group(1)) + 1)
open(f, 'w').write(s[:m.start(1)] + str(v) + s[m.end(1):])
PY
}
FUN
. $R/funciones.sh
resp /etc/hosts
poner_hosts casa
for n in srv-bd srv-bd-replica correo srv-apps srv-monitoreo srv-aaa-1 srv-aaa-2; do
  printf '  %-26s %s\n' "$n.proyecto.local" "$(getent hosts $n.proyecto.local | awk '{print $1}' | head -1)"
done
echo casa > /etc/mejoland/modo

# ---------------------------------------------------------------------
paso "3 Paquetes que el laboratorio necesita (se instalan ahora que hay Internet)"
PK="iputils-arping dnsutils"
[ "$ROL" = correo ] && PK="$PK openssl"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $PK >/dev/null 2>&1 && ok "$PK" || av "no se pudieron instalar: $PK"

# ---------------------------------------------------------------------
if command -v mariadb >/dev/null 2>&1 && mariadb -N -e "SELECT 1" >/dev/null 2>&1; then
paso "4 MariaDB: usuarios @IP-Tailscale copiados a @IP-laboratorio (solo en este servidor, sin replicar)"
python3 - "$R/tabla.txt" <<'PY'
import sys, subprocess
mapa = {}
for l in open(sys.argv[1]):
    n, ts, lab = l.split(); mapa[ts] = lab
def q(sql):
    r = subprocess.run(['mariadb', '-N', '-B', '-r', '-e', sql], capture_output=True, text=True)
    if r.returncode: raise RuntimeError(r.stderr.strip())
    return [x for x in r.stdout.splitlines() if x]
usuarios = [l.split('\t') for l in q("SELECT User, Host FROM mysql.user")]
existentes = {(u, h) for u, h in usuarios}
n = 0
for u, h in usuarios:
    if h not in mapa: continue
    lab = mapa[h]
    if (u, lab) in existentes: print(f"  ya existe '{u}'@'{lab}'"); continue
    try:
        crear = q(f"SHOW CREATE USER `{u}`@`{h}`")[0].replace(f"@`{h}`", f"@`{lab}`").replace(f"@'{h}'", f"@'{lab}'")
        crear = crear.replace('CREATE USER ', 'CREATE USER IF NOT EXISTS ', 1)
        grants = [g.replace(f"@`{h}`", f"@`{lab}`").replace(f"@'{h}'", f"@'{lab}'") for g in q(f"SHOW GRANTS FOR `{u}`@`{h}`")]
        q("SET SESSION sql_log_bin=0; " + crear + "; " + "; ".join(grants) + ";")
        n += 1; print(f"  [OK] '{u}'@'{h}'  ->  '{u}'@'{lab}'")
    except Exception as e:
        print(f"  [AVISO] '{u}'@'{h}': {e}")
print(f"  {n} usuario(s) nuevo(s). Los de Tailscale se mantienen (casa sigue igual).")
PY
BA=$(mariadb -N -e "SELECT @@bind_address" 2>/dev/null)
case "$BA" in ""|0.0.0.0|"*"|"::") ok "MariaDB escucha en todas las interfaces ($BA)";; 127.0.0.1|localhost) ok "MariaDB solo local ($BA)";; *) av "MariaDB escucha solo en $BA: en el laboratorio no la alcanzaran. Cambiar bind-address a 0.0.0.0";; esac
fi

# ---------------------------------------------------------------------
UFW=0; ufw status 2>/dev/null | grep -q "Status: active" && UFW=1
regla() { [ $UFW -eq 1 ] && ufw "$@" >/dev/null 2>&1; }

# ---------------------------------------------------------------------
edunova() {   # srv-bd y damian
  paso "EduNova: nombres en .env y escucha en la red (IP virtual)"
  E=/var/www/lms-backend/.env; B=/var/www/lms-backend
  a_nombres $E
  grep -q '^HOST=' $E && sed -i 's/^HOST=.*/HOST=0.0.0.0/' $E || echo 'HOST=0.0.0.0' >> $E
  grep -q '^PROXY_DMZ=' $E || echo 'PROXY_DMZ="192.168.60.10,100.65.119.48"' >> $E
  ok "HOST=0.0.0.0 y PROXY_DMZ en .env"
  if [ -f /tmp/server.js ] && grep -q "X-Mejoland-Internet" /tmp/server.js && node --check /tmp/server.js; then
    resp $B/server.js; install -m 640 -o root -g lms /tmp/server.js $B/server.js && ok "server.js instalado"
  else av "no hay /tmp/server.js: EduNova conserva el archivo instalado"; fi
  J=/etc/edunova/servicios.json; resp $J
  python3 - "$J" "$R" <<'PY'
import json, sys, re, copy
J, R = sys.argv[1], sys.argv[2]
d = json.load(open(J, encoding='utf-8'))
def publica(s):
    u, i = s.get('url', ''), s.get('id', '')
    if '/glpi' in u or i == 'glpi': return '/glpi/'
    if '/nube' in u or i == 'nube': return '/nube/'
    if i == 'correo' or 'roundcube' in u or 'webmail' in u: return '/webmail/'
    return None
for s in d['servicios']:
    p = publica(s)
    if p: s['url_publica'] = p
    elif str(s.get('url_publica', '')).startswith('https://') and ':8443' in s['url_publica']: s.pop('url_publica')
json.dump(d, open(R + '/servicios.casa.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
lab = copy.deepcopy(d)
ips = {l.split()[1]: l.split()[0] for l in open(R + '/tabla.txt')}
for s in lab['servicios']:
    u = s.get('url', '')
    if not u or u.startswith('app:'): continue
    p = publica(s)
    if p: s['url'] = 'https://mejoland.edu.ec' + p
    elif re.match(r'https://srv-bd\.[^/]+\.ts\.net/?$', u): s['url'] = 'http://srv-bd.proyecto.local:3000/'
    else:
        u = re.sub(r'https://srv-bd\.[^/]+\.ts\.net/', 'http://srv-bd.proyecto.local/', u)
        u = re.sub(r'https://(srv-apps|srv-monitoreo|correo)\.[^/]+\.ts\.net/', r'http://\1.proyecto.local/', u)
        for ip, n in ips.items(): u = u.replace('//' + ip + '/', '//' + n + '.proyecto.local/').replace('//' + ip + ':', '//' + n + '.proyecto.local:')
        s['url'] = u
json.dump(lab, open(R + '/servicios.lab.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
for a, b in zip(d['servicios'], lab['servicios']):
    if a.get('url') != b.get('url') or a.get('url_publica'): print(f"  {a.get('nombre',''):<26} casa: {a.get('url','')}\n  {'':<26} lab:  {b.get('url','')}   publica: {b.get('url_publica','-')}")
PY
  install -m 644 $R/servicios.casa.json $J && ok "servicios.json (casa) con url_publica relativa; version lab en $R/servicios.lab.json"
  regla allow from 192.168.0.0/16 to any port 80,3001 proto tcp
  regla allow from 100.65.119.48 to any port 3001 proto tcp
  if systemctl is-active -q lms; then systemctl restart lms; sleep 3; echo -n "  EduNova en 3001: "; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3001/; fi
  if timeout 10 tailscale funnel status 2>/dev/null | grep -q ':8443'; then
    timeout 15 tailscale funnel --https=8443 off </dev/null >/dev/null 2>&1 && ok "Funnel 8443 apagado (no se publica nada a Internet desde casa)"
  else ok "Funnel no publicado en este equipo"; fi
}

ha_vip() {    # srv-bd y damian: IP virtual del laboratorio dentro de mejoland-ha
  paso "Alta disponibilidad: IP virtual 192.168.40.100 (solo actua en modo laboratorio)"
  M=/usr/local/sbin/mejoland-ha; resp $M /etc/mejoland-ha/ha.conf
  python3 - "$M" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
if 'vip_poner' in s: print("  el parche de IP virtual ya estaba"); sys.exit(0)
bloque = r'''
# --- IP virtual del laboratorio (preparar-lab). En casa no hace nada: se usa svc:mejoland de Tailscale. ---
VIP=192.168.40.100
modo_red() { cat /etc/mejoland/modo 2>/dev/null || echo casa; }
vip_if() { ip -4 -o addr show | awk '$4 ~ /^192\.168\.40\./ && $4 != "192.168.40.100/24" {print $2; exit}'; }
vip_poner() { local i; i=$(vip_if); [ -n "$i" ] || return 1
  ip -4 addr show dev "$i" | grep -q " $VIP/" && return 0
  ip addr add $VIP/24 dev "$i" && { arping -q -U -c 3 -I "$i" $VIP >/dev/null 2>&1; log "IP virtual $VIP puesta en $i (este equipo atiende EduNova)"; }; }
vip_quitar() { local i; for i in $(ip -4 -o addr show | awk '$4=="192.168.40.100/24"{print $2}'); do ip addr del $VIP/24 dev "$i" && log "IP virtual $VIP retirada de $i"; done; return 0; }
tailscale() {
  if [ "${1:-}" = serve ] && [ "$(modo_red)" = lab ]; then case "${2:-}" in advertise) vip_poner;; drain) vip_quitar;; esac; fi
  command tailscale "$@"
}
'''
m = re.search(r'\nlog\(\) \{[^\n]*\n', s); assert m, "no encuentro log()"
s = s[:m.end()] + bloque + s[m.end():]
a = 'anunciado() {\n'
assert a in s, "no encuentro anunciado() (falta parche-anuncio)"
s = s.replace(a, a + '  if [ "$(modo_red)" = lab ]; then ip -4 addr show | grep -q " $VIP/" && return 0 || return 1; fi\n', 1)
open(p, 'w').write(s); print("  [OK] mejoland-ha: en modo lab, 'anunciar' = poner la IP virtual y 'retirar' = quitarla")
PY
  bash -n $M || { echo "  ERROR de sintaxis: restaurando mejoland-ha"; cp -a $BK$M $M; }
  cp -a /etc/mejoland-ha/ha.conf $R/ha.conf.casa
  if [ "$ROL" = srv-bd ]; then
    sed -e 's#^RESPALDO_TS=.*#RESPALDO_TS=192.168.40.13#' \
        -e 's#^TESTIGOS=.*#TESTIGOS="192.168.60.10:993 192.168.60.10:25 192.168.40.11:22"#' $R/ha.conf.casa > $R/ha.conf.lab
  else
    sed -e 's#^PRINCIPAL_TS=.*#PRINCIPAL_TS=192.168.40.10#' \
        -e 's#^PRINCIPAL_URL=.*#PRINCIPAL_URL=http://192.168.40.10:3001/#' \
        -e 's#^TESTIGOS=.*#TESTIGOS="192.168.60.10:993 192.168.60.10:25 192.168.40.11:22"#' $R/ha.conf.casa > $R/ha.conf.lab
  fi
  ok "ha.conf.casa (la actual) y ha.conf.lab:"; sed 's/^/      /' $R/ha.conf.lab | grep -v -i pass
}

# ---------------------------------------------------------------------
case $ROL in
srv-bd)
  edunova; ha_vip
  paso "DNS: zona mejoland.edu.ec para casa y laboratorio"
  Z=/etc/bind/db.mejoland.edu.ec; resp $Z /etc/bind/named.conf.local
  cp -a $Z $R/db.mejoland.edu.ec.casa
  python3 - "$Z" "$R" <<'PY'
import sys, re
z, R = sys.argv[1], sys.argv[2]; s = open(z).read()
for l in open(R + '/tabla.txt'):
    n, ts, lab = l.split(); s = re.sub(r'(?<![\d.])' + re.escape(ts) + r'(?!\d)', lab, s)
pub = ('@', 'www', 'plataforma', 'webmail', 'glpi', 'nube')
s = '\n'.join(l for l in s.splitlines() if not re.match(r'^(%s)\s+(\d+\s+)?(IN\s+)?(A|CNAME)\s' % '|'.join(map(re.escape, pub)), l)) + '\n'
s += '; --- laboratorio: los servicios publicos entran por el proxy de la DMZ ---\n'
s += ''.join(f'{n:<12} IN A     192.168.60.10\n' for n in pub)
open(R + '/db.mejoland.edu.ec.lab', 'w').write(s)
PY
  named-checkzone mejoland.edu.ec $R/db.mejoland.edu.ec.lab >/dev/null && ok "zona de laboratorio valida ($R/db.mejoland.edu.ec.lab)" || av "la zona de laboratorio tiene errores: revisar"
  python3 - /etc/bind/named.conf.local <<'PY'
import sys, re
f = sys.argv[1]; s = open(f).read()
n = re.sub(r'also-notify\s*\{([^}]*)\}', lambda m: m.group(0) if '192.168.40.13' in m.group(1) else 'also-notify {' + m.group(1).rstrip() + ' 192.168.40.13; }', s)
if n != s: open(f, 'w').write(n); print("  [OK] also-notify incluye 192.168.40.13 (damian en el lab)")
PY
  named-checkconf && rndc reconfig >/dev/null 2>&1 && ok "named recargado"
  S=/var/www/secretaria/index.php
  if [ -f $S ]; then resp $S
    grep -o "PLATAFORMA_URL *= *'[^']*'" $S | head -1 | sed "s/.*'\(.*\)'/\1/" > $R/secretaria-url.casa
    echo "https://mejoland.edu.ec/plataforma/" > $R/secretaria-url.lab
    ok "Panel de secretaria: enlace a EduNova casa=$(cat $R/secretaria-url.casa) lab=$(cat $R/secretaria-url.lab)"
  fi
  regla allow from 192.168.0.0/16 to any port 443,3000 proto tcp
  ;;
damian)
  edunova; ha_vip
  paso "Replica LDAP: proveedor por nombre (en vivo, sin reiniciar slapd ni tocar ACL)"
  python3 - <<'PY'
import subprocess, base64, re
r = subprocess.run(['ldapsearch', '-Q', '-LLL', '-Y', 'EXTERNAL', '-H', 'ldapi:///', '-o', 'ldif-wrap=no', '-b', 'cn=config',
                    '(olcSyncrepl=*)', 'olcSyncrepl', 'olcUpdateRef'], capture_output=True, text=True)
dn, vals = None, {'olcSyncrepl': [], 'olcUpdateRef': []}
for l in r.stdout.splitlines():
    m = re.match(r'^(\w+)(::?) ?(.*)$', l)
    if not m: continue
    k, sep, v = m.groups()
    if sep == '::': v = base64.b64decode(v).decode()
    if k == 'dn': dn = v
    elif k in vals: vals[k].append(v)
if not dn or not vals['olcSyncrepl']: print("  [AVISO] no encontre la configuracion de replica LDAP"); raise SystemExit
nuevo = {k: [x.replace('100.89.203.22', 'srv-bd.proyecto.local') for x in v] for k, v in vals.items()}
if nuevo == vals: print("  ya usa nombres"); raise SystemExit
ldif = f"dn: {dn}\nchangetype: modify\n"
for k, v in nuevo.items():
    if v and v != vals[k]:
        ldif += f"replace: {k}\n" + ''.join(f"{k}:: {base64.b64encode(x.encode()).decode()}\n" for x in v) + "-\n"
r = subprocess.run(['ldapmodify', '-Q', '-Y', 'EXTERNAL', '-H', 'ldapi:///'], input=ldif, capture_output=True, text=True)
print("  [OK] proveedor LDAP = ldap://srv-bd.proyecto.local:389" if r.returncode == 0 else "  [AVISO] ldapmodify: " + r.stderr.strip())
PY
  paso "Replica MariaDB: maestro por nombre (con GTID, sin perder posicion)"
  MH=$(mariadb -e "SHOW SLAVE STATUS\G" | awk '/Master_Host:/{print $2}')
  GT=$(mariadb -e "SHOW SLAVE STATUS\G" | awk '/Using_Gtid:/{print $2}')
  ST=$(cat /var/lib/mejoland-ha/estado 2>/dev/null)
  if [ "$MH" = 100.89.203.22 ] && [ -n "$GT" ] && [ "$GT" != No ] && [ "${ST:-ESPERA}" = ESPERA ]; then
    mariadb -e "STOP SLAVE; CHANGE MASTER TO MASTER_HOST='srv-bd.proyecto.local'; START SLAVE;" && sleep 3
    mariadb -e "SHOW SLAVE STATUS\G" | grep -E "Master_Host|Slave_IO_Running|Slave_SQL_Running:|Seconds_Behind" | sed 's/^ */  /'
  else ok "sin cambio (Master_Host=$MH, GTID=$GT, estado HA=$ST)"; fi
  paso "DNS secundario: maestro casa/lab"
  resp /etc/bind/named.conf.local
  cp -a /etc/bind/named.conf.local $R/named.conf.local.casa
  sed 's/100\.89\.203\.22/192.168.40.10/g' $R/named.conf.local.casa > $R/named.conf.local.lab
  ok "named.conf.local.casa y .lab guardados (maestro 192.168.40.10 en el lab)"
  if [ $UFW -eq 1 ]; then
    regla allow from 192.168.0.0/16 to any port 53; regla allow 67/udp
    regla allow from 192.168.40.0/24 to any port 389,3306 proto tcp; regla allow from 192.168.60.10 to any port 389,3306 proto tcp
  fi
  ;;
correo)
  paso "Proxy inverso de la DMZ (lo que se publica a Internet en el laboratorio)"
  C=/etc/mejoland/ca; mkdir -p $C; chmod 700 $C
  if [ ! -f $C/ca-mejoland.key ]; then
    openssl req -x509 -newkey rsa:3072 -nodes -days 3650 -subj "/O=Centro Educativo Mejoland/CN=Mejoland CA" \
      -keyout $C/ca-mejoland.key -out $C/ca-mejoland.crt 2>/dev/null && ok "Autoridad certificadora propia creada (Mejoland CA)"
  fi
  if [ ! -f $C/mejoland.crt ]; then
    openssl req -newkey rsa:2048 -nodes -subj "/O=Centro Educativo Mejoland/CN=mejoland.edu.ec" -keyout $C/mejoland.key -out $C/mejoland.csr 2>/dev/null
    printf 'subjectAltName=DNS:mejoland.edu.ec,DNS:www.mejoland.edu.ec,DNS:correo.mejoland.edu.ec,DNS:correo.proyecto.local,IP:200.10.10.2,IP:200.10.10.6,IP:192.168.60.10,IP:100.65.119.48\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n' > $C/ext.cnf
    openssl x509 -req -in $C/mejoland.csr -CA $C/ca-mejoland.crt -CAkey $C/ca-mejoland.key -CAcreateserial -days 825 -sha256 \
      -extfile $C/ext.cnf -out $C/mejoland.crt 2>/dev/null && ok "Certificado de mejoland.edu.ec firmado por Mejoland CA (825 dias)"
  fi
  chmod 600 $C/*.key; cp $C/ca-mejoland.crt /var/www/html/ca-mejoland.crt && chmod 644 /var/www/html/ca-mejoland.crt
  ok "Certificado de la CA para instalar en los equipos: http://correo/ca-mejoland.crt"
  RC=""; for p in roundcube webmail correo; do c=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/$p/); case $c in 200|302) RC=$p; break;; esac; done
  [ -n "$RC" ] && ok "Correo web encontrado en /$RC/" || { RC=roundcube; av "no encontre el correo web; uso /roundcube/"; }
  cat > $R/destinos.casa <<'EOF'
# Destinos del proxy en CASA (por Tailscale). Lo instala modo-casa.
Define EDUNOVA_URL https://mejoland.tailae692e.ts.net/
Define APPS_URL http://srv-apps.proyecto.local/
EOF
  cat > $R/destinos.lab <<'EOF'
# Destinos del proxy en el LABORATORIO (IP virtual de EduNova). Lo instala modo-lab.
Define EDUNOVA_URL http://192.168.40.100:3001/
Define APPS_URL http://srv-apps.proyecto.local/
EOF
  resp /etc/apache2/conf-available/mejoland-destinos.conf /etc/apache2/sites-available/mejoland-publico.conf
  cp $R/destinos.casa /etc/apache2/conf-available/mejoland-destinos.conf
  WM=""; [ "$RC" != webmail ] && WM="RedirectMatch ^/webmail(/.*)?\$ /$RC/"
  cat > /etc/apache2/sites-available/mejoland-publico.conf <<EOF
# Centro Educativo Mejoland - PROXY INVERSO DE LA DMZ (correo, 192.168.60.10)
# Desde Internet el router hace NAT de 80/443 a este servidor; los servidores internos nunca se publican.
<VirtualHost *:80>
    ServerName mejoland.edu.ec
    ServerAlias www.mejoland.edu.ec
    RedirectMatch ^/(.*)\$ https://mejoland.edu.ec/\$1
</VirtualHost>
<VirtualHost *:443>
    ServerName mejoland.edu.ec
    ServerAlias www.mejoland.edu.ec correo.mejoland.edu.ec 200.10.10.2 200.10.10.6 192.168.60.10 100.65.119.48 correo.tailae692e.ts.net
    SSLEngine on
    SSLCertificateFile    /etc/mejoland/ca/mejoland.crt
    SSLCertificateKeyFile /etc/mejoland/ca/mejoland.key
    Header always set X-Content-Type-Options nosniff
    Header always set Referrer-Policy same-origin
    # Peticiones de fuera de la red privada (Internet a traves del NAT) se marcan para EduNova
    SetEnvIf Remote_Addr "^(127\.|10\.|192\.168\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)" red_interna
    RequestHeader set X-Mejoland-Internet "1" env=!red_interna
    RequestHeader unset X-Mejoland-Internet env=red_interna
    RequestHeader set X-Forwarded-Proto "https"
    RedirectMatch ^/\$ /plataforma/
    RedirectMatch ^/(plataforma|glpi|nube)\$ /\$1/
    $WM
    # Nunca se publican: administracion de cuentas, panel de secretaria, monitoreo
    <LocationMatch "^/(lam|secretaria|zabbix|phpmyadmin|grafana)">
        Require all denied
    </LocationMatch>
    SSLProxyEngine on
    ProxyRequests off
    ProxyTimeout 120
    ProxyPass        /plataforma/ \${EDUNOVA_URL}
    ProxyPassReverse /plataforma/ \${EDUNOVA_URL}
    ProxyPass        /glpi/ \${APPS_URL}glpi/
    ProxyPassReverse /glpi/ \${APPS_URL}glpi/
    ProxyPass        /nube/ \${APPS_URL}nube/
    ProxyPassReverse /nube/ \${APPS_URL}nube/
    Redirect 301 /.well-known/carddav /nube/remote.php/dav
    Redirect 301 /.well-known/caldav  /nube/remote.php/dav
    ErrorLog \${APACHE_LOG_DIR}/mejoland-publico-error.log
    CustomLog \${APACHE_LOG_DIR}/mejoland-publico.log combined
</VirtualHost>
EOF
  a2enmod -q ssl proxy proxy_http headers rewrite >/dev/null 2>&1
  a2enconf -q mejoland-destinos >/dev/null 2>&1; a2ensite -q mejoland-publico >/dev/null 2>&1
  if apache2ctl configtest >/dev/null 2>&1; then systemctl reload apache2 && ok "Apache: sitio mejoland-publico activo (443)"
  else av "error en Apache: desactivo el sitio"; apache2ctl configtest 2>&1 | tail -3; a2dissite -q mejoland-publico; systemctl reload apache2; fi
  RCF=$(ls /etc/roundcube/config.inc.php /var/www/*/config/config.inc.php 2>/dev/null | head -1)
  if [ -n "$RCF" ] && ! grep -q login_rate_limit "$RCF"; then resp "$RCF"; echo "\$config['login_rate_limit'] = 3;" >> "$RCF"; ok "Correo web: maximo 3 intentos de ingreso por minuto"; fi
  regla allow proto tcp to any port 25,80,443,587,993
  ;;
srv-apps)
  paso "Nextcloud: acepta el proxy de la DMZ y LDAP por nombre"
  NC=/var/www/nextcloud; occ() { runuser -u www-data -- php $NC/occ "$@"; }
  resp $NC/config/config.php
  python3 - <<'PY'
import json, subprocess
occ = lambda *a: subprocess.run(['runuser', '-u', 'www-data', '--', 'php', '/var/www/nextcloud/occ', *a], capture_output=True, text=True)
def lista(k):
    r = occ('config:system:get', k, '--output=json');
    try: v = json.loads(r.stdout or 'null')
    except Exception: v = None
    return list(v.values()) if isinstance(v, dict) else (v or [])
for k, nuevos in [('trusted_domains', ['mejoland.edu.ec', 'www.mejoland.edu.ec', '192.168.40.21', 'srv-apps.proyecto.local']),
                  ('trusted_proxies', ['192.168.60.10', '100.65.119.48'])]:
    v = lista(k); i = len(v) + 10
    for n in nuevos:
        if n not in v: occ('config:system:set', k, str(i), '--value=' + n); i += 1; print(f"  [OK] {k}: {n}")
for k, v in [('overwritecondaddr', r'^(192\.168\.60\.10|100\.65\.119\.48)$'), ('overwritehost', 'mejoland.edu.ec'),
             ('overwriteprotocol', 'https'), ('overwritewebroot', '/nube')]:
    occ('config:system:set', k, '--value=' + v)
print("  [OK] Solo cuando la peticion viene del proxy de la DMZ, Nextcloud responde como https://mejoland.edu.ec/nube")
r = occ('ldap:show-config', 's01', '--output=json')
try: c = json.loads(r.stdout)
except Exception: c = {}
c = c.get('s01', c)
for k in ('ldapHost', 'ldapBackupHost'):
    v = str(c.get(k, '')); n = v.replace('100.89.203.22', 'srv-bd.proyecto.local').replace('100.93.52.67', 'srv-bd-replica.proyecto.local')
    if n != v: occ('ldap:set-config', 's01', k, n); print(f"  [OK] Nextcloud {k}: {v} -> {n}")
    else: print(f"  Nextcloud {k}: {v or '(vacio)'}")
PY
  [ -z "$(runuser -u www-data -- php $NC/occ ldap:show-config s01 2>/dev/null | grep -i ldapBackupHost | grep -i srv-bd-replica)" ] && {
    runuser -u www-data -- php $NC/occ ldap:set-config s01 ldapBackupHost srv-bd-replica.proyecto.local >/dev/null 2>&1
    runuser -u www-data -- php $NC/occ ldap:set-config s01 ldapBackupPort 389 >/dev/null 2>&1; ok "Nextcloud: LDAP de respaldo = damian"; }
  echo -n "  Prueba LDAP de Nextcloud: "; runuser -u www-data -- php $NC/occ ldap:test-config s01 2>&1 | tail -1
  paso "GLPI: directorio LDAP por nombre"
  GDB=$(mariadb -N -e "SELECT table_schema FROM information_schema.tables WHERE table_name='glpi_authldaps' LIMIT 1")
  glpi() { mariadb "${GDB:-glpi}" "$@"; }
  for t in glpi_authldaps glpi_authldapreplicates; do
    glpi -e "UPDATE $t SET host=REPLACE(REPLACE(host,'100.89.203.22','srv-bd.proyecto.local'),'100.93.52.67','srv-bd-replica.proyecto.local')" 2>/dev/null
  done
  glpi -N -e "SELECT CONCAT('  GLPI LDAP: ',name,' -> ',host,':',port) FROM glpi_authldaps" 2>/dev/null
  if ! glpi -N -e "SELECT 1 FROM glpi_authldapreplicates WHERE host='srv-bd-replica.proyecto.local'" 2>/dev/null | grep -q 1; then
    glpi -e "INSERT INTO glpi_authldapreplicates (authldaps_id,host,port,name) SELECT id,'srv-bd-replica.proyecto.local',389,'damian (replica)' FROM glpi_authldaps ORDER BY id LIMIT 1" 2>/dev/null && ok "GLPI: LDAP de respaldo = damian"
  fi
  paso "Respaldos nocturnos hacia srv-bd por nombre"
  a_nombres /root/.mejoland/remoto-glpi.cnf /root/.mejoland/remoto-nextcloud.cnf
  regla allow from 192.168.0.0/16 to any port 80 proto tcp
  ;;
srv-monitoreo)
  paso "Zabbix: los equipos se vigilan por nombre (sirve en casa y en el laboratorio)"
  a_nombres /root/.mejoland/remoto-zabbix.cnf
  read -r -s -p "  Clave del usuario Admin de Zabbix: " ZP; echo
  ZP="$ZP" python3 - "$R/tabla.txt" <<'PY'
import json, os, sys, urllib.request
URL = "http://127.0.0.1/zabbix/api_jsonrpc.php"; tok = None
mapa = {l.split()[1]: l.split()[0] + '.proyecto.local' for l in open(sys.argv[1])}
def api(m, p):
    h = {"Content-Type": "application/json-rpc"}
    if tok: h["Authorization"] = "Bearer " + tok
    d = json.load(urllib.request.urlopen(urllib.request.Request(URL, json.dumps({"jsonrpc": "2.0", "method": m, "params": p, "id": 1}).encode(), h), timeout=20))
    if "error" in d: raise SystemExit(f"  [AVISO] Zabbix {m}: {d['error'].get('data')}")
    return d["result"]
tok = api("user.login", {"username": "Admin", "password": os.environ["ZP"]})
hosts = {h["hostid"]: h["host"] for h in api("host.get", {"output": ["hostid", "host"]})}
for i in api("hostinterface.get", {"output": ["interfaceid", "hostid", "ip", "dns", "useip", "port"]}):
    if i["ip"] in mapa and (i["useip"] == "1" or i["dns"] != mapa[i["ip"]]):
        api("hostinterface.update", {"interfaceid": i["interfaceid"], "dns": mapa[i["ip"]], "useip": 0})
        print(f"  [OK] {hosts.get(i['hostid'],'?'):<16} {i['ip']} -> {mapa[i['ip']]}")
    else:
        print(f"  {hosts.get(i['hostid'],'?'):<16} {'por nombre: ' + i['dns'] if i['useip']=='0' else i['ip']}")
api("user.logout", [])
PY
  regla allow from 192.168.0.0/16 to any port 80,10051 proto tcp
  ;;
srv-aaa-1|srv-aaa-2)
  paso "FreeRADIUS"
  grep -rl -E '100\.(89\.203\.22|93\.52\.67)' /etc/freeradius/3.0/mods-enabled/ 2>/dev/null | while read -r f; do a_nombres "$(readlink -f "$f")"; done
  ok "clients.conf ya tiene las redes del laboratorio (192.168.x)"
  ;;
esac

# ---------------------------------------------------------------------
paso "5 Instalando modo-lab / modo-casa / modo-red nuevos"
for f in /usr/local/sbin/modo-lab /usr/local/sbin/modo-casa; do [ -f $f ] && cp -a $f $BK/$(basename $f).anterior; done
cat > /usr/local/sbin/modo-lab <<'EOF'
#!/bin/bash
# =====================================================================
#  MODO LABORATORIO (Centro Educativo Mejoland). SOLO en el laboratorio, desde el teclado del servidor:
#  cambia la red a la del diseno y CORTA el acceso remoto de casa.   Volver:  modo-casa
# =====================================================================
set -u; . /etc/mejoland/red/funciones.sh
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
if [ "${1:-}" != "--si" ]; then
  echo "Este equipo ($ROL) pasara a la red del LABORATORIO: $IF = $LAB_IP/24, puerta $LAB_GW."
  echo "Se apaga el Wi-Fi y se corta cualquier acceso remoto desde casa."
  read -r -p "Escribe LAB para continuar: " r; [ "$r" = LAB ] || { echo "Cancelado."; exit 1; }
fi
log() { echo "  $*"; logger -t modo-lab "$*"; }
systemctl stop mejoland-ha.timer 2>/dev/null && log "Alta disponibilidad en pausa durante el cambio"
ifdown -a --exclude=lo >/dev/null 2>&1
command -v nmcli >/dev/null && { nmcli radio wifi off; nmcli dev disconnect "$IF" >/dev/null 2>&1
  printf '[main]\ndns=none\n[keyfile]\nunmanaged-devices=interface-name:%s\n' "$IF" > /etc/NetworkManager/conf.d/90-mejoland-lab.conf
  systemctl reload NetworkManager 2>/dev/null; log "Wi-Fi apagado; NetworkManager no toca $IF ni el DNS"; }
cp $R/interfaces.lab /etc/network/interfaces
ip addr flush dev "$IF" 2>/dev/null; ifup -a >/dev/null 2>&1 || systemctl restart networking
log "Red: $(ip -4 -o addr show dev "$IF" | awk '{print $4}')  puerta $LAB_GW"
tailscale set --accept-dns=false >/dev/null 2>&1
rm -f /etc/resolv.conf; cp $R/resolv.lab /etc/resolv.conf
poner_hosts lab; echo lab > /etc/mejoland/modo; log "Nombres y DNS del laboratorio"
case $ROL in
  srv-bd)
    cp $R/ha.conf.lab /etc/mejoland-ha/ha.conf
    cp $R/db.mejoland.edu.ec.lab /etc/bind/db.mejoland.edu.ec; cambiar_serial /etc/bind/db.mejoland.edu.ec
    install -m 644 $R/servicios.lab.json /etc/edunova/servicios.json
    [ -f $R/secretaria-url.lab ] && sed -i "s#\(PLATAFORMA_URL *= *'\)[^']*'#\1$(cat $R/secretaria-url.lab)'#" /var/www/secretaria/index.php
    systemctl restart chrony rsyslog named 2>/dev/null; systemctl restart kea-dhcp4-server 2>/dev/null
    PAR=192.168.40.13 ;;
  damian)
    cp $R/ha.conf.lab /etc/mejoland-ha/ha.conf; cp $R/named.conf.local.lab /etc/bind/named.conf.local
    install -m 644 $R/servicios.lab.json /etc/edunova/servicios.json
    systemctl restart named 2>/dev/null; systemctl restart kea-dhcp4-server 2>/dev/null
    PAR=192.168.40.10 ;;
  correo)
    cp $R/destinos.lab /etc/apache2/conf-available/mejoland-destinos.conf
    systemctl restart chrony rsyslog postfix dovecot 2>/dev/null; systemctl reload apache2 ;;
  srv-aaa-1|srv-aaa-2) systemctl restart freeradius 2>/dev/null ;;
  srv-apps) systemctl restart apache2 2>/dev/null ;;
  srv-monitoreo) systemctl restart zabbix-server 2>/dev/null ;;
esac
systemctl restart zabbix-agent2 2>/dev/null || systemctl restart zabbix-agent 2>/dev/null
if [ "$ROL" = srv-bd ] || [ "$ROL" = damian ]; then
  systemctl is-active -q lms && systemctl restart lms
  if ping -c 2 -W 2 $PAR >/dev/null 2>&1; then systemctl start mejoland-ha.timer; log "El otro servidor ($PAR) responde: alta disponibilidad reanudada"
  else log "AVISO: $PAR aun no responde. Cuando este en modo lab, ejecuta aqui:  systemctl start mejoland-ha.timer"; fi
fi
echo "== Pruebas"
ping -c 2 -W 2 $LAB_GW >/dev/null 2>&1 && echo "  puerta $LAB_GW: OK" || echo "  puerta $LAB_GW: NO RESPONDE (cable, VLAN del puerto o router)"
for n in srv-bd srv-bd-replica correo; do ping -c 1 -W 2 $n >/dev/null 2>&1 && echo "  $n: OK" || echo "  $n: no responde"; done
echo "Listo: $ROL en modo LABORATORIO. Revision completa: verificar-lab"
EOF
cat > /usr/local/sbin/modo-casa <<'EOF'
#!/bin/bash
# =====================================================================
#  MODO CASA (Centro Educativo Mejoland): vuelve a la red de casa con Tailscale.
# =====================================================================
set -u; . /etc/mejoland/red/funciones.sh
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
log() { echo "  $*"; logger -t modo-casa "$*"; }
systemctl stop mejoland-ha.timer 2>/dev/null
for i in $(ip -4 -o addr show | awk '$4=="192.168.40.100/24"{print $2}'); do ip addr del 192.168.40.100/24 dev $i; done
ifdown -a --exclude=lo >/dev/null 2>&1
cp $R/interfaces.casa /etc/network/interfaces
ip addr flush dev "$IF" 2>/dev/null
rm -f /etc/NetworkManager/conf.d/90-mejoland-lab.conf
command -v nmcli >/dev/null && { systemctl reload NetworkManager 2>/dev/null; nmcli radio wifi on; }
ifup -a >/dev/null 2>&1 || systemctl restart networking
poner_hosts casa; echo casa > /etc/mejoland/modo
if [ "$TS_DNS" = 1 ]; then tailscale set --accept-dns=true >/dev/null 2>&1; else rm -f /etc/resolv.conf; cp $R/resolv.casa /etc/resolv.conf; fi
case $ROL in
  srv-bd)
    cp $R/ha.conf.casa /etc/mejoland-ha/ha.conf
    cp $R/db.mejoland.edu.ec.casa /etc/bind/db.mejoland.edu.ec; cambiar_serial /etc/bind/db.mejoland.edu.ec
    install -m 644 $R/servicios.casa.json /etc/edunova/servicios.json
    [ -f $R/secretaria-url.casa ] && sed -i "s#\(PLATAFORMA_URL *= *'\)[^']*'#\1$(cat $R/secretaria-url.casa)'#" /var/www/secretaria/index.php
    systemctl restart chrony rsyslog named 2>/dev/null ;;
  damian)
    cp $R/ha.conf.casa /etc/mejoland-ha/ha.conf; cp $R/named.conf.local.casa /etc/bind/named.conf.local
    install -m 644 $R/servicios.casa.json /etc/edunova/servicios.json
    systemctl restart named 2>/dev/null ;;
  correo)
    cp $R/destinos.casa /etc/apache2/conf-available/mejoland-destinos.conf
    systemctl restart chrony rsyslog postfix dovecot 2>/dev/null; systemctl reload apache2 ;;
  srv-aaa-1|srv-aaa-2) systemctl restart freeradius 2>/dev/null ;;
  srv-apps) systemctl restart apache2 2>/dev/null ;;
  srv-monitoreo) systemctl restart zabbix-server 2>/dev/null ;;
esac
systemctl restart zabbix-agent2 2>/dev/null || systemctl restart zabbix-agent 2>/dev/null
sleep 8
if [ "$ROL" = srv-bd ] || [ "$ROL" = damian ]; then systemctl is-active -q lms && systemctl restart lms; systemctl start mejoland-ha.timer; fi
echo "== Pruebas"
ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1 && echo "  Internet: OK" || echo "  Internet: no (revisa Wi-Fi o cable)"
tailscale status >/dev/null 2>&1 && echo "  Tailscale: OK ($(tailscale ip -4 2>/dev/null))" || echo "  Tailscale: no conectado"
echo "Listo: $ROL en modo CASA."
EOF
cat > /usr/local/sbin/modo-red <<'EOF'
#!/bin/bash
. /etc/mejoland/red/funciones.sh
echo "$ROL: modo $(modo_actual) | $IF $(ip -4 -o addr show dev $IF 2>/dev/null | awk '{print $4}' | tr '\n' ' ')| IP virtual: $(ip -4 -o addr show | grep -q ' 192.168.40.100/' && echo SI || echo no)"
EOF
chmod 755 /usr/local/sbin/modo-lab /usr/local/sbin/modo-casa /usr/local/sbin/modo-red
[ -f /tmp/verificar-lab.sh ] && install -m 755 /tmp/verificar-lab.sh /usr/local/sbin/verificar-lab && ok "verificar-lab instalado"
bash -n /usr/local/sbin/modo-lab && bash -n /usr/local/sbin/modo-casa && ok "modo-lab, modo-casa y modo-red listos (NO ejecutar modo-lab en casa)"

# ---------------------------------------------------------------------
paso "6 Comprobacion: todo sigue funcionando en casa"
modo-red
for n in srv-bd srv-bd-replica correo srv-apps; do ping -c 1 -W 3 $n.proyecto.local >/dev/null 2>&1 && echo "  $n: OK" || echo "  $n: no responde (si esta apagado, es normal)"; done
case $ROL in
  srv-bd|damian) /usr/local/sbin/mejoland-ha estado 2>/dev/null | head -3 | sed 's/^/  /' ;;
  correo) for p in plataforma/ glpi/ nube/ webmail/; do printf '  https://correo/%-12s %s\n' "$p" "$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1/$p)"; done ;;
esac
[ $UFW -eq 1 ] && ok "Cortafuegos activo: reglas del laboratorio agregadas" || echo "  Cortafuegos (ufw) no activo en este equipo"
# Modos de red: generan hosts, DNS y enlaces para el modo activo
if [ -f /tmp/corregir-modos.sh ]; then paso "7 Modos de red (corregir-modos.sh)"; bash /tmp/corregir-modos.sh --sin-aplicar
else av "falta /tmp/corregir-modos.sh: ejecutarlo despues para instalar los modos de red."; fi
echo; echo "LISTO en $ROL. Respaldo de lo modificado: $BK"
