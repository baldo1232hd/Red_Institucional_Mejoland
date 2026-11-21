"""
Prueba local de Centinela: evalua ataques tipicos (inundacion de ping, DDoS, fuerza bruta e IP
bloqueada) con el modelo instalado en /opt/centinela y muestra la decision y la explicacion del LLM.
Uso (en el equipo de Centinela):  /opt/centinela/venv/bin/python centinela-probar.py
"""
import sys, time, json
sys.path.insert(0, "/opt/centinela")
import centinela as C
CASOS = [
 ("Inundacion de ping desde casa 3", dict(servidor="srv-bd", ip="10.1.50.2", pings=24000, descartes_escudo=21000)),
 ("DDoS desde un estudiante", dict(servidor="srv-bd", ip="192.168.30.40", conexiones_web=820, conexiones_nuevas_s=310, peticiones_http=22000, errores_http=1500, descartes_escudo=9000)),
 ("Fuerza bruta al correo desde casa 2", dict(servidor="correo", ip="192.168.200.50", ssh_fallidos=85, puertos_distintos=2)),
 ("IP bloqueada que insiste", dict(servidor="correo", ip="181.10.2.2", descartes_escudo=1000)),
]
for n, kw in CASOS:
    ev = C.Evento(**kw); d = C.decidir(ev, C.M); t = time.time()
    exp, origen = C.explicar(ev, d)
    print(f"== {n}: ML={d['clase']} riesgo={d['riesgo']} ({time.time()-t:.1f} s)")
    print(json.dumps(exp, ensure_ascii=False, indent=1)); print()
