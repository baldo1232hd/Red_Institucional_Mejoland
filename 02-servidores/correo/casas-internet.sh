#!/bin/bash
# =====================================================================
#  CASAS -> INTERNET - Centro Educativo Mejoland   (ejecutar en CORREO como root)
#  Para que las casas (Internet simulado) entren por https://mejoland.edu.ec/ :
#    - El proxy acepta la IP publica 10.1.60.10.
#    - Las casas (192.168.100.x, 192.168.200.x, 10.1.50.x) se tratan como INTERNET:
#      EduNova les muestra solo lo publicado (correo, GLPI, nube) con enlaces relativos.
#    - /zabbix/ solo para administracion (VLAN 10), servidores y Tailscale.
#  Requiere en R1, R3 y MikroTik los comandos de 01-red/vyos-y-casas/CASAS-INTERNET-routers-OPCIONAL.txt
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root (sudo -i)"; exit 1; }
case "$(hostname -s | tr A-Z a-z)" in correo*) ;; *) echo "Este script es para CORREO"; exit 1;; esac
C=/etc/apache2/sites-available/mejoland-publico.conf
[ -f $C ] || { echo "No existe $C (falta preparar-lab en correo)"; exit 1; }
BK=/root/proyecto/casas-internet-$(date +%Y%m%d-%H%M%S); mkdir -p $BK; chmod 700 $BK; cp -a $C $BK/
echo "################ CASAS -> INTERNET (correo) ################"
python3 - $C <<'PY'
import sys, re
f = sys.argv[1]; s = open(f).read(); o = s
# 1. IP publica adicional en el sitio 443
s = re.sub(r'^(\s*ServerAlias\s+www\.mejoland\.edu\.ec[^\n]*)$',
           lambda m: m.group(1) if '10.1.60.10' in m.group(1) else m.group(1) + ' 10.1.60.10', s, flags=re.M)
# 2. Red interna = solo las VLAN del colegio, sus servidores y Tailscale (las casas cuentan como Internet)
s = re.sub(r'SetEnvIf Remote_Addr "[^"]*" red_interna',
           r'SetEnvIf Remote_Addr "^(127\\.|192\\.168\\.(10|20|30|40|50|60|99)\\.|172\\.16\\.100\\.|100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.)" red_interna', s)
# 3. Zabbix solo administracion
s = re.sub(r'(<Location /zabbix/>\s*\n\s*Require ip)[^\n]*', r'\1 127.0.0.1 192.168.10.0/24 192.168.40.0/24 100.64.0.0/10', s)
if s != o: open(f, 'w').write(s); print("  [OK] mejoland-publico.conf actualizado")
else: print("  ya estaba")
PY
grep -nE "ServerAlias www|SetEnvIf Remote_Addr|Require ip" $C | sed 's/^/    /'
if apache2ctl configtest >/dev/null 2>&1; then systemctl reload apache2 && echo "  [OK] Apache recargado"
else echo "  [AVISO] error en Apache, restaurando"; apache2ctl configtest 2>&1 | tail -3; cp -a $BK/$(basename $C) $C; systemctl reload apache2; fi
echo; echo "== Pruebas locales (200/301/302 = bien)"
for p in plataforma/ webmail/ glpi/ nube/; do
  printf '    %-40s %s\n' "https://mejoland.edu.ec/$p" "$(curl -sk -o /dev/null -m 15 -w '%{http_code}' --resolve mejoland.edu.ec:443:127.0.0.1 https://mejoland.edu.ec/$p)"
done
echo; echo "LISTO. Respaldo: $BK"
echo "Desde la casa (celular): https://mejoland.edu.ec/plataforma/   (o https://10.1.60.10/plataforma/)"
