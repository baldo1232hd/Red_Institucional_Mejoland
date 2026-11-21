#!/bin/bash
# =====================================================================
#  INSTALAR PANEL DE SECRETARIA - Centro Educativo Mejoland   (SRV-BD, root)
#  Instala el panel web de altas de cuentas (https://<srv-bd>/secretaria/):
#   - PHP 8.4-FPM con un pool propio (usuario secretariaweb) y alias /secretaria en Apache,
#     accesible solo desde la red interna, los servidores y Tailscale.
#   - Cuenta de servicio LDAP cn=svc-secretaria con escritura solo sobre ou=Altas,ou=Personas
#     (contrasenas y pertenencia a los grupos estudiantes y docentes).
#   - Archivos de configuracion en /etc/secretaria y estado/auditoria en /var/lib/secretaria.
#  Requisitos: 01-configurar-srv-bd.sh ejecutado (OpenLDAP dc=proyecto,dc=local y Apache).
#  Uso (desde esta carpeta):  bash instalar-panel.sh
#  Despues: bash crear-cuenta-secretaria.sh   (cuentas del personal de Secretaria)
# =====================================================================
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
D=$(cd "$(dirname "$0")" && pwd)
BASE=dc=proyecto,dc=local; ADMIN="cn=admin,$BASE"; LDAPI=ldapi:///; H=ldap://127.0.0.1
W=/var/www/secretaria; CFG=/etc/secretaria; ST=/var/lib/secretaria; PHPV=8.4
LOGO="$D/../edunova/frontend/logo.jpg"
paso() { echo; echo "=================== $* ==================="; }
[ -f "$D/secretaria_panel.php" ] || { echo "Falta $D/secretaria_panel.php"; exit 1; }

paso "1 Paquetes"
apt-get install -y -q apache2 php$PHPV-fpm php$PHPV-ldap php$PHPV-mbstring ldap-utils slapd >/dev/null
php -l "$D/secretaria_panel.php" >/dev/null

paso "2 Cuenta de servicio LDAP (cn=svc-secretaria)"
read -rsp "  Clave de $ADMIN: " PW </dev/tty; echo
ldapwhoami -x -H $H -D "$ADMIN" -w "$PW" >/dev/null || { echo "  Clave incorrecta"; exit 1; }
existe() { ldapsearch -x -LLL -H $H -D "$ADMIN" -w "$PW" -b "$1" -s base dn >/dev/null 2>&1; }
existe "ou=Altas,ou=Personas,$BASE" || printf 'dn: ou=Altas,ou=Personas,%s\nobjectClass: organizationalUnit\nou: Altas\n' "$BASE" \
  | ldapadd -x -H $H -D "$ADMIN" -w "$PW" >/dev/null
install -d -m 750 -o root -g root $CFG
if [ ! -s $CFG/ldap-service-password ]; then
  openssl rand -base64 24 | tr -d '/+=\n' > $CFG/ldap-service-password
fi
SVC_PW=$(cat $CFG/ldap-service-password); SVC_HASH=$(slappasswd -s "$SVC_PW")
if existe "cn=svc-secretaria,$BASE"; then
  printf 'dn: cn=svc-secretaria,%s\nchangetype: modify\nreplace: userPassword\nuserPassword: %s\n' "$BASE" "$SVC_HASH" \
    | ldapmodify -x -H $H -D "$ADMIN" -w "$PW" >/dev/null
else
  printf 'dn: cn=svc-secretaria,%s\nobjectClass: organizationalRole\nobjectClass: simpleSecurityObject\ncn: svc-secretaria\ndescription: Cuenta de servicio del Panel de Secretaria\nuserPassword: %s\n' "$BASE" "$SVC_HASH" \
    | ldapadd -x -H $H -D "$ADMIN" -w "$PW" >/dev/null
fi
unset PW SVC_PW
echo "  svc-secretaria: OK"

paso "3 Permisos LDAP (ACL de la base $BASE)"
DB=$(ldapsearch -Q -LLL -Y EXTERNAL -H $LDAPI -b cn=config "(olcSuffix=$BASE)" dn | sed -n 's/^dn: //p')
if ldapsearch -Q -LLL -Y EXTERNAL -H $LDAPI -b "$DB" -s base olcAccess | grep -q svc-secretaria; then
  echo "  Las ACL ya incluyen svc-secretaria"
else
  ldapsearch -Q -LLL -Y EXTERNAL -H $LDAPI -b "$DB" -s base olcAccess > /root/acl-antes-panel-$(date +%Y%m%d-%H%M).ldif
  S="dn.exact=\"cn=svc-secretaria,$BASE\""
  ldapmodify -Q -Y EXTERNAL -H $LDAPI >/dev/null <<LDIF
dn: $DB
changetype: modify
replace: olcAccess
olcAccess: {0}to dn.onelevel="ou=Altas,ou=Personas,$BASE" attrs=userPassword by $S write by self write by anonymous auth by * none
olcAccess: {1}to attrs=userPassword by self write by anonymous auth by * none
olcAccess: {2}to attrs=shadowLastChange by self write by * read
olcAccess: {3}to dn.exact="ou=Altas,ou=Personas,$BASE" attrs=children by $S write by * read
olcAccess: {4}to dn.onelevel="ou=Altas,ou=Personas,$BASE" by $S write by * read
olcAccess: {5}to dn.exact="cn=estudiantes,ou=Grupos,$BASE" attrs=member val.regex="^uid=[a-z0-9_-]+,ou=altas,ou=personas,dc=proyecto,dc=local\$" by $S write by * read
olcAccess: {6}to dn.exact="cn=docentes,ou=Grupos,$BASE" attrs=member val.regex="^uid=[a-z0-9_-]+,ou=altas,ou=personas,dc=proyecto,dc=local\$" by $S write by * read
olcAccess: {7}to * by * read
LDIF
  echo "  ACL aplicadas (copia de las anteriores en /root/acl-antes-panel-*.ldif)"
fi

paso "4 Usuario, archivos y pool PHP-FPM"
id secretariaweb >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin secretariaweb
chgrp secretariaweb $CFG
chown root:secretariaweb $CFG/ldap-service-password; chmod 640 $CFG/ldap-service-password
[ -f $CFG/usuarios-web.json ] || echo '{"users":{}}' > $CFG/usuarios-web.json
chown root:secretariaweb $CFG/usuarios-web.json; chmod 640 $CFG/usuarios-web.json
[ -f "$LOGO" ] && install -m 640 -o root -g secretariaweb "$LOGO" $CFG/logo.jpg
install -d -m 700 -o secretariaweb -g secretariaweb $ST $ST/login-rate $ST/sesiones
install -d -m 755 $W
install -m 640 -o root -g secretariaweb "$D/secretaria_panel.php" $W/index.php
cat > /etc/php/$PHPV/fpm/pool.d/secretaria.conf <<POOL
; Panel de Secretaria: pool aislado con usuario propio
[secretaria]
user = secretariaweb
group = secretariaweb
listen = /run/php/secretaria.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = 5
pm.process_idle_timeout = 60s
php_admin_value[open_basedir] = $W:$CFG:$ST:/tmp
php_admin_value[session.save_path] = $ST/sesiones
php_admin_flag[expose_php] = off
php_admin_value[upload_max_filesize] = 1M
POOL
systemctl restart php$PHPV-fpm

paso "5 Apache: alias /secretaria"
cat > /etc/apache2/conf-available/secretaria.conf <<CONF
# Panel de Secretaria (solo red interna, servidores y Tailscale)
Alias /secretaria $W
<Directory $W>
    Options -Indexes
    DirectoryIndex index.php
    Require ip 127.0.0.1 ::1 192.168.10.0/24 192.168.40.0/24 100.64.0.0/10
    <FilesMatch "\.php\$">
        SetHandler "proxy:unix:/run/php/secretaria.sock|fcgi://localhost"
    </FilesMatch>
</Directory>
CONF
a2enmod -q proxy_fcgi setenvif >/dev/null
a2enconf -q secretaria >/dev/null
apache2ctl configtest && systemctl reload apache2

paso "6 Verificacion"
echo -n "  Pagina: "; curl -s -o /dev/null -w "%{http_code} (esperado 200)\n" http://127.0.0.1/secretaria/
echo
echo "LISTO. Crear las cuentas del personal con: bash $D/crear-cuenta-secretaria.sh"
echo "Acceso: https://srv-bd.proyecto.local/secretaria/  (en modo casa, por Tailscale)"
