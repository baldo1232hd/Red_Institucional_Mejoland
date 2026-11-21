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
