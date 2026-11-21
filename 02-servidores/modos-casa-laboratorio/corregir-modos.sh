#!/bin/bash
# =====================================================================
#  MODOS DE RED - Centro Educativo Mejoland   (root, en los 7 servidores; orden: srv-bd, damian, correo, el resto)
#
#  Instala modo-lab, modo-casa, modo-actualizar, modo-red y verificar-lab:
#   - Cada cambio de modo genera, a partir de la configuracion actual, /etc/hosts,
#     las zonas mejoland.edu.ec y proyecto.local (srv-bd) y los enlaces de EduNova.
#     El dominio y los enlaces quedan siempre con las IP del modo activo.
#   - El serial de las zonas se incrementa a partir del registro SOA, para que el DNS secundario se actualice.
#   - modo-lab usa la interfaz con enlace activo (incluido el adaptador USB) y retira la IP del laboratorio
#     de las demas interfaces, para evitar direcciones duplicadas.
#   - Equipos alcanzados por Tailscale en el laboratorio: REMOTOS en /etc/mejoland/red/lab.conf (por defecto las 3 VMs de la Mac).
#   - Secretaria y LAM por HTTPS; Zabbix por el proxy del correo (solo red interna); GLPI y Nextcloud publicados.
#   - Alta disponibilidad: se reanuda automaticamente cuando el otro servidor responde.
#   - Proxy del correo: las redes domesticas se tratan como Internet; acepta 10.1.40.13 y 10.1.60.10; redirige http -> https.
#   - srv-bd y damian: EduNova (3001) solo acepta conexiones del proxy, del otro servidor y de Zabbix.
#   - modo-actualizar regenera todo para el modo actual sin tocar la red (se puede usar por SSH).
#
#  No cambia la red ni el modo actual. Guarda un respaldo y un script deshacer.sh.
#  Uso:  bash corregir-modos.sh                  (aplica al modo actual con modo-actualizar)
#        bash corregir-modos.sh --sin-aplicar    (solo instala los comandos)
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root (sudo -i)"; exit 1; }
R=/etc/mejoland/red
[ -f $R/rol.conf ] && [ -f $R/tabla.txt ] || { echo "Falta /etc/mejoland/red (primero se ejecuta preparar-lab.sh en este equipo)"; exit 1; }
. $R/rol.conf
BK=/root/proyecto/corregir-modos-$(date +%Y%m%d-%H%M%S); mkdir -p $BK; chmod 700 $BK
ok() { echo "  [OK] $*"; }; av() { echo "  [AVISO] $*"; }
resp() { for f in "$@"; do [ -n "$f" ] && [ -e "$f" ] && { mkdir -p "$BK$(dirname "$f")"; cp -a "$f" "$BK$f"; }; done; }
echo "################ CORREGIR MODOS: $ROL ($(hostname -s)) - modo actual: $(cat /etc/mejoland/modo 2>/dev/null || echo casa) ################"

ZP=$(python3 - <<'PY'
import re, glob
for f in ['/etc/bind/named.conf.local'] + glob.glob('/etc/bind/named.conf*'):
    try: s = open(f).read()
    except Exception: continue
    m = re.search(r'zone\s+"proyecto\.local"[^{]*\{[^}]*?file\s+"([^"]+)"', s, re.S)
    if m: print(m.group(1)); break
PY
)
resp $R/funciones.sh $R/lab.conf $R/generar.py /usr/local/sbin/modo-lab /usr/local/sbin/modo-casa /usr/local/sbin/modo-red \
     /usr/local/sbin/modo-actualizar /usr/local/sbin/verificar-lab /etc/hosts /etc/edunova/servicios.json \
     /etc/bind/db.mejoland.edu.ec "$ZP" /etc/apache2/sites-available/mejoland-publico.conf
command -v ufw >/dev/null && ufw status numbered > $BK/ufw-antes.txt 2>/dev/null
cat > $BK/deshacer.sh <<EOF
#!/bin/bash
# Restaura la configuracion previa a la instalacion de los modos (no toca la red)
cd $BK && find . -type f ! -name deshacer.sh ! -name ufw-antes.txt | while read -r f; do cp -a "\$f" "/\${f#./}"; done
[ -f $BK/usr/local/sbin/modo-actualizar ] || rm -f /usr/local/sbin/modo-actualizar
[ -f $BK$R/generar.py ] || rm -f $R/generar.py
command -v rndc >/dev/null && rndc reload >/dev/null 2>&1
command -v apache2ctl >/dev/null && apache2ctl configtest >/dev/null 2>&1 && systemctl reload apache2
systemctl is-active -q lms && systemctl restart lms
echo "Restaurado. Reglas de ufw de antes en $BK/ufw-antes.txt (no se revierten solas)."
EOF
chmod 700 $BK/deshacer.sh

# ---------------------------------------------------------------------
echo; echo "== 1 Configuracion del laboratorio ($R/lab.conf)"
if [ ! -f $R/lab.conf ]; then
  cat > $R/lab.conf <<'EOF'
# Configuracion de modo-lab / modo-casa (Centro Educativo Mejoland). Debe ser igual en los 7 servidores.
# Despues de modificarla:  modo-actualizar   (en cada servidor)

# Equipos que en el laboratorio se alcanzan por Tailscale (sin conexion por cable).
# Por defecto las 3 VMs de la Mac. Si la Mac se conecta por cable en modo puente a la VLAN 40: REMOTOS=""
REMOTOS="srv-apps srv-monitoreo srv-aaa-2"

# Interfaz del laboratorio. Vacio = automatica (la que tiene enlace). Para fijarla: LAB_IF="enx00e04c0c5078"
LAB_IF=""
EOF
  ok "lab.conf creado (REMOTOS = las 3 VMs de la Mac)"
else ok "lab.conf ya existia: se respeta"; fi
grep -E '^(REMOTOS|LAB_IF)=' $R/lab.conf | sed 's/^/      /'

# ---------------------------------------------------------------------
echo; echo "== 2 Comandos nuevos: modo-lab, modo-casa, modo-actualizar, modo-red, verificar-lab"
cat > $R/generar.py <<'FIN_GENERAR'
#!/usr/bin/env python3
# =====================================================================
#  GENERADOR POR MODO - Centro Educativo Mejoland  (lo usan modo-lab, modo-casa y modo-actualizar)
#  Genera, para el modo indicado (lab | casa), versiones completas y coherentes de:
#    hosts           -> bloque MEJOLAND-RED de /etc/hosts
#    zona-mejoland   -> zona DNS mejoland.edu.ec (srv-bd)
#    zona-proyecto   -> zona DNS proyecto.local (srv-bd)
#    servicios       -> enlaces de EduNova (/etc/edunova/servicios.json)
#  Siempre se genera a partir del archivo actual.
#  Equipos en REMOTOS (lab.conf): en el laboratorio se alcanzan por su IP de Tailscale (VMs de la Mac).
#  Uso: generar.py hosts lab | generar.py zona-mejoland lab ARCHIVO | ... | generar.py info
# =====================================================================
import json, os, re, shlex, sys, time

R = os.environ.get('MEJOLAND_R', '/etc/mejoland/red')
HOSTS = os.environ.get('MEJOLAND_HOSTS', '/etc/hosts')


def leer_conf(f):
    d = {}
    if not os.path.exists(f):
        return d
    for l in open(f, encoding='utf-8'):
        l = l.strip()
        if not l or l.startswith('#') or '=' not in l:
            continue
        k, v = l.split('=', 1)
        try:
            d[k.strip()] = ' '.join(shlex.split(v, comments=True))
        except ValueError:
            d[k.strip()] = v.strip().strip('"')
    return d


ROL = leer_conf(R + '/rol.conf').get('ROL', '')
LAB = leer_conf(R + '/lab.conf')
REMOTOS = set(LAB.get('REMOTOS', '').split())
TABLA = [l.split() for l in open(R + '/tabla.txt', encoding='utf-8') if len(l.split()) == 3]
TS = {n: ts for n, ts, lab in TABLA}
LABIP = {n: lab for n, ts, lab in TABLA}
VIP = '192.168.40.100'
PUBLICOS = ('@', 'www', 'plataforma', 'webmail', 'glpi', 'nube')   # siempre al proxy del correo


def ip(nombre, modo):
    """IP con la que se alcanza un equipo en ese modo."""
    if modo == 'casa' or nombre in REMOTOS:
        return TS[nombre]
    return LABIP[nombre]


def proxy(modo):
    return ip('correo', modo)


def ip_a_nombre():
    m = {}
    for n, ts, lab in TABLA:
        m[ts] = n
        m[lab] = n
    return m


def cambiar_ips(texto, modo):
    """Cambia cualquier IP conocida (de casa o del laboratorio) por la que corresponde en este modo."""
    mapa = ip_a_nombre()
    patron = re.compile(r'(?<![\d.])(' + '|'.join(re.escape(x) for x in sorted(mapa, key=len, reverse=True)) + r')(?![\d])')
    return patron.sub(lambda m: ip(mapa[m.group(1)], modo), texto)


def subir_serial(s):
    """Sube el serial del SOA (con o sin parentesis, con o sin comentario ';Serial')."""
    m = re.search(r'\bSOA\b[^(]*\(\s*(?:;[^\n]*\n\s*)*(\d+)', s) or re.search(r'\bSOA\s+\S+\s+\S+\s+(\d+)', s)
    if not m:
        raise SystemExit('  [AVISO] no encontre el SOA/serial de la zona: no se cambio')
    viejo = int(m.group(1))
    nuevo = max(int(time.strftime('%Y%m%d%H')), viejo + 1)
    if nuevo > 4294967295:
        nuevo = viejo + 1
    return s[:m.start(1)] + str(nuevo) + s[m.end(1):], viejo, nuevo


def registro(nombre):
    return re.compile(r'^' + re.escape(nombre) + r'(\.[\w.-]*\.)?\s+(\d+\s+)?(IN\s+)?(A|CNAME)\s', re.I)


def quitar_registros(lineas, nombres):
    regs = [registro(n) for n in nombres]
    return [l for l in lineas if not any(r.match(l) for r in regs)]


def quitar_bloque(lineas):
    out, salta = [], False
    for l in lineas:
        if l.startswith('; >>> MEJOLAND'):
            salta = True
            continue
        if l.startswith('; <<< MEJOLAND'):
            salta = False
            continue
        if salta or l.startswith('; --- publico') or l.startswith('; --- laboratorio') or l.startswith('; --- agregados por'):
            continue
        out.append(l)
    while out and not out[-1].strip():
        out.pop()
    return out


def escribir(f, texto):
    # escribe en el mismo archivo (conserva dueno y permisos)
    with open(f, 'r+', encoding='utf-8') as h:
        h.seek(0)
        h.write(texto)
        h.truncate()


# ---------------------------------------------------------------------
def hosts(modo):
    b = [f'# >>> MEJOLAND-RED {modo} (lo generan modo-lab / modo-casa; no editar a mano)']
    for n, ts, lab in TABLA:
        extra = ' damian.proyecto.local damian' if n == 'srv-bd-replica' else ''
        nota = '   # por Tailscale' if modo == 'lab' and n in REMOTOS else ''
        b.append(f'{ip(n, modo):<15} {n}.proyecto.local {n}{extra}{nota}')
    if modo == 'lab':
        b.append(f'{VIP:<15} plataforma.proyecto.local plataforma')
        if ROL != 'correo':
            b.append(f'{proxy(modo):<15} mejoland.edu.ec www.mejoland.edu.ec')
    b.append('# <<< MEJOLAND-RED')
    nombres = {'srv-bd', 'srv-bd-replica', 'damian', 'correo', 'srv-aaa-1', 'srv-aaa-2', 'srv-apps', 'srv-monitoreo',
               'plataforma', 'mejoland.edu.ec', 'www.mejoland.edu.ec'}
    out, salta = [], False
    for l in open(HOSTS, encoding='utf-8').read().splitlines():
        if re.match(r'#\s*>>>\s*(TAILSCALE|MEJOLAND-RED)', l):
            salta = True
            continue
        if re.match(r'#\s*<<<\s*(TAILSCALE|MEJOLAND-RED)', l):
            salta = False
            continue
        if salta:
            continue
        c = l.split('#')[0].split()
        if c and not re.match(r'^(127\.|::1|fe|ff)', c[0]) and any(
                x in nombres or (x.endswith('.proyecto.local') and x.split('.')[0] in nombres) for x in c[1:]):
            continue
        out.append(l)
    while out and not out[-1].strip():
        out.pop()
    escribir(HOSTS, '\n'.join(out) + '\n\n' + '\n'.join(b) + '\n')
    print(f'  [OK] /etc/hosts: nombres del modo {modo}' + (f' (por Tailscale: {" ".join(sorted(REMOTOS))})' if modo == 'lab' and REMOTOS else ''))


def zona_mejoland(modo, f):
    s = cambiar_ips(open(f, encoding='utf-8').read(), modo)
    lineas = quitar_bloque(quitar_registros(s.splitlines(), PUBLICOS))
    lineas.append(f'; >>> MEJOLAND publico ({modo}): todo lo publico entra por el proxy del correo')
    lineas += [f'{n:<12} IN A     {proxy(modo)}' for n in PUBLICOS]
    lineas.append('; <<< MEJOLAND')
    s, v, n = subir_serial('\n'.join(lineas) + '\n')
    escribir(f, s)
    print(f'  [OK] zona mejoland.edu.ec ({modo}): publico -> {proxy(modo)}; serial {v} -> {n}')


def zona_proyecto(modo, f):
    s = cambiar_ips(open(f, encoding='utf-8').read(), modo)
    nombres = [n for n, _, _ in TABLA] + ['damian', 'plataforma']
    lineas = quitar_bloque(quitar_registros(s.splitlines(), nombres))
    lineas.append(f'; >>> MEJOLAND equipos ({modo}) - los genera modo-lab / modo-casa')
    for n, ts, lab in TABLA:
        lineas.append(f'{n:<16} IN A     {ip(n, modo)}' + ('   ; por Tailscale' if modo == 'lab' and n in REMOTOS else ''))
    lineas.append(f'{"damian":<16} IN CNAME srv-bd-replica')
    if modo == 'lab':
        lineas.append(f'{"plataforma":<16} IN A     {VIP}')
    lineas.append('; <<< MEJOLAND')
    s, v, n = subir_serial('\n'.join(lineas) + '\n')
    escribir(f, s)
    print(f'  [OK] zona proyecto.local ({modo}): {len(TABLA)} equipos; serial {v} -> {n}')


# ---------------------------------------------------------------------
NUEVOS = {
    'nube': {"id": "nube", "nombre": "Nube de archivos (Nextcloud)", "descripcion": "Tus archivos del colegio. Entra con tu usuario institucional.",
             "icono": "archivos", "roles": ["admin", "teacher", "student", "secretary"], "grupos": []},
    'glpi': {"id": "glpi", "nombre": "Mesa de ayuda e inventario (GLPI)", "descripcion": "Reporta problemas y consulta el inventario de equipos.",
             "icono": "enlace", "roles": ["admin", "teacher", "secretary"], "grupos": []},
}


def espec(modo):
    """Enlace de cada servicio conocido, por modo.  pub = ruta que ven las casas (Internet) por el proxy."""
    c = TS['correo']
    if modo == 'lab':
        return {
            'correo':     ('https://mejoland.edu.ec/webmail/', '/webmail/'),
            'nube':       ('https://mejoland.edu.ec/nube/', '/nube/'),
            'glpi':       ('https://mejoland.edu.ec/glpi/', '/glpi/'),
            'secretaria': ('https://srv-bd.proyecto.local/secretaria/', None),   # srv-bd atiende por HTTPS (443)
            'lam':        ('https://srv-bd.proyecto.local/lam/', None),
            'monitoreo':  ('https://mejoland.edu.ec/zabbix/', None),             # por el proxy, solo red interna
        }
    return {
        'correo':     (f'http://{c}/roundcube/', '/webmail/'),
        'nube':       (f'https://{c}/nube/', '/nube/'),
        'glpi':       (f'https://{c}/glpi/', '/glpi/'),
        'secretaria': ('https://srv-bd.tailae692e.ts.net/secretaria/', None),
        'lam':        ('https://srv-bd.tailae692e.ts.net/lam/', None),
        'monitoreo':  (f'http://{TS["srv-monitoreo"]}/zabbix/', None),
    }


def servicios(modo, f):
    d = json.load(open(f, encoding='utf-8'))
    lista = d['servicios'] if isinstance(d, dict) else d
    ids = {s.get('id') for s in lista}
    pos = next((i + 1 for i, s in enumerate(lista) if s.get('id') == 'correo'), 0)
    for k in ('glpi', 'nube'):
        if k not in ids:
            lista.insert(pos, dict(NUEVOS[k]))
            print(f'  [OK] agregado el servicio {k}')
    e = espec(modo)
    for s in lista:
        i, u = s.get('id', ''), s.get('url', '')
        if i in e:
            s['url'], pub = e[i]
            if pub:
                s['url_publica'] = pub
            else:
                s.pop('url_publica', None)
            if i == 'monitoreo':
                s['nombre'] = 'Monitoreo de la red (Zabbix)'
        elif u and not u.startswith('app:'):
            s['url'] = cambiar_ips(u, modo)   # servicio desconocido: solo se corrigen las IP
    if isinstance(d, dict):
        d['servicios'] = lista
        d['_ayuda'] = ('url = enlace dentro del colegio / por la VPN.  url_publica = ruta que ven las casas por el proxy; '
                       'sin url_publica no se muestra desde Internet.  Lo genera modo-lab / modo-casa (modo ' + modo + ').')
    escribir(f, json.dumps(d, ensure_ascii=False, indent=2) + '\n')
    print(f'  [OK] enlaces de EduNova ({modo}):')
    for s in lista:
        print(f'       {s.get("id", ""):<11} {s.get("url") or "(pendiente)":<50} {("casas: " + s["url_publica"]) if s.get("url_publica") else ""}')


def info():
    print(f'  rol={ROL}  remotos por Tailscale en el lab: {" ".join(sorted(REMOTOS)) or "(ninguno)"}')
    for n, ts, lab in TABLA:
        print(f'  {n:<15} casa={ts:<15} lab={ip(n, "lab")}')


if __name__ == '__main__':
    a = sys.argv[1:]
    if not a or a[0] == 'info':
        info()
        sys.exit(0)
    cmd, modo = a[0], (a[1] if len(a) > 1 else '')
    if modo not in ('lab', 'casa'):
        raise SystemExit('modo debe ser lab o casa')
    {'hosts': lambda: hosts(modo),
     'zona-mejoland': lambda: zona_mejoland(modo, a[2]),
     'zona-proyecto': lambda: zona_proyecto(modo, a[2]),
     'servicios': lambda: servicios(modo, a[2])}[cmd]()
FIN_GENERAR
cat > $R/funciones.sh <<'FIN_FUNCIONES'
# shellcheck shell=bash
# =====================================================================
#  Funciones comunes de modo-lab / modo-casa / modo-actualizar (Centro Educativo Mejoland)
#  Las instala corregir-modos.sh. La configuracion se edita en /etc/mejoland/red/lab.conf
# =====================================================================
R=/etc/mejoland/red
. $R/rol.conf
LAB_IF=""; REMOTOS=""
[ -f $R/lab.conf ] && . $R/lab.conf
GEN="python3 $R/generar.py"
TAG=${TAG:-mejoland-modo}

log() { echo "  $*"; logger -t "$TAG" "$*" 2>/dev/null; }
modo_actual() { cat /etc/mejoland/modo 2>/dev/null || echo casa; }
es_remoto() { case " $REMOTOS " in *" $ROL "*) return 0;; esac; return 1; }
poner_hosts() { $GEN hosts "$1"; }
cambiar_serial() { :; }                              # el serial lo incrementa generar.py al regenerar la zona

# ---- interfaz del laboratorio -----------------------------------------
cableadas() { ls /sys/class/net 2>/dev/null | grep -E '^(en|eth)'; }
if_actual() { cat $R/if.actual 2>/dev/null || echo "$IF"; }
elegir_if() {          # interfaz con enlace activo; LAB_IF en lab.conf la fija manualmente
  local i
  if [ -n "$LAB_IF" ]; then echo "$LAB_IF"; return; fi
  for i in $(cableadas); do ip link set "$i" up 2>/dev/null; done
  sleep 5
  for i in $(cableadas); do [ "$(cat /sys/class/net/$i/carrier 2>/dev/null)" = 1 ] && { echo "$i"; return; }; done
  echo "$IF"           # ninguna con cable: la de siempre (avisa modo-lab)
}
quitar_ip_lab() {      # quita la IP del laboratorio y la IP virtual de todas las interfaces
  local i a
  for i in $(ls /sys/class/net); do for a in $LAB_IP/24 $VIP/24; do ip addr del $a dev "$i" 2>/dev/null; done; done
}
escribir_interfaces_lab() {
  cat > $R/interfaces.lab <<EOF
# Red del LABORATORIO (la genera modo-lab con la interfaz que tiene cable: $1)
auto lo
iface lo inet loopback

allow-hotplug $1
auto $1
iface $1 inet static
    address $LAB_IP/24
    gateway $LAB_GW
EOF
}

# ---- alta disponibilidad -------------------------------------------------
par_ha() { case $ROL in srv-bd) echo 192.168.40.13;; damian) echo 192.168.40.10;; esac; }
reanudar_ha() {        # en lab: si el otro servidor aun no responde, se reanuda al detectarlo
  local par; par=$(par_ha); [ -n "$par" ] || return 0
  systemctl stop mejoland-ha-espera 2>/dev/null; systemctl reset-failed mejoland-ha-espera 2>/dev/null
  if ping -c 2 -W 2 "$par" >/dev/null 2>&1; then
    systemctl start mejoland-ha.timer && log "Alta disponibilidad reanudada ($par responde)"
  else
    systemd-run --quiet --unit=mejoland-ha-espera /bin/bash -c "for i in \$(seq 1 90); do ping -c1 -W2 $par >/dev/null 2>&1 && { systemctl start mejoland-ha.timer; logger -t $TAG 'HA reanudada: $par responde'; exit 0; }; sleep 10; done; logger -t $TAG 'HA en pausa: $par no respondio en 15 min'" \
      && log "$par aun no responde: la alta disponibilidad se reanudara sola cuando responda (espera hasta 15 min)"
  fi
}

# ---- archivos de cada servidor, generados para el modo -------------------
zona_proyecto_archivo() {
  python3 - <<'PY'
import re, glob
for f in ['/etc/bind/named.conf.local'] + glob.glob('/etc/bind/named.conf*'):
    try: s = open(f).read()
    except Exception: continue
    m = re.search(r'zone\s+"proyecto\.local"[^{]*\{[^}]*?file\s+"([^"]+)"', s, re.S)
    if m: print(m.group(1)); break
PY
}
regenerar_zonas() {    # srv-bd (maestro): genera ambas zonas para el modo, con respaldo y prueba
  local m=$1 zm=/etc/bind/db.mejoland.edu.ec zp; zp=$(zona_proyecto_archivo)
  mkdir -p $R/ultimo; cp -a $zm $R/ultimo/ 2>/dev/null; [ -f "$zp" ] && cp -a "$zp" $R/ultimo/
  $GEN zona-mejoland $m $zm
  [ -f "$zp" ] && $GEN zona-proyecto $m "$zp"
  if named-checkzone mejoland.edu.ec $zm >/dev/null 2>&1 && { [ ! -f "$zp" ] || named-checkzone proyecto.local "$zp" >/dev/null 2>&1; }; then
    log "Zonas DNS del modo $m validas"
  else
    log "AVISO: zona con errores; se restaura la anterior"; cp -a $R/ultimo/$(basename $zm) $zm; [ -f "$zp" ] && cp -a $R/ultimo/$(basename "$zp") "$zp"
  fi
}
aplicar_rol() {        # $1 = lab | casa.  Todo lo propio de cada servidor para ese modo
  local m=$1
  case $ROL in
    srv-bd)
      [ -f $R/ha.conf.$m ] && cp $R/ha.conf.$m /etc/mejoland-ha/ha.conf
      regenerar_zonas $m
      [ -f /etc/edunova/servicios.json ] && $GEN servicios $m /etc/edunova/servicios.json
      [ -f $R/secretaria-url.$m ] && [ -f /var/www/secretaria/index.php ] && sed -i "s#\(PLATAFORMA_URL *= *'\)[^']*'#\1$(cat $R/secretaria-url.$m)'#" /var/www/secretaria/index.php
      systemctl restart chrony rsyslog 2>/dev/null; systemctl restart named 2>/dev/null; rndc reload >/dev/null 2>&1
      if [ "$m" = lab ]; then systemctl restart kea-dhcp4-server 2>/dev/null; else systemctl stop kea-dhcp4-server 2>/dev/null; fi ;;
    damian)
      [ -f $R/ha.conf.$m ] && cp $R/ha.conf.$m /etc/mejoland-ha/ha.conf
      [ -f $R/named.conf.local.$m ] && cp $R/named.conf.local.$m /etc/bind/named.conf.local
      [ -f /etc/edunova/servicios.json ] && $GEN servicios $m /etc/edunova/servicios.json
      systemctl restart named 2>/dev/null; sleep 2
      for z in mejoland.edu.ec proyecto.local; do rndc retransfer $z >/dev/null 2>&1; done
      log "DNS secundario: pidiendo de nuevo las zonas a srv-bd"
      if [ "$m" = lab ]; then systemctl restart kea-dhcp4-server 2>/dev/null; else systemctl stop kea-dhcp4-server 2>/dev/null; fi ;;
    correo)
      [ -f $R/destinos.$m ] && cp $R/destinos.$m /etc/apache2/conf-available/mejoland-destinos.conf
      systemctl restart chrony rsyslog postfix dovecot 2>/dev/null
      apache2ctl configtest >/dev/null 2>&1 && systemctl reload apache2 ;;
    srv-aaa-1|srv-aaa-2) systemctl restart freeradius 2>/dev/null ;;
    srv-apps) systemctl restart apache2 2>/dev/null ;;
    srv-monitoreo) systemctl restart zabbix-server 2>/dev/null ;;
  esac
  systemctl restart zabbix-agent2 2>/dev/null || systemctl restart zabbix-agent 2>/dev/null
  case $ROL in srv-bd|damian) systemctl is-active -q lms && systemctl restart lms ;; esac
  return 0
}
FIN_FUNCIONES
cat > /usr/local/sbin/modo-lab <<'FIN_MODOLAB'
#!/bin/bash
# =====================================================================
#  MODO LABORATORIO (Centro Educativo Mejoland). Ejecutar desde la consola del servidor.
#  - Usa la interfaz con enlace activo (incluido el adaptador USB) y retira la IP del lab de las demas.
#  - Genera para el laboratorio: /etc/hosts, zonas DNS (srv-bd), enlaces de EduNova y proxy.
#  - Los equipos en REMOTOS (lab.conf) se alcanzan por Tailscale (VMs de la Mac).
#  - La alta disponibilidad se reanuda automaticamente cuando el otro servidor responde.
#  Uso:  modo-lab            (pregunta)      modo-lab --si      (sin preguntar)      Volver:  modo-casa
# =====================================================================
set -u; TAG=modo-lab; . /etc/mejoland/red/funciones.sh
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
SI=0; FORZAR=0; for a in "$@"; do case $a in --si) SI=1;; --forzar) FORZAR=1;; esac; done
if es_remoto && [ $FORZAR -eq 0 ]; then
  echo "$ROL esta en REMOTOS ($R/lab.conf): se queda en casa/VPN y el laboratorio lo alcanza por Tailscale."
  echo "No hace falta modo-lab aqui. Si de verdad lo conectaste por cable al laboratorio:"
  echo "  1) quitalo de REMOTOS en $R/lab.conf de TODOS los servidores y ejecuta modo-actualizar en ellos"
  echo "  2) aqui:  modo-lab --forzar"
  exit 1
fi
if [ $SI -eq 0 ]; then
  echo "Este equipo ($ROL) pasara a la red del LABORATORIO: $LAB_IP/24, puerta $LAB_GW (interfaz con cable)."
  echo "Se apaga el Wi-Fi. El acceso remoto queda solo por Tailscale (si hay salida a Internet)."
  read -r -p "Escribe LAB para continuar: " r; [ "$r" = LAB ] || { echo "Cancelado."; exit 1; }
fi
systemctl stop mejoland-ha.timer mejoland-ha-espera 2>/dev/null && log "Alta disponibilidad en pausa durante el cambio"

echo "== Red"
IFL=$(elegir_if)
if [ "$(cat /sys/class/net/$IFL/carrier 2>/dev/null)" = 1 ]; then log "Interfaz con cable: $IFL"
else log "AVISO: ninguna interfaz cableada tiene enlace; se usa $IFL (revisa cable y puerto del switch)"; fi
echo "$IFL" > $R/if.actual
escribir_interfaces_lab "$IFL"
ifdown -a --exclude=lo >/dev/null 2>&1
if command -v nmcli >/dev/null; then
  nmcli radio wifi off 2>/dev/null; nmcli dev disconnect "$IFL" >/dev/null 2>&1
  printf '[main]\ndns=none\n[keyfile]\nunmanaged-devices=interface-name:%s\n' "$IFL" > /etc/NetworkManager/conf.d/90-mejoland-lab.conf
  systemctl reload NetworkManager 2>/dev/null; log "Wi-Fi apagado; NetworkManager no toca $IFL ni el DNS"
fi
quitar_ip_lab
for i in $(cableadas); do [ "$i" = "$IFL" ] || { ip addr flush dev "$i" 2>/dev/null; ip link set "$i" down 2>/dev/null; log "$i apagada (sin IP del laboratorio)"; }; done
cp $R/interfaces.lab /etc/network/interfaces
ip addr flush dev "$IFL" 2>/dev/null; ifup -a >/dev/null 2>&1 || systemctl restart networking
log "Red: $IFL = $(ip -4 -o addr show dev "$IFL" | awk '{print $4}' | tr '\n' ' ')puerta $LAB_GW"
n=$(ip -4 -o addr show | grep -c " $LAB_IP/"); [ "$n" -le 1 ] || log "AVISO: $LAB_IP aparece en $n interfaces"

echo "== Nombres, DNS y servicios del laboratorio"
tailscale set --accept-dns=false >/dev/null 2>&1
rm -f /etc/resolv.conf; cp $R/resolv.lab /etc/resolv.conf
poner_hosts lab
echo lab > /etc/mejoland/modo
aplicar_rol lab
reanudar_ha

echo "== Pruebas"
ping -c 2 -W 2 $LAB_GW >/dev/null 2>&1 && echo "  puerta $LAB_GW: OK" || echo "  puerta $LAB_GW: NO RESPONDE (cable, VLAN del puerto o router)"
for n in srv-bd srv-bd-replica correo srv-apps srv-monitoreo; do
  printf '  %-15s %-15s %s\n' "$n" "$(getent hosts $n.proyecto.local | awk '{print $1}')" "$(ping -c 1 -W 2 $n >/dev/null 2>&1 && echo OK || echo 'no responde')"
done
echo "Listo: $ROL en modo LABORATORIO. Revision completa: verificar-lab"
FIN_MODOLAB
cat > /usr/local/sbin/modo-casa <<'FIN_MODOCASA'
#!/bin/bash
# =====================================================================
#  MODO CASA (Centro Educativo Mejoland): red domestica con acceso por Tailscale.
#  Requiere que el equipo este conectado a una red domestica (Wi-Fi o router); en el laboratorio
#  esa red no existe y el equipo queda sin conectividad.
#  Genera para casa: /etc/hosts, zonas DNS (srv-bd), enlaces de EduNova y proxy.
# =====================================================================
set -u; TAG=modo-casa; . /etc/mejoland/red/funciones.sh
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
if [ "$(modo_actual)" = lab ] && [ "${1:-}" != "--si" ]; then
  echo "Este equipo ($ROL) volvera a la red de CASA (Wi-Fi / router de casa y Tailscale)."
  echo "Si estas en el laboratorio, se quedara SIN RED. Para solo regenerar archivos usa: modo-actualizar"
  read -r -p "Escribe CASA para continuar: " r; [ "$r" = CASA ] || { echo "Cancelado."; exit 1; }
fi
systemctl stop mejoland-ha.timer mejoland-ha-espera 2>/dev/null

echo "== Red"
quitar_ip_lab
ifdown -a --exclude=lo >/dev/null 2>&1
cp $R/interfaces.casa /etc/network/interfaces
for i in $(cableadas); do ip addr flush dev "$i" 2>/dev/null; ip link set "$i" up 2>/dev/null; done
rm -f /etc/NetworkManager/conf.d/90-mejoland-lab.conf $R/if.actual
command -v nmcli >/dev/null && { systemctl reload NetworkManager 2>/dev/null; nmcli radio wifi on 2>/dev/null; }
ifup -a >/dev/null 2>&1 || systemctl restart networking
if [ "$TS_DNS" = 1 ]; then tailscale set --accept-dns=true >/dev/null 2>&1; else rm -f /etc/resolv.conf; cp $R/resolv.casa /etc/resolv.conf; fi
log "Red de casa restaurada"

echo "== Nombres, DNS y servicios de casa"
poner_hosts casa
echo casa > /etc/mejoland/modo
sleep 8
aplicar_rol casa
case $ROL in srv-bd|damian) systemctl start mejoland-ha.timer 2>/dev/null && log "Alta disponibilidad activa";; esac

echo "== Pruebas"
ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1 && echo "  Internet: OK" || echo "  Internet: no (revisa Wi-Fi o cable)"
tailscale status >/dev/null 2>&1 && echo "  Tailscale: OK ($(tailscale ip -4 2>/dev/null))" || echo "  Tailscale: no conectado"
echo "Listo: $ROL en modo CASA."
FIN_MODOCASA
cat > /usr/local/sbin/modo-actualizar <<'FIN_MODOACT'
#!/bin/bash
# =====================================================================
#  MODO ACTUALIZAR (Centro Educativo Mejoland): regenera nombres, DNS, enlaces de EduNova y proxy
#  para el modo actual, sin tocar la red. Se puede usar por SSH.
#  Usar despues de modificar /etc/mejoland/red/lab.conf (por ejemplo REMOTOS).
# =====================================================================
set -u; TAG=modo-actualizar; . /etc/mejoland/red/funciones.sh
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
M=$(modo_actual)
echo "== $ROL: regenerando todo para el modo $M (la red no se toca)"
$GEN info
poner_hosts $M
aplicar_rol $M
[ "$M" = lab ] && case $ROL in srv-bd|damian) systemctl is-active -q mejoland-ha.timer || reanudar_ha;; esac
echo "Listo."
FIN_MODOACT
cat > /usr/local/sbin/modo-red <<'FIN_MODORED'
#!/bin/bash
# Estado de red de este servidor (Centro Educativo Mejoland)
. /etc/mejoland/red/funciones.sh
I=$(if_actual)
echo "$ROL: modo $(modo_actual) | $I $(ip -4 -o addr show dev $I 2>/dev/null | awk '{print $4}' | tr '\n' ' ')| IP virtual: $(ip -4 -o addr show | grep -q ' 192.168.40.100/' && echo SI || echo no) | por Tailscale en el lab: ${REMOTOS:-ninguno}$(es_remoto && echo ' (este equipo)')"
FIN_MODORED
cat > /usr/local/sbin/verificar-lab <<'FIN_VERIFICAR'
#!/bin/bash
# =====================================================================
#  VERIFICAR LABORATORIO (Centro Educativo Mejoland) - solo lectura.
#  Ejecutar en cualquier servidor despues de modo-lab:   verificar-lab
#  Tiene en cuenta los equipos que van por Tailscale (REMOTOS en /etc/mejoland/red/lab.conf).
# =====================================================================
. /etc/mejoland/red/funciones.sh 2>/dev/null || { echo "Falta preparar-lab / corregir-modos en este equipo"; exit 1; }
B=0; M=0
si() { echo "  [OK]    $*"; B=$((B+1)); }
no() { echo "  [FALLA] $*"; M=$((M+1)); }
prueba() { local d=$1; shift; if "$@" >/dev/null 2>&1; then si "$d"; else no "$d"; fi; }
puerto() { timeout 3 bash -c "</dev/tcp/$1/$2" 2>/dev/null; }
ipde() { getent hosts "$1.proyecto.local" | awk '{print $1; exit}'; }
web() { curl -sk -o /dev/null -m 10 -w '%{http_code}' --resolve mejoland.edu.ec:443:$1 "https://mejoland.edu.ec/$2"; }
I=$(if_actual)
echo "################ VERIFICAR LABORATORIO: $ROL ($(date '+%F %T')) ################"
echo "== Red";  modo-red | sed 's/^/  /'
if es_remoto; then echo "  (este equipo va por Tailscale: no necesita modo lab)"
else
  [ "$(modo_actual)" = lab ] && si "modo laboratorio" || no "este equipo sigue en modo $(modo_actual) (ejecutar modo-lab)"
  ip -4 -o addr show dev $I | grep -q " $LAB_IP/" && si "$I tiene $LAB_IP" || no "$I no tiene $LAB_IP"
  n=$(ip -4 -o addr show | grep -c " $LAB_IP/"); [ "$n" -le 1 ] && si "$LAB_IP en una sola interfaz" || no "$LAB_IP repetida en $n interfaces"
  [ "$(cat /sys/class/net/$I/carrier 2>/dev/null)" = 1 ] && si "$I con cable (enlace arriba)" || no "$I sin enlace"
  prueba "puerta de enlace HSRP $LAB_GW" ping -c 2 -W 2 $LAB_GW
fi
echo "== DNS (srv-bd y damian deben responder lo mismo)"
for n in srv-bd correo srv-apps srv-monitoreo; do
  a=$(dig +short +time=2 +tries=1 @192.168.40.10 $n.proyecto.local 2>/dev/null | tail -1)
  b=$(dig +short +time=2 +tries=1 @192.168.40.13 $n.proyecto.local 2>/dev/null | tail -1)
  [ -n "$a" ] && [ "$a" = "$b" ] && si "$n.proyecto.local = $a (srv-bd y damian)" || no "$n.proyecto.local: srv-bd='${a:-nada}' damian='${b:-nada}'"
done
for n in mejoland.edu.ec webmail.mejoland.edu.ec glpi.mejoland.edu.ec; do
  a=$(dig +short +time=2 +tries=1 @192.168.40.10 $n 2>/dev/null | tail -1)
  b=$(dig +short +time=2 +tries=1 @192.168.40.13 $n 2>/dev/null | tail -1)
  [ "$a" = 192.168.60.10 ] && [ "$b" = 192.168.60.10 ] && si "$n = 192.168.60.10 (proxy DMZ)" || no "$n: srv-bd='${a:-nada}' damian='${b:-nada}' (esperado 192.168.60.10)"
done
echo "== Servicios entre servidores"
prueba "EduNova en la IP virtual 192.168.40.100:3001" puerto 192.168.40.100 3001
prueba "LDAP srv-bd :389"          puerto 192.168.40.10 389
prueba "LDAP damian :389"          puerto 192.168.40.13 389
prueba "MariaDB srv-bd :3306"      puerto 192.168.40.10 3306
prueba "Correo SMTP :25"           puerto 192.168.60.10 25
prueba "Correo IMAP :993"          puerto 192.168.60.10 993
prueba "Proxy DMZ HTTPS :443"      puerto 192.168.60.10 443
prueba "GLPI/nube srv-apps :80 ($(ipde srv-apps))"            puerto "$(ipde srv-apps)" 80
prueba "Zabbix srv-monitoreo :10051 ($(ipde srv-monitoreo))"  puerto "$(ipde srv-monitoreo)" 10051
prueba "RADIUS srv-aaa-1 (ping)"   ping -c 1 -W 2 192.168.40.11
case " $REMOTOS " in *" srv-aaa-2 "*) echo "  [INFO]  srv-aaa-2 va por Tailscale: los routers solo usan srv-aaa-1 para RADIUS";;
  *) prueba "RADIUS srv-aaa-2 (ping)" ping -c 1 -W 2 192.168.40.12;; esac
case $ROL in
  srv-bd|damian)
    echo "== Alta disponibilidad"
    /usr/local/sbin/mejoland-ha estado 2>/dev/null | head -4 | sed 's/^/  /'
    if systemctl is-active -q mejoland-ha.timer; then si "vigilancia HA activa"
    elif systemctl is-active -q mejoland-ha-espera; then echo "  [ESPERA] HA se reanuda sola cuando el otro servidor responda"
    else no "vigilancia HA en pausa (systemctl start mejoland-ha.timer)"; fi
    ip -4 addr show | grep -q ' 192.168.40.100/' && echo "  IP virtual: la tiene ESTE equipo" || echo "  IP virtual: la tiene el otro servidor"
    python3 -c "import json;[print(s['id'],s.get('url','')) for s in json.load(open('/etc/edunova/servicios.json'))['servicios']]" 2>/dev/null \
      | grep -E '100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|ts\.net' >/dev/null && no "EduNova tiene enlaces a Tailscale (ejecutar modo-actualizar)" || si "enlaces de EduNova del laboratorio"
    if [ "$ROL" = damian ]; then
      S=$(mariadb -e "SHOW SLAVE STATUS\G" 2>/dev/null)
      echo "$S" | grep -q "Slave_IO_Running: Yes" && echo "$S" | grep -q "Slave_SQL_Running: Yes" && si "replica MariaDB Yes/Yes desde $(echo "$S" | awk '/Master_Host/{print $2}')" || no "replica MariaDB detenida"
      c=$(ldapsearch -x -LLL -H ldap://127.0.0.1 -b dc=proyecto,dc=local -s base contextCSN 2>/dev/null | awk '/contextCSN/{print $2}' | head -1)
      p=$(ldapsearch -x -LLL -H ldap://192.168.40.10 -b dc=proyecto,dc=local -s base contextCSN 2>/dev/null | awk '/contextCSN/{print $2}' | head -1)
      [ -n "$c" ] && [ "$c" = "$p" ] && si "replica LDAP al dia" || no "replica LDAP distinta (local $c / srv-bd $p)"
    fi ;;
  correo)
    echo "== Publicacion (proxy de la DMZ)"
    for p in plataforma/ webmail/ glpi/ nube/ zabbix/; do
      c=$(web 127.0.0.1 $p)
      case $c in 200|301|302|303) si "https://mejoland.edu.ec/$p -> $c";; *) no "https://mejoland.edu.ec/$p -> $c";; esac
    done
    grep -q 192.168.40.100 /etc/apache2/conf-available/mejoland-destinos.conf && si "proxy apunta a la IP virtual" || no "proxy no esta en destinos de laboratorio" ;;
esac
echo "== Salida a Internet y VPN"
prueba "ping 8.8.8.8" ping -c 2 -W 3 8.8.8.8
tailscale status >/dev/null 2>&1 && si "Tailscale conectado ($(tailscale ip -4 2>/dev/null))" || no "Tailscale no conectado (sin el no se llega a: ${REMOTOS:-nadie})"
echo; echo "Resultado: $B correctas, $M fallas."
FIN_VERIFICAR
chmod 755 $R/generar.py /usr/local/sbin/modo-lab /usr/local/sbin/modo-casa /usr/local/sbin/modo-actualizar /usr/local/sbin/modo-red /usr/local/sbin/verificar-lab
chmod 644 $R/funciones.sh
E=0
for f in /usr/local/sbin/modo-lab /usr/local/sbin/modo-casa /usr/local/sbin/modo-actualizar /usr/local/sbin/modo-red /usr/local/sbin/verificar-lab $R/funciones.sh; do
  bash -n $f || { av "error de sintaxis en $f"; E=1; }
done
python3 -m py_compile $R/generar.py 2>/dev/null || { av "error en generar.py"; E=1; }
if [ $E -eq 1 ]; then echo "  Restaurando lo anterior..."; bash $BK/deshacer.sh; exit 1; fi
ok "instalados y revisados"
python3 $R/generar.py info

# ---------------------------------------------------------------------
echo; echo "== 3 Arreglos propios de este servidor"
case $ROL in
correo)
  C=/etc/apache2/sites-available/mejoland-publico.conf
  if [ -f $C ]; then
    python3 - $C <<'PY'
import sys, re
f = sys.argv[1]; s = open(f).read(); o = s
INTERNA = r'^(127\.|192\.168\.(10|20|30|40|50|60|99)\.|172\.16\.100\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)'
ALIAS = ['192.168.60.10', '10.1.40.13', '10.1.60.10', '100.65.119.48']
# 1. HTTP -> HTTPS conservando el nombre o la IP que uso el visitante
nuevo80 = ('<VirtualHost *:80>\n    ServerName mejoland.edu.ec\n    ServerAlias www.mejoland.edu.ec ' + ' '.join(ALIAS) +
           '\n    RewriteEngine on\n    RewriteRule ^/(.*)$ https://%{HTTP_HOST}/$1 [R=301,L]\n</VirtualHost>')
s = re.sub(r'<VirtualHost \*:80>.*?</VirtualHost>', lambda m: nuevo80, s, count=1, flags=re.S)
# 2. El sitio HTTPS acepta las IP publicas
def alias443(m):
    v = m.group(0).split()
    return m.group(0) + ''.join(' ' + a for a in ALIAS if a not in v)
i = s.find('<VirtualHost *:443>')
if i >= 0:
    s = s[:i] + re.sub(r'ServerAlias[^\n]*', alias443, s[i:], count=1)
# 3. Red interna = VLAN del colegio, servidores y Tailscale. Las casas (192.168.100/200, 10.x) = Internet
s = re.sub(r'SetEnvIf Remote_Addr "[^"]*" red_interna', lambda m: f'SetEnvIf Remote_Addr "{INTERNA}" red_interna', s)
# 4. Zabbix por el proxy, solo red interna (los enlaces de EduNova en el lab usan https://mejoland.edu.ec/zabbix/)
s = re.sub(r'(<LocationMatch "\^/\()([^)]*)(\)">)', lambda m: m.group(1) + '|'.join(x for x in m.group(2).split('|') if x != 'zabbix') + m.group(3), s)
if '<Location /zabbix/>' not in s:
    b = ('    # Zabbix (srv-monitoreo): SOLO red interna y Tailscale; desde Internet -> 403\n    <Location /zabbix/>\n'
         '        Require ip 127.0.0.1 192.168.10.0/24 192.168.40.0/24 192.168.50.0/24 100.64.0.0/10\n'
         '        ProxyPass        http://srv-monitoreo.proyecto.local/zabbix/\n'
         '        ProxyPassReverse http://srv-monitoreo.proyecto.local/zabbix/\n    </Location>\n')
    j = s.rfind('    ErrorLog'); s = s[:j] + b + s[j:]
else:
    s = re.sub(r'(<Location /zabbix/>\s*\n\s*Require ip)[^\n]*', r'\1 127.0.0.1 192.168.10.0/24 192.168.40.0/24 192.168.50.0/24 100.64.0.0/10', s)
if s != o: open(f, 'w').write(s); print("  [OK] proxy de la DMZ corregido (casas = Internet, IP publicas, http->https, Zabbix interno)")
else: print("  proxy de la DMZ: ya estaba bien")
PY
    a2enmod -q rewrite proxy proxy_http headers ssl >/dev/null 2>&1
    if apache2ctl configtest >/dev/null 2>&1; then systemctl reload apache2 && ok "Apache recargado"
    else av "error en Apache: se restaura el sitio"; apache2ctl configtest 2>&1 | tail -3; cp -a $BK$C $C; systemctl reload apache2; fi
  else av "no existe $C (falta preparar-lab en correo)"; fi ;;
srv-bd|damian)
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw delete allow from 192.168.0.0/16 to any port 80,3001 proto tcp >/dev/null 2>&1
    for src in 192.168.60.10 100.65.119.48 192.168.40.10 192.168.40.13 192.168.40.20 100.123.222.5; do
      ufw allow from $src to any port 3001 proto tcp comment "EduNova: proxy, HA y Zabbix" >/dev/null 2>&1
    done
    ok "EduNova (3001): solo proxy del correo, el otro servidor y Zabbix (las casas ya no llegan directo)"
  else av "ufw no esta activo: el puerto 3001 queda como estaba"; fi ;;
esac

# ---------------------------------------------------------------------
if [ "${1:-}" = --sin-aplicar ]; then
  echo; echo "== 4 No se aplico nada al modo actual (--sin-aplicar). Para aplicarlo: modo-actualizar"
else
  echo; echo "== 4 Aplicando al modo actual (sin tocar la red)"
  /usr/local/sbin/modo-actualizar
fi
echo
echo "LISTO en $ROL. Respaldo: $BK   Deshacer: bash $BK/deshacer.sh"
echo "Ahora:  modo-lab (en el laboratorio, con teclado) | modo-casa (en casa) | modo-actualizar (regenerar sin tocar la red) | verificar-lab"
