#!/bin/bash
# =====================================================================
#  Integra los servidores de la Mac al proyecto (root)
#  - En SRV-BD: nombres DNS glpi / nube / monitoreo / srv-aaa-2 en mejoland.edu.ec
#               (damian-1 los copia solo por ser DNS secundario)
#  - En SRV-BD y damian-1: widgets en el portal de EduNova (/etc/edunova/servicios.json)
#  Uso: bash 02-integrar-apps.sh      (primero en SRV-BD, luego en damian-1)
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
APPS=100.107.96.3; MON=100.123.222.5; AAA2=100.74.49.76
BK=/root/proyecto/integrar-apps-$(date +%Y%m%d-%H%M); mkdir -p $BK; chmod 700 $BK

Z=/etc/bind/db.mejoland.edu.ec
if [ -f $Z ] && grep -q "type master" /etc/bind/named.conf.local 2>/dev/null; then
  echo "== DNS (zona maestra en este equipo)"
  cp -a $Z $BK/
  add() { grep -qE "^$1[[:space:]]" $Z || { printf '%-11s IN %-5s %s\n' "$1" "$2" "$3" >> $Z; echo "  + $1 -> $3"; }; }
  add srv-apps A $APPS; add srv-monitoreo A $MON; add srv-aaa-2 A $AAA2
  add glpi CNAME srv-apps; add nube CNAME srv-apps; add monitoreo CNAME srv-monitoreo
  S=$(grep -oE '[0-9]{10}' $Z | head -1); sed -i "0,/$S/s//$((S+1))/" $Z
  if named-checkzone mejoland.edu.ec $Z >/dev/null; then rndc reload mejoland.edu.ec >/dev/null; echo "  zona recargada (serial $((S+1))); damian-1 la copia sola"
  else echo "  ERROR en la zona: restaurando"; cp -a $BK/$(basename $Z) $Z; fi
  for n in glpi nube monitoreo; do printf '  %-28s -> %s\n' "$n.mejoland.edu.ec" "$(dig +short @127.0.0.1 $n.mejoland.edu.ec | tail -1)"; done
else
  echo "== DNS: este equipo no tiene la zona maestra (se omite; damian-1 la recibe de SRV-BD)"
fi

J=/etc/edunova/servicios.json
if [ -f $J ]; then
  echo "== Widgets de EduNova"
  cp -a $J $BK/
  python3 - "$J" "$APPS" "$MON" <<'PY'
import json, sys
p, apps, mon = sys.argv[1:4]
d = json.load(open(p, encoding='utf-8'))
nuevos = [
  {"id": "glpi", "nombre": "Soporte técnico (GLPI)",
   "descripcion": "Reporta fallas de equipos y pide ayuda a TI. Entra con tu usuario y clave institucional.",
   "icono": "enlace", "url": f"http://{apps}/glpi/", "roles": ["admin", "teacher", "student", "secretary"], "grupos": []},
  {"id": "nube", "nombre": "Nube institucional (Nextcloud)",
   "descripcion": "Guarda y comparte archivos. Entra con tu usuario y clave institucional.",
   "icono": "archivos", "url": f"http://{apps}/nube/", "roles": ["admin", "teacher", "student", "secretary"], "grupos": []},
  {"id": "zabbix", "nombre": "Monitoreo de servidores (Zabbix)",
   "descripcion": "Estado de los 7 servidores: CPU, memoria, disco y alertas.",
   "icono": "monitoreo", "url": f"http://{mon}/zabbix/", "roles": [], "grupos": ["admins-red"]},
]
ids = {s["id"] for s in d["servicios"]}
for n in nuevos:
    if n["id"] in ids:
        d["servicios"] = [n if s["id"] == n["id"] else s for s in d["servicios"]]; print("  ~ actualizado:", n["nombre"])
    else:
        d["servicios"].append(n); print("  + agregado:  ", n["nombre"])
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
  python3 -m json.tool $J >/dev/null && echo "  servicios.json valido (se aplica sin reiniciar EduNova)" \
    || { echo "  ERROR en servicios.json: restaurando"; cp -a $BK/servicios.json $J; }
else
  echo "== No existe $J en este equipo (se omite)"
fi
echo; echo "LISTO. Respaldo en $BK"
