"""
Zabbix: grupo y tablero "Seguridad" - Centro Educativo Mejoland  (ejecutar en srv-monitoreo)
Crea por la API de Zabbix el grupo "Seguridad" y el equipo tuf-centinela (agente activo) con sus
datos (API y LLM de Centinela, incidentes por tipo, paquetes descartados por el escudo, uso y
temperatura de la GPU), las alertas correspondientes y el tablero "Seguridad".
Requiere el agente de Zabbix en el equipo de Centinela con las claves centinela.* y gpu.*.
Uso:  ZABBIX_CLAVE=... python3 04-zabbix-seguridad.py   (si no se define, la pide por teclado)
"""
import json, urllib.request, time, os, getpass
U = "http://100.123.222.5/zabbix/api_jsonrpc.php"
def call(m, p, t=None):
    h = {"Content-Type": "application/json-rpc"}
    if t: h["Authorization"] = "Bearer " + t
    r = json.load(urllib.request.urlopen(urllib.request.Request(U, json.dumps({"jsonrpc": "2.0", "method": m, "params": p, "id": 1}).encode(), h), timeout=30))
    if "error" in r: print(m, "ERROR", r["error"])
    return r.get("result")
t = call("user.login", {"username": "Admin", "password": os.environ.get("ZABBIX_CLAVE") or getpass.getpass("Clave de Admin en Zabbix: ")})
tpl = call("template.get", {"filter": {"host": ["Linux by Zabbix agent active"]}, "output": ["templateid"]}, t)[0]["templateid"]
g = call("hostgroup.get", {"filter": {"name": ["Seguridad"]}, "output": ["groupid"]}, t)
gid = g[0]["groupid"] if g else call("hostgroup.create", {"name": "Seguridad"}, t)["groupids"][0]
h = call("host.get", {"filter": {"host": ["tuf-centinela"]}, "output": ["hostid"]}, t)
hid = h[0]["hostid"] if h else call("host.create", {"host": "tuf-centinela", "name": "tuf-centinela (ML + LLM)", "groups": [{"groupid": gid}], "templates": [{"templateid": tpl}]}, t)["hostids"][0]
print("host", hid)
A = "7"  # agente activo
items = [
 ("Centinela: API (codigo HTTP)", "centinela.http", "3", "", "30s"),
 ("Centinela: LLM disponibles", "centinela.llm_ok", "3", "", "30s"),
 ("Centinela: Ollama (codigo HTTP)", "centinela.ollama", "3", "", "30s"),
 ("Centinela: precision del modelo", "centinela.precision", "0", "%", "5m"),
 ("Incidentes medios y altos (5 min)", "centinela.inc[total]", "3", "", "30s"),
 ("Incidentes nivel alto (5 min)", "centinela.inc[nivel:alto]", "3", "", "30s"),
 ("Incidentes: fuerza bruta (5 min)", "centinela.inc[fuerza_bruta]", "3", "", "30s"),
 ("Incidentes: inundacion web (5 min)", "centinela.inc[inundacion_web]", "3", "", "30s"),
 ("Incidentes: inundacion de ping (5 min)", "centinela.inc[inundacion_ping]", "3", "", "30s"),
 ("Incidentes: escaneo de puertos (5 min)", "centinela.inc[escaneo_puertos]", "3", "", "30s"),
 ("Incidentes: ataque contenido (5 min)", "centinela.inc[ataque_contenido]", "3", "", "30s"),
 ("Escudo: paquetes descartados (5 min)", "centinela.descartes", "3", "", "30s"),
 ("GPU: uso", "gpu.uso", "3", "%", "10s"),
 ("GPU: VRAM usada", "gpu.vram_mb", "3", "MB", "30s"),
 ("GPU: temperatura", "gpu.temp", "0", "°C", "30s"),
]
existentes = {i["key_"]: i["itemid"] for i in call("item.get", {"hostids": [hid], "output": ["key_"]}, t)}
for n, k, vt, un, d in items:
    if k not in existentes:
        call("item.create", {"hostid": hid, "name": n, "key_": k, "type": A, "value_type": vt, "units": un, "delay": d,
                             "tags": [{"tag": "scope", "value": "security"}]}, t)
H = "tuf-centinela"
trig = [
 ("Centinela no responde", f"last(/{H}/centinela.http)<>200", "4"),
 ("Centinela: ningun LLM disponible", f"last(/{H}/centinela.llm_ok)=0", "3"),
 ("Centinela: incidente de nivel alto en los ultimos 5 minutos", f"last(/{H}/centinela.inc[nivel:alto])>0", "4"),
 ("Centinela: escaneo de puertos detectado", f"last(/{H}/centinela.inc[escaneo_puertos])>0", "2"),
 ("GPU del LLM sobre 90 °C", f"last(/{H}/gpu.temp)>90", "3"),
]
ya = {x["description"] for x in call("trigger.get", {"hostids": [hid], "output": ["description"]}, t)}
for n, e, s in trig:
    if n not in ya: call("trigger.create", {"description": n, "expression": e, "priority": s, "tags": [{"tag": "scope", "value": "security"}]}, t)
print("items y alertas listos")

# ---- tablero Seguridad ----
def F(tp, n, v): return {"type": tp, "name": n, "value": str(v)}
def iid(k): return call("item.get", {"hostids": [hid], "filter": {"key_": k}, "output": ["itemid"]}, t)[0]["itemid"]
def valor(nombre, k, x, y, w=12, h=3, extra=[]):
    return {"type": "item", "name": nombre, "x": x, "y": y, "width": w, "height": h, "view_mode": "0",
            "fields": [F(0, "rf_rate", 30), F(4, "itemid.0", iid(k))] + extra}
def graf(nombre, x, y, w, h, series, pct=False):
    fl = [F(0, "rf_rate", 10), F(1, "time_period.from", "now-1h"), F(1, "time_period.to", "now"), F(0, "righty", 0)]
    col = ["E53935", "FB8C00", "FDD835", "8E24AA", "1E88E5", "43A047", "00ACC1"]
    for i, it in enumerate(series):
        fl += [F(1, f"ds.{i}.hosts.0", H), F(1, f"ds.{i}.items.0", it), F(1, f"ds.{i}.color", col[i % 7]), F(0, f"ds.{i}.width", 2), F(0, f"ds.{i}.fill", 0), F(0, f"ds.{i}.transparency", 0)]
    if pct: fl += [F(1, "lefty_min", 0), F(1, "lefty_max", 100)]
    return {"type": "svggraph", "name": nombre, "x": x, "y": y, "width": w, "height": h, "view_mode": "0", "fields": fl}
umbral = lambda verde, amarillo, rojo: [F(1, "thresholds.0.color", "00C853"), F(1, "thresholds.0.threshold", verde),
                                      F(1, "thresholds.1.color", "FFD54F"), F(1, "thresholds.1.threshold", amarillo),
                                      F(1, "thresholds.2.color", "FF465C"), F(1, "thresholds.2.threshold", rojo)]
W = [
 {"type": "problems", "name": "Alertas de seguridad", "x": 0, "y": 0, "width": 48, "height": 4, "view_mode": "0",
  "fields": [F(0, "rf_rate", 30), F(1, "tags.0.tag", "scope"), F(0, "tags.0.operator", 1), F(1, "tags.0.value", "security"), F(0, "show_tags", 3)]},
 valor("Centinela API", "centinela.http", 48, 0, 12, 2),
 valor("LLM disponibles", "centinela.llm_ok", 60, 0, 12, 2),
 valor("Precision del modelo", "centinela.precision", 48, 2, 12, 2),
 valor("Ollama", "centinela.ollama", 60, 2, 12, 2),
 graf("Incidentes por tipo (ventana de 5 min)", 0, 4, 36, 6, ["Incidentes: fuerza bruta (5 min)", "Incidentes: inundacion web (5 min)", "Incidentes: inundacion de ping (5 min)", "Incidentes: escaneo de puertos (5 min)", "Incidentes: ataque contenido (5 min)"]),
 graf("Escudo: paquetes descartados (5 min)", 36, 4, 36, 6, ["Escudo: paquetes descartados (5 min)"]),
 graf("GPU del LLM: uso (%)", 0, 10, 24, 5, ["GPU: uso"], pct=True),
 graf("GPU del LLM: VRAM (MB)", 24, 10, 24, 5, ["GPU: VRAM usada"]),
 graf("Temperatura TUF: GPU y CPU (°C)", 48, 10, 24, 5, ["GPU: temperatura", "Temperatura CPU"]),
 {"type": "honeycomb", "name": "Nucleos de la TUF (ahora)", "x": 0, "y": 15, "width": 72, "height": 4, "view_mode": "0",
  "fields": [F(0, "rf_rate", 10), F(3, "hostids.0", hid), F(1, "items.0", "Núcleo*"), F(0, "interpolation", 1)] + umbral(0, 50, 80)},
]
d = call("dashboard.get", {"filter": {"name": ["Seguridad"]}, "output": ["dashboardid"]}, t)
if d:
    print("tablero:", call("dashboard.update", {"dashboardid": d[0]["dashboardid"], "pages": [{"widgets": W}]}, t))
else:
    print("tablero:", call("dashboard.create", {"name": "Seguridad", "display_period": 30, "auto_start": 1, "pages": [{"widgets": W}]}, t))
