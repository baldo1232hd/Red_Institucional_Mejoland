# Red Institucional Mejoland

Infraestructura de red y servidores del **Centro Educativo Mejoland**, una institución educativa con red corporativa propia. El proyecto incluye:

- **Red:** VLAN por área, núcleo colapsado con HSRP y OSPF, BGP con tres proveedores emulados, NAT/PAT y DMZ.
- **Servidores Debian 13:** directorio LDAP, base de datos MariaDB, DNS, correo, AAA/RADIUS, monitoreo con Zabbix, GLPI, Nextcloud y la plataforma educativa **EduNova**.
- **Alta disponibilidad:** réplica de MariaDB, LDAP y DNS, con conmutación automática.
- **Seguridad:** cortafuegos en cada servidor y **Centinela**, un detector de ataques con aprendizaje automático y un LLM local.

Este repositorio contiene las configuraciones finales y los scripts para montar el proyecto desde cero.

> **Sin claves.** Ningún archivo contiene claves reales. Los scripts las generan en el servidor (`/root/proyecto/claves*.txt`, permisos 600) o las piden por teclado. Ver [`claves.ejemplo.env`](claves.ejemplo.env).

---

## 1. Arquitectura

```
                 Internet (VyOS en la Vivobook)
                              |
         MikroTik ISP-A (AS 65001) --- R5 ISP-B (AS 65002) --- Casa 2
                |            \              |
                |             R4 ISP-C (AS 65003) --- Casa 1
              Casa 3          |
                     SW-NUBE-A / SW-NUBE-B  (nube emulada)
                          |            |
                 R1 (borde + distribucion) === R3 (borde + distribucion)   AS 65004
                 HSRP, OSPF, DHCP, NAT/PAT, BGP     NAT 192.168.60.10 = 10.1.40.13
                          |            |
                  SWdistri1 ===Po1=== SWdistri2   (capa 2)
                   /   |   \            |   \
             SW-ACC ADMIN / DOCENTES / ESTUDIANTES      servidores (VLAN 40) y DMZ (VLAN 60)
```

| VLAN | Uso | Red |
|---|---|---|
| 10 | Administración | 192.168.10.0/24 |
| 20 | Docentes | 192.168.20.0/24 |
| 30 | Estudiantes (laboratorio y Wi-Fi) | 192.168.30.0/24 |
| 40 | Servidores | 192.168.40.0/24 |
| 50 | Gestión de equipos de red | 192.168.50.0/24 |
| 60 | DMZ (correo y proxy público) | 192.168.60.0/24 |
| 100 | Tránsito OSPF R1–R3 | 172.16.100.0/28 |

### Servidores

| Servidor | Equipo | IP laboratorio | IP Tailscale | Servicios |
|---|---|---|---|---|
| srv-bd | Toshiba Satellite L55-A | 192.168.40.10 | 100.89.203.22 | MariaDB, OpenLDAP, DNS (maestro), CUPS, EduNova, Panel de Secretaría |
| damian (srv-bd-replica) | HP Laptop 14-bs0xx | 192.168.40.13 | 100.93.52.67 | Réplica de MariaDB, LDAP y DNS; EduNova en espera |
| correo | HP Pavilion g4 | 192.168.60.10 (DMZ) | 100.65.119.48 | Postfix, Dovecot, Roundcube, proxy inverso público |
| srv-aaa-1 | Toshiba Satellite L645D | 192.168.40.11 | 100.75.163.23 | FreeRADIUS (AAA de equipos de red y Wi-Fi) |
| srv-aaa-2 | VM en MacBook Pro (UTM) | 192.168.40.12 | 100.74.49.76 | FreeRADIUS de respaldo |
| srv-monitoreo | VM en MacBook Pro (UTM) | 192.168.40.20 | 100.123.222.5 | Zabbix 7.0 LTS |
| srv-apps | VM en MacBook Pro (UTM) | 192.168.40.21 | 100.107.96.3 | GLPI 11, Nextcloud |

- **IP virtual de EduNova:** 192.168.40.100. La toma el servidor activo, srv-bd o damian.
- **Publicación:** NAT estático en R1/R3, 192.168.60.10 ↔ 10.1.40.13. Solo se publican los puertos 80 y 443.
- **Dominios:** `mejoland.edu.ec` es el dominio público y del correo; `proyecto.local` es el dominio interno y la base LDAP `dc=proyecto,dc=local`.

### Modos de red

Los servidores funcionan en dos modos:

- **modo-casa:** cada equipo está en una red doméstica y los servidores se comunican por Tailscale (VPN).
- **modo-lab:** red física del diseño, con IP estáticas en la VLAN 40 y la DMZ.

Cada cambio de modo regenera los nombres, las zonas DNS, los enlaces de EduNova y el proxy. Ver [`02-servidores/modos-casa-laboratorio/LEEME-modos.txt`](02-servidores/modos-casa-laboratorio/LEEME-modos.txt).

---

## 2. Requisitos

**Hardware:** 4 portátiles para srv-bd, damian, correo y srv-aaa-1, y un equipo con al menos 16 GB de RAM para las tres VMs. Recursos de cada VM:

| VM | vCPU | RAM | Disco |
|---|---|---|---|
| srv-aaa-2 | 1 | 1 GiB | 20 GiB |
| srv-monitoreo | 2 | 4 GiB | 45 GiB |
| srv-apps | 2 | 5 GiB | 70 GiB |

**Equipos de red:** 4 routers Cisco ISR con IOS-XE, 2 switches Cisco C1000, 5 switches Catalyst 2960, un MikroTik CCR2004 y 3 routers domésticos.

**Equipo para Centinela:** PC con GPU de 8 GB o más, en Windows o Fedora, con Ollama y Python 3.11 o superior.

**Software:**
- Debian 13 "trixie" en modo consola en todos los servidores.
- Una cuenta de **Tailscale** con todos los servidores unidos a la misma red.
- Git para clonar este repositorio.

---

## 3. Estructura del repositorio

### `01-red/` — Equipos de red

| Archivo | Qué hace |
|---|---|
| `00-LEEME-red.txt` | Arquitectura, orden de aplicación y tabla de cableado |
| `cisco/00-seguridad-ssh-comun.txt` | SSH v2, usuario `admin`, `enable secret` y ACL de gestión para todos los Cisco |
| `cisco/01-SW-NUBE-A.txt`, `02-SW-NUBE-B.txt` | Switches de la nube emulada (troncales hacia ISP-A, R1/R3 y R4/R5) |
| `cisco/03-SWdistri1-L2.txt`, `04-SWdistri2-L2.txt` | Distribución en capa 2: VLAN, troncales, EtherChannel Po1 y puertos de servidores |
| `cisco/05..07-SW-ACC-*.txt` | Switches de acceso de Administración, Docentes y Estudiantes |
| `cisco/08-R4-ISP-C.txt`, `09-R5-ISP-B.txt` | Proveedores emulados (BGP AS 65003 y 65002) y DHCP de las casas |
| `cisco/10-R1-...`, `11-R3-borde-distribucion.txt` | Núcleo colapsado: subinterfaces, HSRP, OSPF, DHCP partido, PAT, NAT estático, BGP AS 65004 |
| `mikrotik/12-MikroTik-ISP-A.rsc` | ISP-A (AS 65001): BGP con R1, R3, R4 y R5; anti-DDoS; DHCP de la Casa 3 |
| `vyos-y-casas/13-VyOS-casas-servidores.txt` | Salida a Internet con VyOS, routers domésticos y conexión de los servidores |
| `vyos-y-casas/CASAS-INTERNET-routers-OPCIONAL.txt` | Opcional: publicar el proxy como 10.1.60.10 y DNS para las casas |
| `14-PRUEBAS-red.txt` | Pruebas de funcionamiento y de caída de equipos |
| `RESPALDO-CONFIGURACION.txt` | Comandos para exportar la configuración de cada equipo |
| `inventario-red.sh` | Inventario de red de un servidor (solo lectura) |
| `topologia/topologia-mejoland.pkt` | Topología en Cisco Packet Tracer |

### `02-servidores/` — Servidores Debian 13

En cada carpeta, los scripts se ejecutan en el orden de su número. Todos se ejecutan como `root`, guardan un respaldo de lo que modifican y muestran una verificación al terminar.

**`srv-bd/`** — servidor central

| Archivo | Qué hace |
|---|---|
| `01-configurar-srv-bd.sh` | MariaDB (datos en `/srv/datos`), OpenLDAP con estructura, usuarios y grupos, DNS bind9, NTP, syslog, CUPS, cortafuegos y bases de cada servicio |
| `02-migrar-cuentas-altas.sh` | Mueve estudiantes y docentes existentes a `ou=Altas` (solo si había cuentas previas) |
| `03-dominio-srvbd.sh` | Dominio de correo `proyecto.local` → `mejoland.edu.ec` en LDAP (parte 1 de 2) |
| `04-dns-mejoland.sh` | Zona DNS `mejoland.edu.ec` |
| `05-replica-bd-srvbd.sh` | Usuarios `repl` y `volcado` (temporal) para crear la réplica de MariaDB en damian |
| `06-dns-secundario-srvbd.sh` | Permite la transferencia de zona y notificaciones hacia damian |
| `07-ha-instalar-srvbd.sh` | Alta disponibilidad: `mejoland-ha` en modo principal y paquete de EduNova para damian |
| `08-ha-auto-srvbd.sh` | Conmutación y regreso automáticos (usuario `ha_sync`, tabla de estado) |
| `09-ha-ajustes-vigilante.sh` | Tolerancia a carga del vigilante; excluye `zabbix` de la réplica |
| `10-ha-exclusiones-devolucion.sh` | Excluye las bases de srv-apps; devuelve el servicio solo sin usuarios activos |
| `11-ha-anuncio-servicio.sh` | Solo el servidor activo anuncia `svc:mejoland` en Tailscale |
| `12-replica-agente-zabbix.sh` | Datos de estado y atraso de la réplica para el agente de Zabbix |
| `13-permisos-mac-srvbd.sh` | Acceso de las VMs de la Mac a sus bases por Tailscale |
| `mejoland-ha-srvbd` | Programa `mejoland-ha` del servidor principal (lo instala el paso 07) |
| `inventario-cambios.sh` | Lista lo instalado o modificado en los últimos días (solo lectura) |

**`edunova/`** — plataforma educativa (se instala en srv-bd)

| Archivo | Qué hace |
|---|---|
| `instalar-edunova.sh` | Instala la plataforma completa: Node.js, servicio `lms`, API de impresión, tablas, usuario de base de datos y `.env` |
| `backend/server.js`, `package.json` | Servidor web y API (Express, LDAP, MariaDB) |
| `frontend/` | Interfaz web (`index.html`, `estilos.css`, logo y fotos) |
| `impresion/main.py` | API de impresión (FastAPI + CUPS), solo en 127.0.0.1:8000 |
| `sql/esquema-lms.sql`, `sql/biblioteca.sql` | Tablas `lms_*` de la plataforma |
| `config/servicios-lab.json`, `servicios-casa.json` | Enlaces del portal para cada modo |

**`panel-secretaria/`** — altas de cuentas (se instala en srv-bd)

| Archivo | Qué hace |
|---|---|
| `instalar-panel.sh` | PHP-FPM con pool propio, alias `/secretaria` en Apache, cuenta LDAP `svc-secretaria` y sus permisos |
| `secretaria_panel.php` | Panel web: altas, claves, directorio, auditoría y ficha de entrega en Word |
| `crear-cuenta-secretaria.sh` | Crea o habilita cuentas del personal de Secretaría (grupo `secretaria`) |

**`damian/`** — respaldo de srv-bd

| Archivo | Dónde se ejecuta | Qué hace |
|---|---|---|
| `00-base-damian.sh` | damian | MariaDB de réplica (server-id 2, solo lectura) y OpenLDAP |
| `01-replica-bd-damian.sh` | damian | Copia consistente de las bases e inicio de la réplica GTID |
| `02-replica-ldap-damian.sh` | damian | Réplica LDAP (syncrepl) de `dc=proyecto,dc=local` |
| `03-dns-secundario-damian.sh` | damian | DNS secundario de `mejoland.edu.ec` |
| `04-respaldo-edunova.sh` | srv-bd | EduNova usa la réplica LDAP si falla la principal |
| `05-respaldo-correo.sh` | correo | Postfix y Dovecot usan la réplica LDAP como respaldo (con prueba) |
| `06-respaldo-radius.sh` | srv-aaa-1 | FreeRADIUS usa la réplica LDAP como respaldo (con prueba) |
| `07-ha-instalar-damian.sh` | damian | EduNova en espera y vigilante con testigos |
| `08-ha-auto-damian.sh` | damian | Conmutación y regreso automáticos |
| `mejoland-ha-damian` | damian | Programa `mejoland-ha` del servidor de respaldo |
| `reparar-replica.sh` | damian | Repara la réplica si se detiene por un usuario inexistente |
| `damian-puerta-casas.sh` | damian | Alternativa: proxy en damian si las casas solo llegan a él |

**`correo/`** — servidor de la DMZ

| Archivo | Qué hace |
|---|---|
| `01-configurar-correo.sh` | Postfix y Dovecot con usuarios LDAP, Roundcube y red del laboratorio |
| `02-dominio-correo.sh` | Buzones y Postfix con `mejoland.edu.ec` (parte 2 de 2) |
| `03-roundcube-bd-local.sh` | Roundcube con base SQLite local (no depende de srv-bd) |
| `04-marca-roundcube.sh` | Imagen institucional de Roundcube |
| `casas-internet.sh` | Opcional: el proxy trata a las casas como Internet |

**`srv-aaa-1/`, `srv-aaa-2/`** — RADIUS

| Archivo | Qué hace |
|---|---|
| `srv-aaa-1/01-configurar-aaa1.sh` | FreeRADIUS con LDAP y SQL: administración de routers y switches (solo `admins-red`) y Wi-Fi EAP-TTLS |
| `srv-aaa-2/01-instalar-srv-aaa-2.sh` | RADIUS de respaldo con la misma configuración que srv-aaa-1 |

**`srv-monitoreo/`** — Zabbix

| Archivo | Dónde se ejecuta | Qué hace |
|---|---|---|
| `01-instalar-srv-monitoreo.sh` | srv-monitoreo | Zabbix 7.0 LTS (servidor, web y agente) |
| `02-agente-zabbix-en-cada-servidor.sh` | cada servidor | Agente activo con autorregistro |
| `03-mover-bd-zabbix.sh` | srv-monitoreo | Base de Zabbix local y respaldo diario de la configuración |
| `04-zabbix-seguridad.py` | srv-monitoreo | Tablero y alertas de seguridad (Centinela, escudo, GPU) |
| `05-replica-alertas.sh` | srv-monitoreo | Alertas de réplica de MariaDB detenida o atrasada |

**`srv-apps/`** — GLPI y Nextcloud

| Archivo | Qué hace |
|---|---|
| `01-instalar-srv-apps.sh` | GLPI 11 y Nextcloud con Apache, PHP 8.4 y acceso LDAP |
| `02-integrar-apps.sh` | Registros DNS y enlaces del portal (se ejecuta en srv-bd y damian) |
| `03-acelerar-apps.sh` | OPcache, APCu y Redis |
| `04-mover-bd-apps.sh` | Bases de GLPI y Nextcloud locales con respaldo nocturno |
| `05-respaldos-persistentes.sh` | Respaldos con temporizadores de systemd (se ejecutan aunque el equipo estuviera apagado) |

**`comun/`** — en los 7 servidores

| Archivo | Qué hace |
|---|---|
| `blindar.sh` | Protección del núcleo (SYN, ping, suplantación), ufw, escudo anti-DDoS (nftables), fail2ban, SSH, Apache y Postfix |
| `cerrar-puertos.sh` | Cada puerto interno acepta solo a quien lo necesita; oculta versiones |
| `instalar-sensor.sh`, `sensor-centinela.py` | Sensor que envía cada minuto a Centinela la actividad por IP |
| `inventario-claves.sh` | Lista dónde hay claves configuradas (sin mostrarlas) |
| `cambiar-claves.sh` | Cambia a la vez la clave de los servicios y de sus archivos |

**`modos-casa-laboratorio/`** y raíz de `02-servidores/`

| Archivo | Qué hace |
|---|---|
| `preparar-lab.sh` | Prepara cada servidor para el laboratorio sin cortar el acceso remoto |
| `corregir-modos.sh` | Instala `modo-lab`, `modo-casa`, `modo-actualizar`, `modo-red` y `verificar-lab` |
| `verificar-lab.sh` | Revisión completa del laboratorio |
| `LEEME-modos.txt` | Uso de los modos y puesta en marcha en el laboratorio |
| `recolectar-configuracion.sh` | Reúne la configuración activa de un servidor, sin claves |

### `03-seguridad-centinela/` — Detección de ataques

| Archivo | Qué hace |
|---|---|
| `centinela.py` | API (puerto 8800): IsolationForest (anomalías) + RandomForest (tipo de ataque) + reglas fijas; un LLM local explica cada incidente |
| `Modelfile` | Modelo `mejoland-analista` (basado en `qwen3:8b`) con el contexto de la red |
| `centinela-etiquetados.jsonl` | Ejemplos reales etiquetados para el entrenamiento |
| `iniciar-centinela.bat` | Inicio en Windows |
| `instalar-centinela-fedora.sh` | Instalación completa en Fedora: Ollama, modelo, API, servicio y cortafuegos |
| `simular.py`, `centinela-probar.py` | Envían ataques simulados y muestran la clasificación |
| `crear-analista*.json` | Definición del modelo para la API de Ollama |
| `LEEME-ENTRENAR.txt` | Cómo crear el modelo y reentrenar el ML con tráfico real |

### `04-pruebas/`

| Archivo | Qué hace |
|---|---|
| `esfuerzo/crear-datos-prueba.sh` | 250 cuentas y 50 cursos de prueba, separados de los reales |
| `esfuerzo/carga-edunova.js`, `ejecutar-prueba.bat` | Prueba de carga con k6 (hasta 200 estudiantes simultáneos) |
| `esfuerzo/borrar-datos-prueba.sh` | Elimina todos los datos de prueba |
| `esfuerzo/informe-*usuarios.html` | Resultados con 50, 100 y 200 usuarios |
| `seguridad/escaneo-puertos-*.txt` | Escaneo Nmap de los servicios publicados |

---

## 4. Montaje paso a paso

Convenciones:
- Todo se ejecuta como `root` (`sudo -i`).
- En cada servidor, clonar el repositorio (`git clone <URL>`) o copiar la carpeta por `scp`, y ejecutar los scripts desde su carpeta.
- Cuando un script indica `Antes: copiar a /tmp ...`, se copian esos archivos a `/tmp` antes de ejecutarlo.

### Fase 0 — Preparación de los servidores
1. Instalar Debian 13 (netinst, sin entorno gráfico, con servidor SSH) en los 4 portátiles y en las 3 VMs.
2. Asignar el nombre de cada equipo (`hostnamectl set-hostname srv-bd`, etc.).
3. Instalar Tailscale en todos y unirlos a la misma red: `curl -fsSL https://tailscale.com/install.sh | sh && tailscale up`.
4. Ajustar las IP de Tailscale de la tabla de servidores si las de tu red son distintas. Están al inicio de los scripts y en `corregir-modos.sh`.

### Fase 1 — Red
Seguir [`01-red/00-LEEME-red.txt`](01-red/00-LEEME-red.txt):
1. Cablear.
2. Borrar la configuración de los equipos.
3. Aplicar `00-seguridad-ssh-comun.txt` y los archivos 01 a 11.
4. Aplicar el MikroTik (12) y VyOS con las casas (13).
5. Verificar con `14-PRUEBAS-red.txt`.

### Fase 2 — srv-bd (servidor central)
```bash
cd 02-servidores/srv-bd
bash 01-configurar-srv-bd.sh        # pide las claves de LDAP; genera las de las bases en /root/proyecto/claves.txt
bash 03-dominio-srvbd.sh            # dominio de correo mejoland.edu.ec (luego ejecutar la parte 2 en correo)
bash 04-dns-mejoland.sh
cd ../edunova && bash instalar-edunova.sh
cd ../panel-secretaria && bash instalar-panel.sh && bash crear-cuenta-secretaria.sh
```
`02-migrar-cuentas-altas.sh` solo es necesario si ya existían cuentas antes del panel.

### Fase 3 — correo y RADIUS
```bash
# en correo
cd 02-servidores/correo
bash 01-configurar-correo.sh
bash 02-dominio-correo.sh
bash 03-roundcube-bd-local.sh
cp ../edunova/frontend/logo.jpg /tmp/ && cp ../edunova/frontend/img/biblioteca.jpg /tmp/ && bash 04-marca-roundcube.sh

# en srv-aaa-1
cd 02-servidores/srv-aaa-1 && bash 01-configurar-aaa1.sh
```
El secreto RADIUS que pide el script es el mismo que se configura en los clientes RADIUS (puntos de acceso Wi-Fi y equipos de red que autentiquen contra srv-aaa-1).

### Fase 4 — damian y alta disponibilidad
Ejecutar en el orden indicado. La columna "Equipo" dice dónde va cada paso.

| # | Equipo | Comando |
|---|---|---|
| 1 | damian | `bash damian/00-base-damian.sh` |
| 2 | srv-bd | `bash srv-bd/05-replica-bd-srvbd.sh` (muestra una clave temporal) |
| 3 | damian | `bash damian/01-replica-bd-damian.sh CLAVE_TEMPORAL` |
| 4 | srv-bd | `bash srv-bd/05-replica-bd-srvbd.sh --limpiar` |
| 5 | damian | `bash damian/02-replica-ldap-damian.sh` |
| 6 | srv-bd → damian | `bash srv-bd/06-dns-secundario-srvbd.sh` y luego `bash damian/03-dns-secundario-damian.sh` |
| 7 | srv-bd / correo / srv-aaa-1 | `damian/04-respaldo-edunova.sh`, `05-respaldo-correo.sh` y `06-respaldo-radius.sh`, cada uno en su equipo |
| 8 | srv-bd | Copiar `srv-bd/mejoland-ha-srvbd` y `damian/mejoland-ha-damian` a `/tmp` y ejecutar `bash srv-bd/07-ha-instalar-srvbd.sh` |
| 9 | damian | Copiar `/tmp/ha-paquete.tgz` de srv-bd y ejecutar `bash damian/07-ha-instalar-damian.sh` |
| 10 | srv-bd → damian | `bash srv-bd/08-ha-auto-srvbd.sh` y luego `bash damian/08-ha-auto-damian.sh CLAVE` |
| 11 | srv-bd y damian | `09-ha-ajustes-vigilante.sh`, `10-ha-exclusiones-devolucion.sh` y `11-ha-anuncio-servicio.sh`, en los dos |

Comprobar con `mejoland-ha estado` en ambos servidores.

### Fase 5 — Máquinas virtuales de la Mac
1. En srv-bd: `bash srv-bd/13-permisos-mac-srvbd.sh`.
2. srv-aaa-2: en srv-aaa-1 crear la copia con `tar czf /tmp/radius-conf.tgz -C /etc freeradius`, pasarla a `/tmp` de srv-aaa-2 y ejecutar `bash srv-aaa-2/01-instalar-srv-aaa-2.sh`.
3. srv-monitoreo: ejecutar `01-instalar-srv-monitoreo.sh` y `03-mover-bd-zabbix.sh`.
4. En cada servidor: `bash srv-monitoreo/02-agente-zabbix-en-cada-servidor.sh`.
5. En srv-bd y damian: `bash srv-bd/12-replica-agente-zabbix.sh`. Luego, en srv-monitoreo: `bash srv-monitoreo/05-replica-alertas.sh`.
6. srv-apps: ejecutar `01-instalar-srv-apps.sh`, luego `02-integrar-apps.sh` (en srv-bd y en damian), y después `03`, `04` y `05`.

### Fase 6 — Seguridad
1. En los 7 servidores: `bash comun/blindar.sh` y luego `bash comun/cerrar-puertos.sh`.
2. Centinela en el equipo con GPU:
   - **Fedora:** `sudo bash 03-seguridad-centinela/instalar-centinela-fedora.sh`.
   - **Windows:** seguir `LEEME-ENTRENAR.txt` y usar `iniciar-centinela.bat`.
3. En cada servidor: copiar `comun/sensor-centinela.py` a `/tmp` y ejecutar `bash comun/instalar-sensor.sh`.
4. En srv-monitoreo: `python3 srv-monitoreo/04-zabbix-seguridad.py`.

### Fase 7 — Modos y puesta en marcha en el laboratorio
1. En los 7 servidores: copiar `preparar-lab.sh`, `corregir-modos.sh` y `verificar-lab.sh` a `/tmp` y ejecutar `bash /tmp/preparar-lab.sh`.
2. En el laboratorio, desde la consola de cada servidor y en este orden: `modo-lab` en srv-bd, damian, correo y srv-aaa-1.
3. Ejecutar `verificar-lab` en cualquier servidor.
4. Acceso:
   - **Red interna:** `https://mejoland.edu.ec/plataforma/`
   - **Desde Internet o las casas:** `https://10.1.40.13/plataforma/`

### Fase 8 — Pruebas
1. **Red:** `01-red/14-PRUEBAS-red.txt`.
2. **Carga:** `bash 04-pruebas/esfuerzo/crear-datos-prueba.sh` en srv-bd, luego `ejecutar-prueba.bat` en una PC con k6, y al terminar `borrar-datos-prueba.sh`.
3. **Seguridad:** escaneo Nmap desde la VLAN de estudiantes y desde una casa; `simular.py` contra Centinela.

---

## 5. Componentes configurados manualmente

Estos componentes no tienen script propio:
- **LAM (LDAP Account Manager)** en srv-bd: `apt install ldap-account-manager` y configurar el servidor `ldap://127.0.0.1`, la base `dc=proyecto,dc=local` y el administrador `cn=admin,dc=proyecto,dc=local`.
- **Certificados:** el proxy público usa un certificado autofirmado; para producción, reemplazarlo por uno emitido por una autoridad.
- **Impresoras:** se agregan desde EduNova (Administración → Impresoras) o con CUPS en srv-bd.

## 6. Reglas para contribuir

- Antes de trabajar: `git pull`.
- Antes de cada commit: `git status`, y revisar que no se suba ninguna clave, token ni respaldo. El `.gitignore` los bloquea, pero hay que revisarlo igual.
- Si una clave se sube por error, cambiarla en el servidor. Borrarla del repositorio no basta, porque queda en el historial.
- Los `.sh` y `.py` se guardan con fin de línea LF (`.gitattributes`).
- Los comentarios describen qué hace cada parte, no su historial. Los cambios se explican en el mensaje del commit.
