"""
CENTINELA MEJOLAND - deteccion de ataques con machine learning + explicacion con LLM
Centro Educativo Mejoland. Corre en la ASUS TUF (Windows).

  Machine learning (procesador):
    - IsolationForest: aprende como es el trafico normal y marca lo que se aleja (anomalia).
    - RandomForest: reconoce el tipo de ataque (fuerza bruta, inundacion web, inundacion de ping, escaneo).
  Motor de decisiones: combina ML + reglas fijas -> riesgo 0-100, nivel y accion recomendada.
      Nunca recomienda bloquear IP de la lista de confianza (servidores, administracion).
  LLM (Ollama, tarjeta grafica): solo EXPLICA los incidentes medios y altos. No decide nada.
      Al LLM solo le llegan numeros validados, nunca texto de los registros (evita que lo enganen).

Uso:   python centinela.py              (API en el puerto 8800)
       python centinela.py --entrenar   (vuelve a entrenar los modelos)
"""
import ipaddress
import json
import os
import sqlite3
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

import joblib
import numpy as np
import requests
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field
from sklearn.ensemble import IsolationForest, RandomForestClassifier

VERSION = "1.3"
BASE = Path(__file__).resolve().parent
DB = BASE / "centinela.db"
ETIQUETADOS = BASE / "etiquetados.jsonl"   # ejemplos reales etiquetados a mano
MODELOS = BASE / "modelos.joblib"
PUERTO = int(os.environ.get("CENTINELA_PUERTO", "8800"))
TOKEN = os.environ.get("CENTINELA_TOKEN", "")
LLMS = [u.strip().rstrip("/") for u in os.environ.get("CENTINELA_LLM", "http://127.0.0.1:11434").split(",") if u.strip()]
MODELO_LLM = os.environ.get("CENTINELA_MODELO", "qwen3:8b")
CONFIANZA = [ipaddress.ip_network(n.strip(), strict=False) for n in os.environ.get(
    "CENTINELA_CONFIANZA",
    "127.0.0.0/8,192.168.10.0/24,192.168.40.10/32,192.168.40.11/32,192.168.40.12/32,192.168.40.13/32,"
    "192.168.40.20/32,192.168.40.21/32,192.168.40.100/32,192.168.60.10/32,"
    "100.89.203.22/32,100.93.52.67/32,100.65.119.48/32,100.75.163.23/32,100.74.49.76/32,"
    "100.123.222.5/32,100.107.96.3/32").split(",") if n.strip()]

# --- Caracteristicas que envia cada servidor por IP de origen y por ventana de tiempo (1 minuto) ---
CAMPOS = ["ssh_fallidos", "ssh_exitosos", "conexiones_web", "conexiones_nuevas_s", "peticiones_http",
          "errores_http", "pings", "puertos_distintos", "descartes_escudo"]
CLASES = ["normal", "fuerza_bruta", "inundacion_web", "inundacion_ping", "escaneo_puertos", "ataque_contenido"]
NOMBRES = {"normal": "Trafico normal", "fuerza_bruta": "Fuerza bruta de claves (SSH/correo)",
           "inundacion_web": "Inundacion de conexiones web (DoS/DDoS)", "inundacion_ping": "Inundacion de ping (ICMP)",
           "escaneo_puertos": "Escaneo de puertos",
           "ataque_contenido": "Ataque en curso ya contenido por el escudo (la IP bloqueada sigue insistiendo)"}
MITRE = {"fuerza_bruta": "T1110 Brute Force", "inundacion_web": "T1499 Endpoint Denial of Service",
         "inundacion_ping": "T1498 Network Denial of Service", "escaneo_puertos": "T1046 Network Service Discovery",
         "ataque_contenido": "T1499/T1498 Denial of Service (contenido)"}

CONTEXTO_RED = """Red del Centro Educativo Mejoland v5 (detalle completo en el rol del analista, Modelfile):
servidores en VLAN 40 y correo en la DMZ VLAN 60; bordes R1/R3 con NAT (publicado 10.1.40.13); nube emulada con MikroTik, R4, R5 y VyOS.
Defensas: MikroTik ddos-bloqueados, escudo nftables, fail2ban, ufw."""


# =====================================================================================
#  Machine learning
# =====================================================================================
def _simular(clase, n, r):
    """Datos de entrenamiento simulados por tipo de trafico (por IP y por minuto)."""
    def u(a, b): return r.integers(a, b + 1, n)
    z = np.zeros(n, dtype=int)
    if clase == "normal":
        cols = [r.choice([0, 0, 0, 1, 2], n), u(0, 3), u(0, 40), u(0, 8), u(0, 250), u(0, 12), u(0, 4), u(1, 4), z]
        # Muchos minutos solo tienen una actividad (solo SSH, solo web...): se apagan columnas al azar
        cols = [c * (r.random(n) < 0.55) if i != 7 else c for i, c in enumerate(cols)]
    elif clase == "fuerza_bruta":
        cols = [u(12, 600), u(0, 1), u(0, 5), u(0, 3), u(0, 20), u(0, 5), u(0, 3), u(1, 2), u(0, 200)]
    elif clase == "inundacion_web":
        cols = [z, z, u(120, 6000), u(40, 3000), u(400, 80000), u(0, 6000), u(0, 10), u(1, 3), u(0, 200000)]
    elif clase == "inundacion_ping":
        cols = [z, z, u(0, 10), u(0, 3), u(0, 50), u(0, 5), u(150, 200000), u(0, 2), u(0, 200000)]
    elif clase == "ataque_contenido":
        # La IP ya esta bloqueada: el sensor solo ve los paquetes que el escudo descarta
        cols = [z, z, u(0, 3), u(0, 2), u(0, 5), u(0, 2), u(0, 3), u(0, 1), u(150, 200000)]
    else:  # escaneo_puertos
        cols = [u(0, 3), z, u(0, 15), u(0, 60), u(0, 30), u(0, 20), u(0, 20), u(15, 1000), u(0, 2000) * (r.random(n) < 0.5)]
    return np.column_stack(cols)


def entrenar(datos_reales=None):
    r = np.random.default_rng(2026)
    X, y = [], []
    for c in CLASES:
        m = _simular(c, 4000 if c == "normal" else 1200, r)
        X.append(m); y += [c] * len(m)
    etiquetados = 0
    if ETIQUETADOS.exists():
        for linea in ETIQUETADOS.read_text().splitlines():
            if not linea.strip(): continue
            e = json.loads(linea)
            base = np.array([e["datos"].get(k, 0) for k in CAMPOS], float)
            copias = np.rint(base * r.uniform(0.7, 1.3, (60, len(CAMPOS))))   # 60 variaciones de cada caso real
            X.append(copias.astype(int)); y += [e["clase"]] * 60; etiquetados += 1
    X = np.log1p(np.vstack(X).astype(float))
    normal = X[np.array(y) == "normal"]
    if datos_reales is not None and len(datos_reales):
        normal = np.vstack([normal, np.log1p(np.asarray(datos_reales, float))])
    anomalia = IsolationForest(n_estimators=200, contamination=0.01, random_state=2026).fit(normal)
    # Validacion: 25 % de los datos se aparta para medir la precision antes del entrenamiento final
    from sklearn.model_selection import train_test_split
    from sklearn.metrics import accuracy_score, classification_report
    Xa, Xp, ya, yp = train_test_split(X, y, test_size=0.25, random_state=2026, stratify=y)
    prueba = RandomForestClassifier(n_estimators=200, max_depth=12, random_state=2026, n_jobs=-1).fit(Xa, ya)
    pred = prueba.predict(Xp)
    rep = classification_report(yp, pred, output_dict=True, zero_division=0)
    validacion = {"precision_global": round(accuracy_score(yp, pred), 4),
                  "por_clase": {c: {"precision": round(rep[c]["precision"], 3), "deteccion": round(rep[c]["recall"], 3),
                                    "muestras_prueba": int(rep[c]["support"])} for c in CLASES if c in rep}}
    clasificador = RandomForestClassifier(n_estimators=200, max_depth=12, random_state=2026, n_jobs=-1).fit(X, y)
    joblib.dump({"anomalia": anomalia, "clasificador": clasificador, "campos": CAMPOS,
                 "entrenado": datetime.now().isoformat(timespec="seconds"),
                 "normales_reales": 0 if datos_reales is None else len(datos_reales),
                 "ejemplos_reales_etiquetados": etiquetados, "validacion": validacion}, MODELOS)
    return joblib.load(MODELOS)


def cargar_modelos():
    if MODELOS.exists():
        m = joblib.load(MODELOS)
        if m.get("campos") == CAMPOS:
            return m
    return entrenar()


# =====================================================================================
#  Motor de decisiones
# =====================================================================================
def de_confianza(ip):
    a = ipaddress.ip_address(ip)
    return any(a in n for n in CONFIANZA)


def decidir(ev, M):
    v = np.array([[getattr(ev, c) for c in CAMPOS]], float)
    x = np.log1p(v)
    puntaje = float(M["anomalia"].decision_function(x)[0])          # < 0 = anomalo
    p = M["clasificador"].predict_proba(x)[0]
    clases = list(M["clasificador"].classes_)
    clase = clases[int(p.argmax())]
    prob = float(p.max())
    riesgo_ml = 0.0 if clase == "normal" else prob * 100
    riesgo_anom = float(np.clip(-puntaje * 400, 0, 100))
    # Reglas fijas (no dependen del ML)
    reglas = []
    if ev.ssh_fallidos >= 20: reglas.append(("ssh_fallidos >= 20", 75))
    if ev.conexiones_web >= 300: reglas.append(("conexiones_web >= 300 (limite del escudo)", 80))
    if ev.pings >= 1200: reglas.append(("pings >= 20/s", 70))
    if ev.puertos_distintos >= 20: reglas.append(("puertos_distintos >= 20", 70))
    if ev.descartes_escudo > 0: reglas.append(("el escudo ya descarto paquetes", 60))
    riesgo_reglas = max([r for _, r in reglas], default=0)
    riesgo = round(max(riesgo_ml, riesgo_anom * 0.8, riesgo_reglas))
    if clase == "ataque_contenido":
        riesgo = min(riesgo, 60)   # ya esta bloqueado y no llega al servicio: vigilar, no escalar
    if clase == "normal" and riesgo >= 40:
        clase = "anomalia_desconocida"
    nivel = "alto" if riesgo >= 70 else "medio" if riesgo >= 40 else "bajo"
    confiable = de_confianza(ev.ip)
    if nivel == "alto" and not confiable:
        accion = "bloquear_temporal"; detalle = "Bloquear la IP 10 minutos en el escudo y avisar al administrador"
    elif nivel == "alto":
        accion = "alertar"; detalle = "IP de confianza: NO se bloquea; revisar manualmente (puede ser una prueba o un equipo comprometido)"
    elif nivel == "medio":
        accion = "alertar"; detalle = "Avisar al administrador y vigilar la IP"
    else:
        accion = "observar"; detalle = "Sin accion"
    return {"clase": clase, "tipo": NOMBRES.get(clase, "Comportamiento anomalo no clasificado"),
            "mitre": MITRE.get(clase, ""), "probabilidad": round(prob, 3), "anomalia": round(puntaje, 4),
            "riesgo": riesgo, "nivel": nivel, "ip_de_confianza": confiable, "accion": accion,
            "accion_detalle": detalle, "reglas": [t for t, _ in reglas]}


# =====================================================================================
#  LLM (solo explica)
# =====================================================================================
_cache = {}
_cache_lock = threading.Lock()


INTERNAS = [ipaddress.ip_network(n) for n in ("192.168.10.0/24", "192.168.20.0/24", "192.168.30.0/24",
                                                "192.168.40.0/24", "192.168.50.0/24", "192.168.60.0/24")]


def pasos_recomendados(ev, d):
    """Pasos fijos segun el tipo de ataque y el origen. El LLM solo los redacta: no los elige."""
    ip = ev.ip
    interna = any(ipaddress.ip_address(ip) in n for n in INTERNAS)
    c = d["clase"]
    p = []
    if c == "fuerza_bruta":
        p += ["Confirmar el bloqueo de fail2ban: sudo fail2ban-client status sshd",
              f"Comprobar que ningun intento entro: sudo grep Accepted /var/log/auth.log | grep {ip}"]
    elif c in ("inundacion_web", "inundacion_ping", "anomalia_desconocida"):
        p += ["Confirmar el bloqueo en el escudo: sudo nft list set inet mejoland_escudo bloqueados",
              "Revisar en Zabbix (tablero Prueba de capacidad) que el servidor siga respondiendo"]
    elif c == "escaneo_puertos":
        p += ["Verificar que solo esten abiertos los puertos esperados: sudo ss -tlnp",
              "Vigilar la IP: un escaneo suele preceder a un ataque"]
    elif c == "ataque_contenido":
        p += ["Verificar que siga bloqueada: sudo nft list set inet mejoland_escudo bloqueados",
              "No actuar sobre el servicio: el ataque no esta llegando"]
    if d["ip_de_confianza"]:
        p.append("Es IP de confianza: NO bloquearla; confirmar con el equipo si es una prueba o un equipo comprometido")
    elif interna:
        p.append(f"Ubicar el equipo interno: en SWdistri 'show ip dhcp binding | include {ip}' y 'show mac address-table address <mac>'")
    elif c != "normal":
        p.append("Ver si el MikroTik tambien la aislo: /ip firewall address-list print where list=ddos-bloqueados")
    return interna, p


def explicar(ev, d):
    clave = (ev.ip, ev.servidor, d["clase"])
    with _cache_lock:
        c = _cache.get(clave)
        if c and time.time() - c[0] < 120:
            return c[1], c[2] + " (reutilizada)"
    ultimo = "sin LLM configurado"
    datos = {k: getattr(ev, k) for k in CAMPOS}
    interna, pasos = pasos_recomendados(ev, d)
    prompt = (f"{CONTEXTO_RED}\n\nIncidente detectado por el sistema (datos numericos de 1 minuto):\n"
              f"servidor={ev.servidor}  ip_origen={ev.ip}  ip_de_confianza={d['ip_de_confianza']}\n"
              f"metricas={json.dumps(datos)}\nclasificacion_ML={d['tipo']}  riesgo={d['riesgo']}/100  nivel={d['nivel']}\n"
              f"accion_decidida={d['accion_detalle']}\n"
              f"origen={'INTERNO del colegio' if interna else 'EXTERNO (casas o Internet)'}\n"
              f"pasos_del_sistema={json.dumps(pasos, ensure_ascii=False)}\n"
              "En que_revisar usa EXACTAMENTE los pasos_del_sistema (numeralos y redactalos, sin agregar otros comandos).\n\n"
              "Responde SOLO en JSON en espanol con estas claves: "
              '{"resumen": "1-2 frases para el administrador", "por_que": "que metricas lo delatan", '
              '"que_revisar": "1-3 pasos concretos", "falso_positivo_posible": "si/no y por que"}. '
              "No inventes IP ni datos que no esten arriba.")
    for url in LLMS:
        try:
            t = time.time()
            r = requests.post(f"{url}/api/chat", timeout=(3, 40), json={  # 3 s para conectar: si un LLM esta apagado, pasa rapido al siguiente
                "model": MODELO_LLM, "stream": False, "think": False, "format": "json",
                "options": {"temperature": 0.2},
                # El modelo personalizado (mejoland-analista) ya trae su propio rol y ejemplos en el Modelfile
                "messages": ([] if MODELO_LLM.startswith("mejoland") else
                             [{"role": "system", "content": "Eres analista de ciberseguridad de una red escolar. Eres breve y preciso."}])
                            + [{"role": "user", "content": prompt}]})
            r.raise_for_status()
            texto = r.json()["message"]["content"]
            try:
                exp = json.loads(texto)
            except ValueError:
                exp = {"resumen": texto.strip()[:600]}
            origen = f"{url} ({time.time() - t:.1f} s)"
            with _cache_lock:
                _cache[clave] = (time.time(), exp, origen)
            return exp, origen
        except Exception as e:  # prueba el siguiente LLM (respaldo)
            ultimo = f"{url}: {type(e).__name__}"
    return None, "LLM no disponible (" + ultimo + ")"


# =====================================================================================
#  Base de datos (auditoria)
# =====================================================================================
def db():
    c = sqlite3.connect(DB, timeout=10)
    c.execute("""CREATE TABLE IF NOT EXISTS incidentes (id INTEGER PRIMARY KEY AUTOINCREMENT, cuando TEXT,
                 servidor TEXT, ip TEXT, clase TEXT, riesgo INTEGER, nivel TEXT, accion TEXT,
                 datos TEXT, decision TEXT, explicacion TEXT, llm TEXT)""")
    return c


# =====================================================================================
#  API
# =====================================================================================
class Evento(BaseModel):
    servidor: str = Field(pattern=r"^[a-z0-9-]{1,30}$")
    ip: str
    ventana_s: int = Field(60, ge=1, le=3600)
    ssh_fallidos: int = Field(0, ge=0)
    ssh_exitosos: int = Field(0, ge=0)
    conexiones_web: int = Field(0, ge=0)
    conexiones_nuevas_s: int = Field(0, ge=0)
    peticiones_http: int = Field(0, ge=0)
    errores_http: int = Field(0, ge=0)
    pings: int = Field(0, ge=0)
    puertos_distintos: int = Field(0, ge=0)
    descartes_escudo: int = Field(0, ge=0)


M = cargar_modelos()
app = FastAPI(title="Centinela Mejoland", version=VERSION)


def autorizar(token):
    if TOKEN and token != TOKEN:
        raise HTTPException(401, "token invalido")


@app.get("/salud")
def salud():
    llms = {}
    for url in LLMS:
        try:
            ok = requests.get(f"{url}/api/tags", timeout=(2, 3)).ok
        except Exception:
            ok = False
        llms[url] = "ok" if ok else "sin respuesta"
    return {"centinela": VERSION, "modelos_entrenados": M["entrenado"], "llm": llms, "modelo_llm": MODELO_LLM}


@app.post("/analizar")
def analizar(ev: Evento, explicar_llm: bool = True, x_token: str = Header("")):
    autorizar(x_token)
    try:
        ipaddress.ip_address(ev.ip)
    except ValueError:
        raise HTTPException(422, "ip invalida")
    t = time.time()
    d = decidir(ev, M)
    exp, origen = (None, "no requerido (nivel bajo)")
    if explicar_llm and d["nivel"] != "bajo":
        exp, origen = explicar(ev, d)
    datos = ev.model_dump()
    with db() as c:
        cur = c.execute("INSERT INTO incidentes (cuando,servidor,ip,clase,riesgo,nivel,accion,datos,decision,explicacion,llm)"
                        " VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                        (datetime.now().isoformat(timespec="seconds"), ev.servidor, ev.ip, d["clase"], d["riesgo"],
                         d["nivel"], d["accion"], json.dumps(datos), json.dumps(d), json.dumps(exp, ensure_ascii=False), origen))
    return {"id": cur.lastrowid, **d, "explicacion": exp, "llm": origen, "tiempo_s": round(time.time() - t, 2)}


@app.get("/incidentes")
def incidentes(limite: int = 30, minimo: str = "medio", x_token: str = Header("")):
    autorizar(x_token)
    niveles = {"bajo": ("bajo", "medio", "alto"), "medio": ("medio", "alto"), "alto": ("alto",)}.get(minimo, ("medio", "alto"))
    with db() as c:
        filas = c.execute(f"SELECT id,cuando,servidor,ip,clase,riesgo,nivel,accion,explicacion,llm FROM incidentes "
                          f"WHERE nivel IN ({','.join('?' * len(niveles))}) ORDER BY id DESC LIMIT ?",
                          (*niveles, max(1, min(limite, 500)))).fetchall()
    k = ["id", "cuando", "servidor", "ip", "clase", "riesgo", "nivel", "accion", "explicacion", "llm"]
    return [dict(zip(k, f[:8] + (json.loads(f[8]) if f[8] else None, f[9]))) for f in filas]


@app.get("/modelo")
def modelo():
    """Calidad del modelo: precision medida con datos apartados (no usados para entrenar)."""
    return {"version": VERSION, "entrenado": M.get("entrenado"), "clases": CLASES,
            "normales_reales": M.get("normales_reales", 0),
            "ejemplos_reales_etiquetados": M.get("ejemplos_reales_etiquetados", 0),
            "validacion": M.get("validacion", {})}


@app.post("/entrenar")
def reentrenar(x_token: str = Header("")):
    """Reentrena sumando el trafico real que el sistema clasifico como bajo (normal)."""
    autorizar(x_token)
    global M
    with db() as c:
        filas = [json.loads(f[0]) for f in c.execute("SELECT datos FROM incidentes WHERE nivel='bajo' ORDER BY id DESC LIMIT 20000")]
    reales = [[f.get(k, 0) for k in CAMPOS] for f in filas]
    M = entrenar(reales)
    return {"entrenado": M["entrenado"], "normales_reales_usados": len(reales),
            "ejemplos_reales_etiquetados": M.get("ejemplos_reales_etiquetados", 0), "validacion": M.get("validacion", {})}


if __name__ == "__main__":
    if "--entrenar" in sys.argv:
        M = entrenar(); print("Modelos entrenados:", M["entrenado"]); sys.exit(0)
    import uvicorn
    print(f"Centinela Mejoland {VERSION} en el puerto {PUERTO} | LLM: {', '.join(LLMS)} | token: {'SI' if TOKEN else 'NO (cualquiera puede enviar)'}")
    uvicorn.run(app, host="0.0.0.0", port=PUERTO, log_level="warning")
