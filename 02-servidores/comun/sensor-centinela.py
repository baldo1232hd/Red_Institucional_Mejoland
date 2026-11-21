#!/usr/bin/env python3
"""
SENSOR CENTINELA - Centro Educativo Mejoland
Corre cada minuto en cada servidor (temporizador systemd). Cuenta, por IP de origen, lo que paso
en el ultimo minuto y lo envia a Centinela (TUF) para que el ML lo clasifique.
Solo envia NUMEROS (nunca texto de los registros): asi nadie puede enganar al LLM escribiendo en un log.

Datos por IP:  ssh_fallidos, ssh_exitosos (journal de sshd)
               conexiones_web y conexiones_nuevas_s (ss: conexiones a 80/443/3001 y semiabiertas SYN-RECV)
               peticiones_http, errores_http (logs de Apache, lineas nuevas desde la ultima vez)
               pings y conexiones nuevas (tabla nftables propia 'mejoland_sensor', solo cuenta)
               puertos_distintos (cortafuegos ufw: puertos distintos bloqueados)
               descartes_escudo (IP en la lista de bloqueadas del escudo)
Configuracion: /etc/mejoland/centinela.conf  (URL=una o varias separadas por coma, TOKEN=...)
"""
import collections, glob, ipaddress, json, os, re, socket, subprocess, sys, time, urllib.request

CONF = "/etc/mejoland/centinela.conf"
ESTADO = "/var/lib/mejoland-sensor"
VENTANA = 60
WEB = {80, 443, 3001, 8443}


def conf():
    c = {}
    for l in open(CONF):
        if "=" in l and not l.strip().startswith("#"):
            k, v = l.strip().split("=", 1); c[k.strip()] = v.strip().strip('"')
    return c


def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=20).stdout
    except Exception:
        return ""


def ip_valida(x):
    try:
        a = ipaddress.ip_address(x)
        return a.version == 4 and not a.is_loopback and not a.is_unspecified
    except ValueError:
        return False


def main():
    c = conf()
    datos = collections.defaultdict(lambda: collections.Counter())
    puertos = collections.defaultdict(set)

    # SSH (journal del ultimo minuto)
    for l in run(["journalctl", "-q", "--no-pager", "-o", "cat", "--since", f"-{VENTANA}s",
                  "-t", "sshd", "-t", "sshd-session"]).splitlines():
        m = re.search(r"(Failed password|Invalid user|Accepted \w+) .*?from (\d+\.\d+\.\d+\.\d+)", l)
        if m and ip_valida(m.group(2)):
            datos[m.group(2)]["ssh_exitosos" if m.group(1).startswith("Accepted") else "ssh_fallidos"] += 1

    # Conexiones web abiertas y semiabiertas
    for l in run(["ss", "-tnH", "state", "all"]).splitlines():
        p = l.split()
        if len(p) < 5:
            continue
        est, local, remoto = p[0], p[3], p[4]
        try:
            lp = int(local.rsplit(":", 1)[1]); rip = remoto.rsplit(":", 1)[0].strip("[]").replace("::ffff:", "")
        except (ValueError, IndexError):
            continue
        if lp in WEB and ip_valida(rip):
            if est == "ESTAB":
                datos[rip]["conexiones_web"] += 1
            elif est == "SYN-RECV":
                datos[rip]["conexiones_nuevas_s"] += 1

    # Apache: lineas nuevas desde la ultima ejecucion
    os.makedirs(ESTADO, exist_ok=True)
    pos_f = os.path.join(ESTADO, "apache.json")
    try:
        pos = json.load(open(pos_f))
    except Exception:
        pos = {}
    # Todos los registros de acceso de Apache (access.log, mejoland-publico.log del proxy de la DMZ, etc.), no los de errores
    for f in glob.glob("/var/log/apache2/*.log"):
        if "error" in os.path.basename(f):
            continue
        try:
            tam = os.path.getsize(f); ini = pos.get(f, tam)
            if ini > tam: ini = 0
            with open(f, errors="replace") as h:
                h.seek(ini)
                for l in h:
                    # IP del cliente = la que va justo antes de "- usuario [fecha" (sirve para combined y vhost_combined)
                    mi = re.search(r"(?:^|\s)(\d+\.\d+\.\d+\.\d+) \S+ \S+ \[", l)
                    ms = re.search(r'" (\d{3}) ', l)
                    if mi and ms and ip_valida(mi.group(1)):
                        datos[mi.group(1)]["peticiones_http"] += 1
                        if ms.group(1)[0] in "45":
                            datos[mi.group(1)]["errores_http"] += 1
                pos[f] = h.tell()
        except OSError:
            pass
    json.dump(pos, open(pos_f, "w"))

    # Cortafuegos: puertos distintos bloqueados por IP (escaneo)
    for l in run(["journalctl", "-q", "--no-pager", "-k", "-o", "cat", "--since", f"-{VENTANA}s", "--grep", "UFW BLOCK"]).splitlines():
        m = re.search(r"SRC=(\d+\.\d+\.\d+\.\d+).*?DPT=(\d+)", l)
        if m and ip_valida(m.group(1)):
            puertos[m.group(1)].add(m.group(2))
    for ip, s in puertos.items():
        datos[ip]["puertos_distintos"] = len(s)

    # Contadores por IP de la tabla del sensor (pings y conexiones web nuevas del ultimo minuto)
    for conjunto, campo in (("s_ping", "pings"), ("s_nuevas", "_nuevas")):
        try:
            j = json.loads(run(["nft", "-j", "list", "set", "inet", "mejoland_sensor", conjunto]) or "{}")
            for o in j.get("nftables", []):
                for e in (o.get("set") or {}).get("elem", []):
                    el = e.get("elem", {}); ip = el.get("val"); n = (el.get("counter") or {}).get("packets", 0)
                    if isinstance(ip, str) and ip_valida(ip) and n:
                        datos[ip][campo] += int(n)
            run(["nft", "flush", "set", "inet", "mejoland_sensor", conjunto])
        except ValueError:
            pass
    for ip, d in datos.items():
        if d.get("_nuevas"):
            d["conexiones_nuevas_s"] = max(d.get("conexiones_nuevas_s", 0), -(-d["_nuevas"] // VENTANA))
            del d["_nuevas"]

    # Escudo: IP bloqueadas ahora mismo (superaron los limites)
    for ip in set(re.findall(r"(\d+\.\d+\.\d+\.\d+)", run(["nft", "list", "set", "inet", "mejoland_escudo", "bloqueados"]))):
        if ip_valida(ip): datos[ip]["descartes_escudo"] += 1000

    servidor = re.sub(r"[^a-z0-9-]", "", socket.gethostname().split(".")[0].lower())[:30] or "servidor"
    enviados = 0
    urls = [u.strip().rstrip("/") for u in c["URL"].split(",") if u.strip()]
    # La TUF puede estar en Windows o en Fedora: se prueba primero la que respondio la ultima vez
    ult_f = os.path.join(ESTADO, "ultima_url")
    try:
        ult = open(ult_f).read().strip()
        if ult in urls:
            urls.remove(ult); urls.insert(0, ult)
    except OSError:
        pass
    # Se comprueba una sola vez (3 s) que cada direccion acepte conexiones; las apagadas se saltan
    muertas = set()
    for url in urls:
        try:
            hp = url.split("//", 1)[-1].split("/", 1)[0]
            host, _, port = hp.partition(":")
            socket.create_connection((host, int(port or 80)), timeout=3).close()
        except Exception:
            muertas.add(url)
    for ip, d in datos.items():
        ev = {"servidor": servidor, "ip": ip, "ventana_s": VENTANA, **{k: int(v) for k, v in d.items() if not k.startswith("_")}}
        if "puertos_distintos" not in d:
            ev["puertos_distintos"] = 1 if (d["conexiones_web"] or d["ssh_exitosos"] or d["ssh_fallidos"]) else 0
        for url in urls:
            if url in muertas:
                continue
            req = urllib.request.Request(url + "/analizar", json.dumps(ev).encode(),
                                         {"Content-Type": "application/json", "X-Token": c.get("TOKEN", "")})
            try:
                r = json.load(urllib.request.urlopen(req, timeout=45))
                enviados += 1
                if urls[0] != url:
                    urls.remove(url); urls.insert(0, url)
                try:
                    open(ult_f, "w").write(url)
                except OSError:
                    pass
                if r.get("nivel") in ("medio", "alto"):
                    print(f"{ip}: {r.get('tipo')} riesgo={r.get('riesgo')} accion={r.get('accion')} (via {url})")
                break
            except Exception as e:
                muertas.add(url)   # no se vuelve a esperar por ella en esta vuelta
                print(f"No se pudo enviar {ip} a {url}: {e}", file=sys.stderr)
    print(f"{servidor}: {len(datos)} IP con actividad, {enviados} enviadas a Centinela")


if __name__ == "__main__":
    main()
