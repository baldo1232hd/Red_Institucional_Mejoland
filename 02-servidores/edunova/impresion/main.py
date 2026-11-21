"""
API de impresion - Centro Educativo Mejoland
Servicio interno (solo 127.0.0.1:8000) que EduNova usa para imprimir mediante CUPS.
Autenticacion HTTP Basic; usuario y clave en /etc/print-api/credenciales.env (EnvironmentFile).

Rutas:
  GET    /impresoras             impresoras configuradas y su estado (sin exponer direcciones internas)
  GET    /control                estado, niveles y cola de una impresora (?impresora=NOMBRE;
                                 por defecto PRINT_API_IMPRESORA)
  POST   /imprimir               recibe un PDF/JPG/PNG (cuerpo binario), cuenta sus paginas, valida el
                                 rango y el cupo indicados por EduNova e imprime a nombre del usuario
  POST   /cancelar/{id}          cancela un trabajo
  GET    /descubrir              impresoras encontradas en la red y por USB (CUPS-Get-Devices)
  POST   /impresoras             crea una cola (IPP Everywhere / driverless o controlador por modelo)
  PATCH  /impresoras/{nombre}    cambia descripcion y ubicacion
  DELETE /impresoras/{nombre}    quita una cola

Seguridad: /docs, /redoc y /openapi.json desactivados; conexion a CUPS nueva en cada peticion;
errores internos solo en el registro del sistema; pausa de 1 s en cada autenticacion fallida.
Se ejecuta con un usuario sin privilegios (grupo lpadmin).
"""
import logging
import os
import re
import subprocess
import tempfile
import threading
import secrets
import time

import cups
from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.responses import FileResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials

log = logging.getLogger("print-api")
logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

USUARIO_ADMIN = os.environ.get("PRINT_API_USER", "")
PASSWORD_ADMIN = os.environ.get("PRINT_API_PASSWORD", "")
IMPRESORA_DEFECTO = os.environ.get("PRINT_API_IMPRESORA", "impresora-principal")
if not USUARIO_ADMIN or len(PASSWORD_ADMIN) < 8:
    raise SystemExit("Faltan PRINT_API_USER / PRINT_API_PASSWORD (min. 8) en /etc/print-api/credenciales.env")

BASE = os.path.dirname(os.path.abspath(__file__))
app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
security = HTTPBasic()

def validar_admin(request: Request, credentials: HTTPBasicCredentials = Depends(security)):
    ok_u = secrets.compare_digest(credentials.username.encode(), USUARIO_ADMIN.encode())
    ok_p = secrets.compare_digest(credentials.password.encode(), PASSWORD_ADMIN.encode())
    if not (ok_u and ok_p):
        # Pausa de 1 s por intento fallido: frena la fuerza bruta sin bloquear a EduNova
        # (que usa la misma IP 127.0.0.1 con la clave correcta).
        log.warning("Inicio de sesion fallido desde %s", request.client.host if request.client else "?")
        time.sleep(1.0)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Acceso denegado",
            headers={"WWW-Authenticate": "Basic"},
        )
    return credentials.username


def cx() -> cups.Connection:
    try:
        return cups.Connection()
    except Exception as e:  # cupsd caido
        log.error("No hay conexion con CUPS: %s", e)
        raise HTTPException(status_code=503, detail="El servicio de impresion no esta disponible.")


OCULTOS = {"device-uri"}
EXTRA = ["printer-state-reasons", "queued-job-count", "marker-names", "marker-levels", "marker-colors", "marker-types", "marker-low-levels"]


@app.get("/", response_class=FileResponse)
def cargar_panel(username: str = Depends(validar_admin)):
    return FileResponse(os.path.join(BASE, "index.html"))


@app.get("/impresoras")
def estado_impresoras(username: str = Depends(validar_admin)):
    try:
        printers = cx().getPrinters()
    except HTTPException:
        raise
    except Exception as e:
        log.error("getPrinters: %s", e)
        raise HTTPException(status_code=502, detail="No se pudo consultar el estado de las impresoras.")
    limpio = {n: {k: v for k, v in a.items() if k not in OCULTOS} for n, a in printers.items()}
    # Niveles de tinta, avisos (sin papel, atasco...) y trabajos en cola, si la impresora los reporta.
    try:
        c = cx()
        for n in limpio:
            try:
                extra = c.getPrinterAttributes(n, requested_attributes=EXTRA)
                limpio[n].update({k: extra[k] for k in EXTRA if k in extra})
            except Exception:
                pass
    except HTTPException:
        pass
    return {"impresoras": limpio}


ACCIONES = {"reanudar", "pausar", "limpiar"}


@app.post("/control/{accion}")
def controlar_impresora(accion: str, impresora: str | None = None, username: str = Depends(validar_admin)):
    if accion not in ACCIONES:
        raise HTTPException(status_code=400, detail="Accion no reconocida")
    c = cx()
    nombre = impresora or IMPRESORA_DEFECTO
    try:
        existentes = c.getPrinters()
    except Exception as e:
        log.error("getPrinters: %s", e)
        raise HTTPException(status_code=502, detail="No se pudo consultar CUPS.")
    if nombre not in existentes:
        raise HTTPException(status_code=404, detail="Impresora no encontrada")
    try:
        if accion == "reanudar":
            c.enablePrinter(nombre)
            c.acceptJobs(nombre)
            msg = f"{nombre} reanudada exitosamente"
        elif accion == "pausar":
            c.disablePrinter(nombre)
            msg = f"{nombre} pausada"
        else:
            c.cancelAllJobs(nombre)
            msg = f"Trabajos de {nombre} cancelados"
    except cups.IPPError as e:
        log.error("CUPS %s %s: %s", accion, nombre, e)
        raise HTTPException(status_code=502, detail="CUPS rechazo la accion. Revisa los permisos del servicio.")
    except Exception as e:
        log.error("CUPS %s %s: %s", accion, nombre, e)
        raise HTTPException(status_code=502, detail="No se pudo completar la accion en CUPS.")
    log.info("%s: %s (%s)", username, msg, accion)
    return {"mensaje": msg}


ESTADOS = {3: "Pendiente", 4: "Retenido", 5: "Procesando", 6: "Detenido", 7: "Cancelado", 8: "Abortado", 9: "Completado"}


@app.get("/trabajos")
def historial_trabajos(username: str = Depends(validar_admin)):
    try:
        jobs = cx().getJobs(which_jobs="all", requested_attributes=[
            "job-id", "job-printer-uri", "job-originating-host-name", "job-originating-user-name",
            "job-name", "job-k-octets", "job-media-sheets-completed", "job-state", "time-at-creation",
        ])
    except HTTPException:
        raise
    except Exception as e:
        log.error("getJobs: %s", e)
        raise HTTPException(status_code=502, detail="No se pudo consultar el historial.")
    historial = [{
        "id": jid,
        "impresora": str(job.get("job-printer-uri", "")).split("/")[-1],
        "ip": job.get("job-originating-host-name", "Desconocida"),
        "usuario": job.get("job-originating-user-name", ""),
        "documento": job.get("job-name", ""),
        "tamano_kb": job.get("job-k-octets", 0),
        "paginas": job.get("job-media-sheets-completed", 0),
        "estado": ESTADOS.get(job.get("job-state", 0), "Desconocido"),
        "fecha": job.get("time-at-creation", 0),
    } for jid, job in jobs.items()]
    historial.sort(key=lambda x: x["id"], reverse=True)
    return {"trabajos": historial[:300]}


# ======================= Envio de trabajos =======================
MAX_BYTES = 10 * 1024 * 1024
TIPOS = {"application/pdf": ".pdf", "image/jpeg": ".jpg", "image/png": ".png"}
FIRMAS = {".pdf": b"%PDF-", ".jpg": b"\xff\xd8\xff", ".png": b"\x89PNG\r\n\x1a\n"}
_lock_usuario = threading.Lock()   # cups.setUser es global al proceso


def contar_paginas(ruta: str, ext: str) -> int:
    if ext != ".pdf":
        return 1
    try:
        out = subprocess.run(["pdfinfo", ruta], capture_output=True, text=True, timeout=20, check=True).stdout
    except Exception as e:
        log.warning("pdfinfo: %s", e)
        raise HTTPException(status_code=400, detail="El PDF está dañado o protegido con contraseña.")
    m = re.search(r"^Pages:\s+(\d+)", out, re.M)
    if not m or int(m.group(1)) < 1:
        raise HTTPException(status_code=400, detail="No se pudo leer el número de páginas del PDF.")
    return int(m.group(1))


def paginas_de_rango(rango: str, total: int) -> int:
    """'1-3,5' -> 4 paginas. Vacio = todas."""
    if not rango:
        return total
    if not re.fullmatch(r"\d{1,4}(-\d{1,4})?(,\d{1,4}(-\d{1,4})?){0,19}", rango):
        raise HTTPException(status_code=400, detail="Rango de páginas no válido (ejemplo: 1-3,5).")
    elegidas = set()
    for parte in rango.split(","):
        a, _, b = parte.partition("-")
        ini, fin = int(a), int(b or a)
        if ini < 1 or fin < ini or fin > total:
            raise HTTPException(status_code=400, detail=f"El documento tiene {total} página(s); revisa el rango.")
        elegidas.update(range(ini, fin + 1))
    return len(elegidas)


@app.post("/imprimir")
async def imprimir(request: Request, usuario: str, titulo: str = "documento", copias: int = 1,
                   paginas: str = "", color: bool = False, max_paginas: int = -1,
                   impresora: str | None = None, username: str = Depends(validar_admin)):
    if not re.fullmatch(r"[a-z0-9._-]{1,64}", usuario):
        raise HTTPException(status_code=400, detail="Usuario no válido.")
    if not 1 <= copias <= 20:
        raise HTTPException(status_code=400, detail="Copias: de 1 a 20.")
    ext = TIPOS.get(request.headers.get("content-type", "").split(";")[0].strip().lower())
    if not ext:
        raise HTTPException(status_code=415, detail="Solo se aceptan PDF, JPG o PNG.")
    datos = await request.body()
    if not datos or len(datos) > MAX_BYTES:
        raise HTTPException(status_code=413, detail="El archivo está vacío o supera 10 MB.")
    if not datos.startswith(FIRMAS[ext]):
        raise HTTPException(status_code=415, detail="El contenido no corresponde al tipo de archivo.")
    titulo = re.sub(r"[^\w .,()\-]", "_", titulo, flags=re.UNICODE)[:100] or "documento"
    nombre = impresora or IMPRESORA_DEFECTO
    with tempfile.NamedTemporaryFile(suffix=ext, delete=True) as tmp:
        tmp.write(datos); tmp.flush()
        total = contar_paginas(tmp.name, ext)
        cobradas = paginas_de_rango(paginas.replace(" ", ""), total) * copias
        if max_paginas >= 0 and cobradas > max_paginas:
            raise HTTPException(status_code=409, detail=f"Este trabajo usa {cobradas} página(s) y tu cupo disponible es {max_paginas}.")
        opciones = {"copies": str(copias), "print-color-mode": "color" if color else "monochrome"}
        if not color:
            opciones["ColorModel"] = "Gray"
        if paginas:
            opciones["page-ranges"] = paginas.replace(" ", "")
        if ext != ".pdf":
            opciones["fit-to-page"] = "true"
        try:
            with _lock_usuario:
                cups.setUser(usuario)
                try:
                    c = cups.Connection()
                    if nombre not in c.getPrinters():
                        raise HTTPException(status_code=404, detail="Impresora no encontrada")
                    job = c.printFile(nombre, tmp.name, titulo, opciones)
                finally:
                    cups.setUser("printapi")
        except HTTPException:
            raise
        except cups.IPPError as e:
            log.error("printFile %s: %s", nombre, e)
            raise HTTPException(status_code=502, detail="La impresora rechazó el trabajo (puede estar pausada).")
        except Exception as e:
            log.error("printFile %s: %s", nombre, e)
            raise HTTPException(status_code=503, detail="El servicio de impresion no esta disponible.")
    log.info("%s envio trabajo %s a %s: %s pag (%s doc x %s copias) %s", usuario, job, nombre, cobradas, total, copias, "color" if color else "b/n")
    return {"trabajo": job, "impresora": nombre, "paginas": cobradas, "paginas_documento": total}


@app.post("/cancelar/{trabajo}")
def cancelar(trabajo: int, username: str = Depends(validar_admin)):
    try:
        cx().cancelJob(trabajo)
    except HTTPException:
        raise
    except cups.IPPError as e:
        log.error("cancelJob %s: %s", trabajo, e)
        raise HTTPException(status_code=409, detail="El trabajo ya terminó o no existe.")
    return {"mensaje": f"Trabajo {trabajo} cancelado"}


# ======================= Alta y baja de impresoras =======================
from pydantic import BaseModel, Field

NOMBRE_RE = re.compile(r"^[A-Za-z0-9_-]{2,40}$")
URI_RE = re.compile(r"^(ipp|ipps|dnssd|usb|socket|lpd|http|https)://[^\s\"'<>`$;|&]{1,250}$")
ESQUEMAS = ["dnssd", "ipp", "ipps", "usb", "socket", "lpd"]


@app.get("/descubrir")
def descubrir(username: str = Depends(validar_admin)):
    try:
        devs = cx().getDevices(timeout=8, include_schemes=ESQUEMAS)
    except HTTPException:
        raise
    except Exception as e:
        log.error("getDevices: %s", e)
        raise HTTPException(status_code=502, detail="No se pudo buscar impresoras.")
    out = []
    for uri, d in devs.items():
        if "://" not in uri or not URI_RE.match(uri):
            continue  # entradas genericas como "socket" o "ipp" sin direccion
        out.append({
            "uri": uri,
            "tipo": d.get("device-class", ""),
            "nombre": d.get("device-info", "") or d.get("device-make-and-model", ""),
            "modelo": d.get("device-make-and-model", ""),
            "ubicacion": d.get("device-location", ""),
        })
    out.sort(key=lambda x: (not x["uri"].startswith(("dnssd", "ipp")), x["nombre"]))
    return {"dispositivos": out[:60]}


class NuevaImpresora(BaseModel):
    nombre: str = Field(min_length=2, max_length=40)
    uri: str = Field(min_length=6, max_length=260)
    descripcion: str = Field(default="", max_length=120)
    ubicacion: str = Field(default="", max_length=120)
    modelo: str = Field(default="", max_length=200)


def _buscar_ppd(c: cups.Connection, modelo: str) -> str | None:
    if not modelo:
        return None
    try:
        ppds = c.getPPDs2(ppd_make_and_model=modelo, limit=5)
        if ppds:
            return next(iter(ppds))
        marca = modelo.split()[0]
        cand = c.getPPDs2(ppd_make=marca, limit=400)
        clave = modelo.lower().replace(" series", "")
        for n, a in cand.items():
            mm = str(a.get("ppd-make-and-model", "")).lower()
            if clave and clave in mm:
                return n
    except Exception as e:
        log.warning("getPPDs: %s", e)
    return None


@app.post("/impresoras")
def agregar_impresora(datos: NuevaImpresora, username: str = Depends(validar_admin)):
    if not NOMBRE_RE.match(datos.nombre):
        raise HTTPException(status_code=400, detail="Nombre: solo letras, números, guion y guion bajo (2 a 40), sin espacios.")
    if not URI_RE.match(datos.uri):
        raise HTTPException(status_code=400, detail="Dirección de impresora no válida.")
    c = cx()
    if datos.nombre in c.getPrinters():
        raise HTTPException(status_code=409, detail="Ya existe una impresora con ese nombre.")
    info = datos.descripcion or datos.nombre
    intento = None

    def limpiar():
        # Si CUPS dejo una cola a medio crear, se borra para no dejar basura.
        try:
            if datos.nombre in c.getPrinters():
                c.deletePrinter(datos.nombre)
        except Exception:
            pass

    try:
        if not datos.uri.startswith(("usb:", "socket:", "lpd:")):
            # IPP Everywhere / AirPrint: CUPS genera el controlador preguntandole a la impresora.
            try:
                c.addPrinter(datos.nombre, ppdname="everywhere", info=info, location=datos.ubicacion, device=datos.uri)
                intento = "everywhere"
            except cups.IPPError as e:
                log.warning("everywhere fallo para %s: %s", datos.uri, e)
                limpiar()
        if not intento:
            ppd = _buscar_ppd(c, datos.modelo)
            if not ppd:
                raise HTTPException(status_code=422, detail="La impresora no respondió como IPP Everywhere y no se encontró un controlador para su modelo. Revisa que esté encendida y en la red, o agrégala desde la página de CUPS (puerto 631).")
            c.addPrinter(datos.nombre, ppdname=ppd, info=info, location=datos.ubicacion, device=datos.uri)
            intento = ppd
        c.enablePrinter(datos.nombre)
        c.acceptJobs(datos.nombre)
        c.setPrinterShared(datos.nombre, True)
    except HTTPException:
        raise
    except cups.IPPError as e:
        log.error("addPrinter %s %s: %s", datos.nombre, datos.uri, e)
        limpiar()
        raise HTTPException(status_code=502, detail="CUPS no pudo crear la impresora. Revisa que esté encendida y en la misma red.")
    log.info("%s agrego %s (%s) con %s", username, datos.nombre, datos.uri, intento)
    return {"mensaje": f"Impresora {datos.nombre} agregada", "controlador": "IPP Everywhere" if intento == "everywhere" else intento}


class CambioImpresora(BaseModel):
    descripcion: str | None = Field(default=None, max_length=120)
    ubicacion: str | None = Field(default=None, max_length=120)


@app.patch("/impresoras/{nombre}")
def editar_impresora(nombre: str, datos: CambioImpresora, username: str = Depends(validar_admin)):
    c = cx()
    if nombre not in c.getPrinters():
        raise HTTPException(status_code=404, detail="Impresora no encontrada")
    try:
        if datos.descripcion is not None:
            c.setPrinterInfo(nombre, datos.descripcion)
        if datos.ubicacion is not None:
            c.setPrinterLocation(nombre, datos.ubicacion)
    except cups.IPPError as e:
        log.error("editar %s: %s", nombre, e)
        raise HTTPException(status_code=502, detail="CUPS no pudo guardar los cambios.")
    return {"mensaje": "Cambios guardados"}


@app.delete("/impresoras/{nombre}")
def quitar_impresora(nombre: str, username: str = Depends(validar_admin)):
    c = cx()
    if nombre not in c.getPrinters():
        raise HTTPException(status_code=404, detail="Impresora no encontrada")
    try:
        c.deletePrinter(nombre)
    except cups.IPPError as e:
        log.error("deletePrinter %s: %s", nombre, e)
        raise HTTPException(status_code=502, detail="CUPS no pudo quitar la impresora.")
    log.info("%s quito la impresora %s", username, nombre)
    return {"mensaje": f"Impresora {nombre} quitada"}
