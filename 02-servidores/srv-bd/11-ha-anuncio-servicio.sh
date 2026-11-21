#!/bin/bash
# =====================================================================
#  Alta disponibilidad: solo el servidor activo anuncia svc:mejoland (ejecutar en SRV-BD y en damian-1, root)
#  "tailscale serve drain" no persiste tras un reinicio, por lo que el servidor en espera podria
#  volver a anunciar el servicio y recibir conexiones con EduNova detenido.
#  En cada ciclo (10 s) mejoland-ha comprueba el anuncio y lo ajusta:
#    al mando (SRV-BD NORMAL / damian PRINCIPAL)  -> anunciado y EduNova encendido
#    en espera (damian ESPERA/ENTREGANDO, SRV-BD CERCADO) -> sin anuncio
#  Uso:  bash 11-ha-anuncio-servicio.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
H=/usr/local/sbin/mejoland-ha
[ -f $H ] || { echo "No existe $H"; exit 1; }
cp -a $H /root/proyecto/mejoland-ha-antes-parche-$(date +%Y%m%d-%H%M%S)
python3 - "$H" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
if 'asegurar_sin_anuncio' in s:
    print("  El parche ya estaba aplicado."); sys.exit(0)
fun = r'''
# --- Anuncio del servicio: 0 = anunciado, 1 = no anunciado, 2 = no se puede determinar ---
anunciado() {
  local P; P=$(tailscale debug prefs 2>/dev/null | tr -d ' \n')
  echo "$P" | grep -q '"AdvertiseServices"' || return 2
  echo "$P" | grep -o '"AdvertiseServices":\[[^]]*\]' | grep -q "\"$SVC\"" && return 0 || return 1
}
asegurar_anuncio() {
  anunciado; [ $? -eq 0 ] && return 0
  tailscale serve advertise "$SVC" >/dev/null 2>&1 && log "Anuncio de $SVC restablecido (este equipo esta al mando)"
}
asegurar_sin_anuncio() {
  anunciado; local r=$?
  [ $r -eq 1 ] && return 0
  tailscale serve drain "$SVC" >/dev/null 2>&1
  [ $r -eq 0 ] && log "Este equipo anunciaba $SVC sin estar al mando: anuncio retirado"
  return 0
}
'''
m = re.search(r'\nponer\(\) \{[^\n]*\}\n', s)
assert m, "no encuentro poner()"
s = s[:m.end()] + fun + s[m.end():]
n = 0
if 'PRINCIPAL_TS=' in open('/etc/mejoland-ha/ha.conf').read():   # damian-1
    a = "        systemctl is-active -q lms || systemctl start lms\n        marcar PRINCIPAL $EPOCA\n"
    assert a in s; s = s.replace(a, "        systemctl is-active -q lms || systemctl start lms\n        asegurar_anuncio\n        marcar PRINCIPAL $EPOCA\n"); n += 1
    a = "      ENTREGANDO)\n"
    assert a in s; s = s.replace(a, a + "        asegurar_sin_anuncio\n", 1); n += 1
    a = "      *)   # ESPERA\n        marcar ESPERA $EPOCA\n"
    assert a in s; s = s.replace(a, a + "        systemctl is-active -q lms && systemctl stop lms\n        asegurar_sin_anuncio\n"); n += 1
else:                                                            # SRV-BD
    a = "        systemctl is-active -q lms && { tailscale serve drain \"$SVC\" >/dev/null 2>&1; systemctl stop lms; }\n"
    assert a in s; s = s.replace(a, a + "        asegurar_sin_anuncio\n"); n += 1
    a = "      *)   # NORMAL\n        marcar NORMAL $EPOCA\n"
    assert a in s; s = s.replace(a, a + "        systemctl is-active -q lms || systemctl start lms\n        asegurar_anuncio\n"); n += 1
open(p, 'w').write(s)
print(f"  Parche aplicado ({n} puntos)")
PY
[ $? -eq 0 ] || { echo "ERROR aplicando el parche (no se cambio nada)"; exit 1; }
bash -n $H || { echo "ERROR de sintaxis: restaurando"; cp -a "$(ls -t /root/proyecto/mejoland-ha-antes-parche-* | head -1)" $H; exit 1; }
echo "  Ejecutando una vuelta ahora..."
$H vigilar >/dev/null 2>&1
sleep 2
P=$(tailscale debug prefs 2>/dev/null | tr -d ' \n' | grep -o '"AdvertiseServices":\[[^]]*\]')
echo "  Estado HA: $(cat /var/lib/mejoland-ha/estado 2>/dev/null || $H estado | head -1)"
echo "  Anuncio actual: ${P:-(no disponible)}   EduNova: $(systemctl is-active lms)"
tail -3 /var/log/mejoland-ha.log | sed 's/^/  /'
echo; echo "LISTO en $(hostname)."
