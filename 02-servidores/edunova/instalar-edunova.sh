#!/bin/bash
# =====================================================================
#  INSTALAR EDUNOVA - Centro Educativo Mejoland   (SRV-BD, root)
#  Instala la plataforma educativa EduNova desde cero:
#   - Servidor web y API en Node.js   /var/www/lms-backend   (servicio lms, puerto 3001)
#   - Interfaz web                    /var/www/lms-frontend
#   - Tablas lms_* en la base institucion (MariaDB) y usuario de base de datos lms
#   - API de impresion (FastAPI + CUPS) /opt/print-api, solo en 127.0.0.1:8000 (servicio print-api)
#   - Enlaces del portal              /etc/edunova/servicios.json
#  Requisitos: 01-configurar-srv-bd.sh ejecutado (MariaDB, OpenLDAP, CUPS y cuenta cn=lector).
#  Uso (desde esta carpeta):  bash instalar-edunova.sh
#  Se puede volver a ejecutar: conserva las claves ya generadas y actualiza los archivos.
#  En damian la plataforma se copia con el paquete de alta disponibilidad (srv-bd/07-ha-instalar-srvbd.sh).
# =====================================================================
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
D=$(cd "$(dirname "$0")" && pwd)
B=/var/www/lms-backend; F=/var/www/lms-frontend; C=/etc/edunova; P=/opt/print-api
E=$B/.env; CRED=/etc/print-api/credenciales.env; DBN=institucion
BASE_DN=dc=proyecto,dc=local
paso() { echo; echo "=================== $* ==================="; }
for f in backend/server.js backend/package.json frontend/index.html frontend/estilos.css frontend/logo.jpg \
         impresion/main.py sql/esquema-lms.sql sql/biblioteca.sql config/servicios-casa.json; do
  [ -f "$D/$f" ] || { echo "Falta $D/$f"; exit 1; }
done
# Valor de una variable en un archivo clave=valor (vacio si no existe)
val() { [ -f "$2" ] && sed -n "s/^$1=//p" "$2" | head -1 | sed "s/^'\(.*\)'\$/\1/" || true; }

paso "1 Paquetes"
apt-get update -q
apt-get install -y -q nodejs npm python3-venv python3-dev gcc libcups2-dev cups \
  poppler-utils ldap-utils curl openssl >/dev/null
node --version

paso "2 Usuarios de servicio (sin privilegios)"
id lms >/dev/null 2>&1 || useradd --system --home-dir $B --no-create-home --shell /usr/sbin/nologin lms
id printapi >/dev/null 2>&1 || useradd --system --home-dir $P --no-create-home --shell /usr/sbin/nologin printapi
usermod -aG lpadmin printapi
echo "  lms y printapi listos"

paso "3 Base de datos"
# Los documentos de la biblioteca y de la impresion en espera se guardan en la base (hasta ~20 MB)
cat > /etc/mysql/mariadb.conf.d/61-mejoland-paquetes.cnf <<'CNF'
# EduNova: documentos guardados en la base (impresion en espera y biblioteca)
[mysqld]
max_allowed_packet = 64M
[client]
max_allowed_packet = 64M
[mysqldump]
max_allowed_packet = 64M
CNF
mysql -e "SET GLOBAL max_allowed_packet=67108864"
mysql -e "CREATE DATABASE IF NOT EXISTS \`$DBN\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci"
mysql "$DBN" < "$D/sql/esquema-lms.sql"
mysql "$DBN" < "$D/sql/biblioteca.sql"
DBP=$(val DB_PASSWORD "$E"); [ -n "$DBP" ] || DBP=$(openssl rand -hex 16)
for H in localhost 127.0.0.1; do
  mysql -e "CREATE USER IF NOT EXISTS 'lms'@'$H' IDENTIFIED BY '$DBP';
            ALTER USER 'lms'@'$H' IDENTIFIED BY '$DBP';
            GRANT SELECT, INSERT, UPDATE, DELETE ON \`$DBN\`.* TO 'lms'@'$H';"
done
echo "  Base $DBN y usuario lms: OK"

paso "4 Cuenta de lectura LDAP (cn=lector)"
LP=$(val LDAP_BIND_PASSWORD "$E")
if [ -z "$LP" ]; then
  read -rsp "  Clave de cn=lector,$BASE_DN: " LP </dev/tty; echo
fi
ldapwhoami -x -H ldap://127.0.0.1 -D "cn=lector,$BASE_DN" -w "$LP" >/dev/null \
  || { echo "  La clave de cn=lector no es valida"; exit 1; }
echo "  LDAP: OK"

paso "5 API de impresion"
mkdir -p /etc/print-api; chown root:printapi /etc/print-api; chmod 750 /etc/print-api
if [ ! -f "$CRED" ]; then
  read -rp "  Nombre de la impresora en CUPS (lpstat -p; Enter = ninguna por ahora): " IMP </dev/tty
  printf "PRINT_API_USER='edunova'\nPRINT_API_PASSWORD='%s'\nPRINT_API_IMPRESORA='%s'\n" \
    "$(openssl rand -hex 16)" "${IMP:-}" > "$CRED"
fi
chown root:printapi "$CRED"; chmod 640 "$CRED"
install -d -o root -g printapi -m 750 $P
install -m 640 -o root -g printapi "$D/impresion/main.py" $P/main.py
[ -x $P/venv/bin/python3 ] || python3 -m venv $P/venv
$P/venv/bin/pip install -q --upgrade pip
$P/venv/bin/pip install -q fastapi "uvicorn[standard]" pycups pydantic
chown -R root:printapi $P; chmod -R u+rwX,g+rX,g-w,o-rwx $P
cat > /etc/systemd/system/print-api.service <<UNIT
[Unit]
Description=API de impresion de EduNova (Centro Educativo Mejoland)
After=network.target cups.service
Wants=cups.service

[Service]
User=printapi
Group=printapi
SupplementaryGroups=lpadmin
WorkingDirectory=$P
EnvironmentFile=$CRED
Environment=PYTHONDONTWRITEBYTECODE=1
ExecStart=$P/venv/bin/python3 -m uvicorn main:app --host 127.0.0.1 --port 8000 --no-server-header
Restart=always
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable -q --now print-api; systemctl restart print-api
echo "  print-api en 127.0.0.1:8000"

paso "6 EduNova (servidor y archivos)"
install -d -o root -g lms -m 750 $B
install -d -o root -g lms -m 755 $F $F/img
install -d -o lms -g lms -m 750 /var/lib/edunova /var/lib/edunova/impresiones
install -m 640 -o root -g lms "$D/backend/server.js" "$D/backend/package.json" $B/
install -m 644 -o root -g lms "$D/frontend/index.html" "$D/frontend/estilos.css" "$D/frontend/logo.jpg" $F/
install -m 644 -o root -g lms "$D"/frontend/img/*.jpg $F/img/
(cd $B && npm install --omit=dev --no-audit --no-fund --silent)
chown -R root:lms $B/node_modules; chmod -R g+rX,o-rwx $B/node_modules
install -d -o root -g lms -m 750 $C
[ -f $C/servicios.json ] || install -m 640 -o root -g lms "$D/config/servicios-casa.json" $C/servicios.json

# Configuracion (.env): se regenera conservando las claves existentes
LURL=$( [ -f $E ] && sed -n 's/^LDAP_URL=//p' $E | tr -d "\"'" | tail -1 || true ); LURL=${LURL:-ldap://127.0.0.1:389}
umask 027
cat > $E <<ENV
HOST=0.0.0.0
PORT=3001
FRONTEND_DIR=$F
DB_HOST=127.0.0.1
DB_USER=lms
DB_PASSWORD=$DBP
DB_NAME=$DBN
LDAP_URL="$LURL"
LDAP_BASE_DN=$BASE_DN
LDAP_BIND_DN=cn=lector,$BASE_DN
LDAP_BIND_PASSWORD=$LP
SERVICIOS_FILE=$C/servicios.json
PROXY_DMZ=192.168.60.10,100.65.119.48
PRINT_API_URL=http://127.0.0.1:8000
PRINT_API_USER=$(val PRINT_API_USER "$CRED")
PRINT_API_PASSWORD=$(val PRINT_API_PASSWORD "$CRED")
PRINT_IMPRESORA=$(val PRINT_API_IMPRESORA "$CRED")
PRINT_ARCHIVO_DIR=/var/lib/edunova/impresiones
PRINT_RETENCION_DIAS=7
PRINT_DIFERIDO=1
PRINT_CUPO_ESTUDIANTE=20
PRINT_CUPO_DOCENTE=100
PRINT_CUPO_SECRETARIA=100
PRINT_CUPO_ADMIN=0
PRINT_COLOR_ESTUDIANTE=0
PRINT_COLOR_DOCENTE=1
PRINT_COLOR_SECRETARIA=1
PRINT_COLOR_ADMIN=1
SECRETARIA_MATRICULA=1
ENV
umask 022
chown root:lms $E; chmod 640 $E

cat > /etc/systemd/system/lms.service <<UNIT
[Unit]
Description=EduNova - plataforma educativa (Centro Educativo Mejoland)
After=network-online.target mariadb.service slapd.service print-api.service
Wants=network-online.target

[Service]
User=lms
Group=lms
WorkingDirectory=$B
ExecStart=/usr/bin/node $B/server.js
Restart=always
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes
ReadWritePaths=/var/lib/edunova

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable -q lms; systemctl restart lms; sleep 3

paso "7 Verificacion"
echo -n "  Pagina principal:         "; curl -s -o /dev/null -w "%{http_code} (esperado 200)\n" http://127.0.0.1:3001/
echo -n "  API sin sesion:           "; curl -s -o /dev/null -w "%{http_code} (esperado 401)\n" http://127.0.0.1:3001/api/biblioteca
echo -n "  API de impresion sin clave: "; curl -s -o /dev/null -w "%{http_code} (esperado 401)\n" http://127.0.0.1:8000/impresoras
journalctl -u lms -n 3 --no-pager | sed 's/^/  /'
echo
echo "LISTO. EduNova: http://<IP-de-SRV-BD>:3001/  (en produccion se publica por el proxy: https://mejoland.edu.ec/plataforma/)"
echo "Claves generadas: $E y $CRED (solo root y los servicios)."
