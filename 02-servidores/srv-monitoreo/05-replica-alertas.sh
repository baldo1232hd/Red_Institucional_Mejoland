#!/bin/bash
# =====================================================================
#  Alerta de replica - PARTE 2 (ejecutar en srv-monitoreo, root)
#  Crea en Zabbix, para SRV-BD y damian: 2 datos (estado y atraso) y 3 alertas:
#    ALTA:        "Replica MariaDB DETENIDA"      (estado = 0 durante 1 minuto)
#    ADVERTENCIA: "Replica MariaDB atrasada"      (atraso > 5 min durante 5 min)
#    ADVERTENCIA: "No se puede leer la replica"  (estado = -1)
#  Pide el usuario y la clave de Zabbix (no se muestran ni se guardan).
#  Uso:  bash 05-replica-alertas.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
read -r -p "Usuario de Zabbix [Admin]: " ZU; ZU=${ZU:-Admin}
read -r -s -p "Clave de $ZU: " ZP; echo
ZU="$ZU" ZP="$ZP" python3 - <<'PY'
import json, os, urllib.request
URL = "http://127.0.0.1/zabbix/api_jsonrpc.php"
tok = None
def api(m, p):
    h = {"Content-Type": "application/json-rpc"}
    if tok: h["Authorization"] = "Bearer " + tok
    r = urllib.request.urlopen(urllib.request.Request(URL, json.dumps({"jsonrpc": "2.0", "method": m, "params": p, "id": 1}).encode(), h), timeout=20)
    d = json.load(r)
    if "error" in d: raise SystemExit(f"  ERROR de Zabbix en {m}: {d['error'].get('data') or d['error'].get('message')}")
    return d["result"]
tok = api("user.login", {"username": os.environ["ZU"], "password": os.environ["ZP"]})
print("  Sesion en Zabbix: OK")
hosts = [h for h in api("host.get", {"output": ["hostid", "host"]}) if h["host"].lower() in ("srv-bd", "damian", "damian-1")]
if not hosts: raise SystemExit("  No encontre los equipos srv-bd / damian en Zabbix.")
for h in hosts:
    hid, n = h["hostid"], h["host"]
    print(f"== {n}")
    for key, name, units in [("mejoland.replica[estado]", "Replica MariaDB: estado (1 ok, 0 detenida, 2 no replica, -1 sin lectura)", ""),
                             ("mejoland.replica[atraso]", "Replica MariaDB: atraso", "s")]:
        if api("item.get", {"hostids": hid, "filter": {"key_": key}, "output": ["itemid"]}):
            print(f"  ya existe el dato {key}")
        else:
            api("item.create", {"hostid": hid, "name": name, "key_": key, "type": 7, "value_type": 0,
                                "delay": "30s", "units": units, "history": "7d", "trends": "30d"})
            print(f"  + dato {key}")
    trig = [(f"Replica MariaDB DETENIDA en {n}", f"max(/{n}/mejoland.replica[estado],1m)=0", 4,
             "La copia hacia el respaldo se detuvo. En el equipo: mysql -e \"SHOW SLAVE STATUS\\G\" y si es ALTER USER failed: bash /tmp/reparar-replica.sh"),
            (f"Replica MariaDB atrasada mas de 5 min en {n}", f"min(/{n}/mejoland.replica[atraso],5m)>300", 2,
             "El respaldo va atrasado. Si SRV-BD cae ahora, damian tomaria el control con datos viejos."),
            (f"No se puede leer el estado de la replica en {n}", f"last(/{n}/mejoland.replica[estado])=-1", 2,
             "El agente no puede consultar MariaDB (usuario zbxmon). Ejecuta de nuevo replica-agente.sh en el equipo.")]
    for desc, expr, prio, com in trig:
        if api("trigger.get", {"hostids": hid, "filter": {"description": desc}, "output": ["triggerid"]}):
            print(f"  ya existe la alerta: {desc}")
        else:
            api("trigger.create", {"description": desc, "expression": expr, "priority": prio, "comments": com})
            print(f"  + alerta: {desc}")
api("user.logout", [])
print("\nLISTO. En 1-2 minutos: Supervision -> Datos recientes -> filtrar 'Replica' para ver los valores.")
PY
