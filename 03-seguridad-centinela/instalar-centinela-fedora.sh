#!/bin/bash
# =====================================================================
#  CENTINELA en FEDORA (ASUS TUF) - Centro Educativo Mejoland
#  Instala el mismo entorno que en Windows: Ollama + mejoland-analista (8B), Centinela (ML + API :8800),
#  arranque automatico, Tailscale y cortafuegos solo para Tailscale.
#  Uso:  sudo bash instalar-centinela-fedora.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutalo con sudo"; exit 1; }
D=/opt/centinela
ok() { echo "  [OK] $*"; }; av() { echo "  [AVISO] $*"; }; paso() { echo; echo "== $*"; }
echo "################ CENTINELA EN FEDORA: $(hostname) ################"

paso "1 Paquetes"
dnf install -y -q python3 python3-pip curl tailscale >/dev/null 2>&1 || dnf install -y python3 python3-pip curl
command -v tailscale >/dev/null || { dnf config-manager addrepo --from-repofile=https://pkgs.tailscale.com/stable/fedora/tailscale.repo >/dev/null 2>&1; dnf install -y -q tailscale; }
for c in python3 curl tailscale; do command -v $c >/dev/null && ok $c || av "falta $c"; done

paso "2 Ollama (usa la RX 7700S con ROCm o Vulkan)"
command -v ollama >/dev/null || curl -fsSL https://ollama.com/install.sh | sh
mkdir -p /etc/systemd/system/ollama.service.d
printf '[Service]\nEnvironment="OLLAMA_HOST=0.0.0.0"\nEnvironment="OLLAMA_KEEP_ALIVE=-1"\nEnvironment="OLLAMA_CONTEXT_LENGTH=8192"\n' > /etc/systemd/system/ollama.service.d/mejoland.conf
systemctl daemon-reload; systemctl enable --now ollama >/dev/null 2>&1; systemctl restart ollama; sleep 5
journalctl -u ollama --no-pager | grep -o 'inference compute.*' | tail -1 | sed 's/^/  /'

paso "3 Tailscale"
systemctl enable --now tailscaled >/dev/null 2>&1
if ! tailscale status >/dev/null 2>&1; then echo "  Abre el enlace que aparece e inicia sesion con la cuenta del proyecto:"; tailscale up; fi
ok "IP Tailscale: $(tailscale ip -4 2>/dev/null)"

paso "4 Cortafuegos: Ollama y Centinela solo para Tailscale; sin suspension"
for p in 11434 8800; do firewall-cmd -q --permanent --add-rich-rule="rule family=\"ipv4\" source address=\"100.64.0.0/10\" port port=\"$p\" protocol=\"tcp\" accept" 2>/dev/null; done
firewall-cmd -q --reload 2>/dev/null && ok "puertos 11434 y 8800 abiertos solo para Tailscale"
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1
mkdir -p /etc/systemd/logind.conf.d; printf '[Login]\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\n' > /etc/systemd/logind.conf.d/mejoland.conf
ok "no se suspende (ni al cerrar la tapa)"

paso "5 Centinela (ML + API)"
id centinela >/dev/null 2>&1 || useradd -r -s /sbin/nologin -d $D centinela
mkdir -p $D
cat > $D/centinela.py <<'PYEOF'
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

VERSION = "1.2"
BASE = Path(__file__).resolve().parent
DB = BASE / "centinela.db"
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
CLASES = ["normal", "fuerza_bruta", "inundacion_web", "inundacion_ping", "escaneo_puertos"]
NOMBRES = {"normal": "Trafico normal", "fuerza_bruta": "Fuerza bruta de claves (SSH/correo)",
           "inundacion_web": "Inundacion de conexiones web (DoS/DDoS)", "inundacion_ping": "Inundacion de ping (ICMP)",
           "escaneo_puertos": "Escaneo de puertos"}
MITRE = {"fuerza_bruta": "T1110 Brute Force", "inundacion_web": "T1499 Endpoint Denial of Service",
         "inundacion_ping": "T1498 Network Denial of Service", "escaneo_puertos": "T1046 Network Service Discovery"}

CONTEXTO_RED = """Red del Centro Educativo Mejoland (proyecto de redes):
VLAN 10 administracion 192.168.10.0/24 | VLAN 20 docentes 192.168.20.0/24 | VLAN 30 estudiantes 192.168.30.0/24
VLAN 40 servidores 192.168.40.0/24 | VLAN 60 DMZ: servidor de correo y proxy 192.168.60.10 | Internet llega por NAT al correo.
Servidores: srv-bd (EduNova, LDAP, MariaDB, DNS) y su replica damian; srv-aaa-1/2 (RADIUS); srv-apps (GLPI, nube);
srv-monitoreo (Zabbix); correo. Defensas: cortafuegos ufw, escudo nftables (limite por IP y bloqueo 10 min), fail2ban.
Los estudiantes solo deben usar la web (80/443); SSH desde estudiantes no es normal."""


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
    else:  # escaneo_puertos
        cols = [u(0, 3), z, u(0, 15), u(0, 60), u(0, 30), u(0, 20), u(0, 20), u(15, 1000), u(0, 2000) * (r.random(n) < 0.5)]
    return np.column_stack(cols)


def entrenar(datos_reales=None):
    r = np.random.default_rng(2026)
    X, y = [], []
    for c in CLASES:
        m = _simular(c, 4000 if c == "normal" else 1200, r)
        X.append(m); y += [c] * len(m)
    X = np.log1p(np.vstack(X).astype(float))
    normal = X[np.array(y) == "normal"]
    if datos_reales is not None and len(datos_reales):
        normal = np.vstack([normal, np.log1p(np.asarray(datos_reales, float))])
    anomalia = IsolationForest(n_estimators=200, contamination=0.01, random_state=2026).fit(normal)
    clasificador = RandomForestClassifier(n_estimators=200, max_depth=12, random_state=2026, n_jobs=-1).fit(X, y)
    joblib.dump({"anomalia": anomalia, "clasificador": clasificador, "campos": CAMPOS,
                 "entrenado": datetime.now().isoformat(timespec="seconds"),
                 "normales_reales": 0 if datos_reales is None else len(datos_reales)}, MODELOS)
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


def explicar(ev, d):
    clave = (ev.ip, ev.servidor, d["clase"])
    with _cache_lock:
        c = _cache.get(clave)
        if c and time.time() - c[0] < 120:
            return c[1], c[2] + " (reutilizada)"
    ultimo = "sin LLM configurado"
    datos = {k: getattr(ev, k) for k in CAMPOS}
    prompt = (f"{CONTEXTO_RED}\n\nIncidente detectado por el sistema (datos numericos de 1 minuto):\n"
              f"servidor={ev.servidor}  ip_origen={ev.ip}  ip_de_confianza={d['ip_de_confianza']}\n"
              f"metricas={json.dumps(datos)}\nclasificacion_ML={d['tipo']}  riesgo={d['riesgo']}/100  nivel={d['nivel']}\n"
              f"accion_decidida={d['accion_detalle']}\n\n"
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


@app.post("/entrenar")
def reentrenar(x_token: str = Header("")):
    """Reentrena sumando el trafico real que el sistema clasifico como bajo (normal)."""
    autorizar(x_token)
    global M
    with db() as c:
        filas = [json.loads(f[0]) for f in c.execute("SELECT datos FROM incidentes WHERE nivel='bajo' ORDER BY id DESC LIMIT 20000")]
    reales = [[f.get(k, 0) for k in CAMPOS] for f in filas]
    M = entrenar(reales)
    return {"entrenado": M["entrenado"], "normales_reales_usados": len(reales)}


if __name__ == "__main__":
    if "--entrenar" in sys.argv:
        M = entrenar(); print("Modelos entrenados:", M["entrenado"]); sys.exit(0)
    import uvicorn
    print(f"Centinela Mejoland {VERSION} en el puerto {PUERTO} | LLM: {', '.join(LLMS)} | token: {'SI' if TOKEN else 'NO (cualquiera puede enviar)'}")
    uvicorn.run(app, host="0.0.0.0", port=PUERTO, log_level="warning")
PYEOF
cat > $D/simular.py <<'PYEOF'
"""
SIMULADOR - envia a Centinela eventos de prueba (normal y ataques) y muestra como los clasifica.
Uso:  python simular.py                 (contra esta misma PC)
      python simular.py 100.124.36.19   (contra la TUF desde otro equipo)
"""
import os, sys, time, requests

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
URL = f"http://{HOST}:8800"
_t = os.path.join(os.path.dirname(os.path.abspath(__file__)), "token.txt")
TOKEN = os.environ.get("CENTINELA_TOKEN") or (open(_t).read().strip() if os.path.exists(_t) else "")
H = {"X-Token": TOKEN}
PRUEBAS = [
    ("Estudiante navegando EduNova", dict(servidor="srv-bd", ip="192.168.30.21", conexiones_web=12, conexiones_nuevas_s=3, peticiones_http=90, errores_http=2, puertos_distintos=2)),
    ("Administrador por SSH",        dict(servidor="srv-bd", ip="192.168.10.5", ssh_exitosos=1, puertos_distintos=1)),
    ("Fuerza bruta SSH",             dict(servidor="srv-bd", ip="192.168.30.15", ssh_fallidos=42, puertos_distintos=1)),
    ("Inundacion web (DoS)",         dict(servidor="srv-bd", ip="192.168.30.15", conexiones_web=900, conexiones_nuevas_s=400, peticiones_http=15000, errores_http=800, descartes_escudo=5000)),
    ("Inundacion de ping",           dict(servidor="correo", ip="200.50.1.9", pings=30000, descartes_escudo=28000)),
    ("Escaneo de puertos (nmap)",    dict(servidor="srv-apps", ip="192.168.30.40", puertos_distintos=180, conexiones_nuevas_s=20, errores_http=4)),
    ("Ataque desde IP de confianza", dict(servidor="srv-bd", ip="192.168.10.5", ssh_fallidos=60)),
]
print(requests.get(f"{URL}/salud", timeout=5).json(), "\n")
for nombre, ev in PRUEBAS:
    t = time.time()
    r = requests.post(f"{URL}/analizar", json=ev, headers=H, timeout=90).json()
    if "riesgo" not in r:
        print(nombre, "->", r); continue
    print(f"== {nombre}  ({ev['ip']} -> {ev['servidor']})")
    print(f"   ML: {r['tipo']}  | riesgo {r['riesgo']}/100 ({r['nivel']}) | accion: {r['accion']}  [{time.time()-t:.1f} s]")
    if r["explicacion"]:
        e = r["explicacion"]
        print(f"   LLM: {e.get('resumen','')}")
        if e.get("que_revisar"): print(f"        Revisar: {e['que_revisar']}")
    print(f"   ({r['llm']})\n")
PYEOF
cat > $D/Modelfile <<'MODELEOF'
# Analista de seguridad del Centro Educativo Mejoland (personaliza qwen3:8b sin reentrenarlo)
# Crear:  ollama create mejoland-analista -f Modelfile
FROM qwen3:8b
PARAMETER temperature 0.2
PARAMETER num_ctx 8192

SYSTEM """Eres el analista de ciberseguridad de la red del Centro Educativo Mejoland. Respondes SIEMPRE en espanol, breve y preciso.

RED:
- VLAN 10 administracion 192.168.10.0/24 (administradores: acabezas, dayala, ecacuango, iperez)
- VLAN 20 docentes 192.168.20.0/24 | VLAN 30 estudiantes 192.168.30.0/24 | VLAN 50 gestion de equipos de red
- VLAN 40 servidores: srv-bd .10 (EduNova, LDAP, MariaDB, DNS), srv-aaa-1 .11 y srv-aaa-2 .12 (RADIUS), damian .13 (replica de srv-bd),
  srv-monitoreo .20 (Zabbix), srv-apps .21 (GLPI y nube), IP virtual de EduNova .100
- VLAN 60 DMZ: correo y proxy inverso 192.168.60.10. Desde Internet solo se llega al correo por NAT (puertos 25, 80, 443, 587, 993).
- Red de administracion remota Tailscale 100.64.0.0/10.

LO NORMAL:
- Estudiantes y docentes usan solo la web (80/443). Administradores entran por SSH desde VLAN 10 o Tailscale.
- Los servidores hablan entre si (replica MariaDB y LDAP, Zabbix 10050/10051, proxy del correo hacia EduNova).
- Pocos fallos de clave aislados (1-3) son errores humanos, no ataques.

LO SOSPECHOSO:
- Muchos fallos SSH o de correo desde una IP: fuerza bruta (MITRE T1110).
- Cientos de conexiones web o miles de peticiones por minuto desde una IP: denegacion de servicio (T1499).
- Miles de pings por minuto: inundacion ICMP (T1498).
- Muchos puertos distintos tocados por una IP: escaneo de puertos (T1046), suele preceder a un ataque.
- SSH desde la VLAN de estudiantes nunca es normal.

DEFENSAS QUE YA EXISTEN: listas de acceso en los routers Cisco, cortafuegos ufw, escudo nftables (limite por IP, bloqueo 10 minutos),
filtro de puertos internos, fail2ban (6 fallos = 10 minutos bloqueado), alta disponibilidad (damian toma el control si srv-bd cae).

REGLAS:
- Usa solo los datos que te den. Nunca inventes IP, usuarios ni cifras.
- No ejecutas acciones: explicas y recomiendas; la decision la toma el sistema o el administrador.
- Si te piden JSON, responde solo JSON valido."""

MESSAGE user servidor=srv-bd ip_origen=192.168.30.15 metricas={"ssh_fallidos": 42, "puertos_distintos": 1} clasificacion_ML=Fuerza bruta riesgo=75 nivel=alto. Responde en JSON con resumen, por_que, que_revisar, falso_positivo_posible.
MESSAGE assistant {"resumen": "Fuerza bruta de SSH contra srv-bd desde un equipo de la VLAN de estudiantes (T1110).", "por_que": "42 claves fallidas en un minuto desde una sola IP; los estudiantes no deberian usar SSH.", "que_revisar": "1) Confirmar que fail2ban y el escudo la bloquearon. 2) Identificar el equipo 192.168.30.15 en el switch de acceso. 3) Revisar si algun intento fue exitoso.", "falso_positivo_posible": "no: el volumen y el origen no corresponden a un error humano"}
MESSAGE user servidor=srv-bd ip_origen=192.168.10.5 metricas={"ssh_fallidos": 2, "ssh_exitosos": 1} clasificacion_ML=Trafico normal riesgo=0 nivel=bajo. Responde en JSON con resumen, por_que, que_revisar, falso_positivo_posible.
MESSAGE assistant {"resumen": "Acceso administrativo normal a srv-bd desde la VLAN de administracion.", "por_que": "Dos fallos seguidos de un ingreso correcto: tipico error al escribir la clave.", "que_revisar": "Nada urgente.", "falso_positivo_posible": "no aplica: no es un incidente"}
MODELEOF
python3 -m venv $D/venv && $D/venv/bin/pip install -q --upgrade pip >/dev/null 2>&1
$D/venv/bin/pip install -q fastapi uvicorn scikit-learn joblib numpy requests && ok "librerias de Python"
if [ ! -s $D/token.txt ]; then
  echo "  Pega el MISMO token de Windows (C:\\centinela\\centinela\\token.txt) para que los servidores sirvan con ambos sistemas."
  read -r -p "  Token (Enter = crear uno nuevo): " T </dev/tty
  [ -n "$T" ] && printf '%s' "$T" > $D/token.txt || python3 -c "import uuid;print(uuid.uuid4().hex,end='')" > $D/token.txt
fi
chmod 600 $D/token.txt; chown -R centinela:centinela $D
cat > /etc/systemd/system/centinela.service <<EOF
[Unit]
Description=Centinela Mejoland (ML + LLM)
After=network-online.target ollama.service
Wants=network-online.target
[Service]
User=centinela
WorkingDirectory=$D
ExecStart=/bin/sh -c 'CENTINELA_TOKEN=\$\$(cat $D/token.txt) exec $D/venv/bin/python $D/centinela.py'
Environment=CENTINELA_LLM=http://127.0.0.1:11434,http://100.115.112.39:11434,http://100.78.26.62:11434
Environment=CENTINELA_MODELO=mejoland-analista
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

paso "6 Modelo mejoland-analista (8B)"
ollama pull qwen3:8b && (cd $D && ollama create mejoland-analista -f Modelfile) && ok "modelo creado"
ollama run mejoland-analista --think=false "Responde en una linea: que es la VLAN 30?" ; ollama ps | sed 's/^/  /'

paso "7 Arranque"
systemctl enable --now centinela >/dev/null 2>&1; sleep 12
curl -s http://127.0.0.1:8800/salud; echo
echo; echo "LISTO. Centinela arranca solo con Fedora. Prueba: cd $D && CENTINELA_TOKEN=\$(cat token.txt) venv/bin/python simular.py"
echo "Datos para Claude: IP Tailscale $(tailscale ip -4 2>/dev/null) | estado: systemctl status centinela ollama"
