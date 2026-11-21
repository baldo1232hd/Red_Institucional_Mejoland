#!/bin/bash
# =====================================================================
#  MAC - SRV-APPS (root): GLPI 11 (inventario y tickets) + Nextcloud (nube)
#  - Bases glpi y nextcloud en el MariaDB de SRV-BD (se replican solas a damian-1)
#  - Apache + PHP 8.4:  http://IP/glpi   y   http://IP/nube
#  - Nextcloud con login por LDAP (cuenta institucional, SRV-BD + replica)
#  ANTES, en SRV-BD: definir las claves de los usuarios glpi y nextcloud de MariaDB
#  Uso:  bash 01-instalar-srv-apps.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root (sudo -i)"; exit 1; }
paso() { echo; echo "=================== $1 ==================="; }
DBH=srv-bd.proyecto.local; GLPI_VER=11.0.12
BASE=dc=proyecto,dc=local; LECTOR=cn=lector,$BASE
BK=/root/proyecto/apps-$(date +%Y%m%d-%H%M); mkdir -p $BK; chmod 700 $BK
SECRETOS=/root/proyecto/claves-apps.txt

paso "1 Nombres (Tailscale)"
cp -a /etc/hosts $BK/hosts
sed -i '/# >>> TAILSCALE/,/# <<< TAILSCALE/d' /etc/hosts
cat >> /etc/hosts <<'H'
# >>> TAILSCALE (solo en casa)
100.89.203.22   srv-bd.proyecto.local srv-bd
100.93.52.67    srv-bd-replica.proyecto.local srv-bd-replica
100.65.119.48   correo.proyecto.local correo
100.123.222.5   srv-monitoreo.proyecto.local srv-monitoreo
# <<< TAILSCALE
H
for p in "$DBH 3306" "$DBH 389" "srv-bd-replica 389"; do set -- $p
  timeout 3 bash -c "</dev/tcp/$1/$2" 2>/dev/null && echo "  $1:$2 OK" || echo "  $1:$2 NO RESPONDE"; done

paso "2 Paquetes (Apache + PHP 8.4)"
DEBIAN_FRONTEND=noninteractive apt-get install -y -q apache2 libapache2-mod-php php php-mysql php-gd php-curl php-zip php-xml \
  php-mbstring php-intl php-bcmath php-gmp php-ldap php-apcu php-bz2 php-imagick mariadb-client ldap-utils curl bzip2 >/dev/null \
  || { echo "  ERROR instalando paquetes"; exit 1; }
PV=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
for d in apache2 cli; do cat > /etc/php/$PV/$d/conf.d/90-mejoland.ini <<'I'
memory_limit = 512M
upload_max_filesize = 512M
post_max_size = 512M
max_execution_time = 300
date.timezone = America/Guayaquil
session.cookie_httponly = On
session.cookie_samesite = Lax
apc.enable_cli = 1
I
done
a2enmod rewrite headers env dir mime >/dev/null
echo "  PHP $PV"

paso "3 Claves"
read -rsp "  Clave de la base GLPI (CLAVE_BD_GLPI): " PWG; echo
read -rsp "  Clave de la base Nextcloud (CLAVE_BD_NEXTCLOUD): " PWN; echo
read -rsp "  Clave de cn=lector (LDAP): " PWL; echo
mysql -h $DBH -u glpi -p"$PWG" -e "SELECT 1" glpi >/dev/null 2>&1 && echo "  Base glpi: OK" || { echo "  ERROR: la clave no entra a la base glpi"; exit 1; }
mysql -h $DBH -u nextcloud -p"$PWN" -e "SELECT 1" nextcloud >/dev/null 2>&1 && echo "  Base nextcloud: OK" || { echo "  ERROR: la clave no entra a la base nextcloud"; exit 1; }
ldapwhoami -x -H ldap://$DBH -D "$LECTOR" -w "$PWL" >/dev/null 2>&1 && echo "  LDAP cn=lector: OK" || { echo "  ERROR: la clave de cn=lector no funciona"; exit 1; }

paso "4 GLPI $GLPI_VER"
if [ ! -d /var/www/glpi ]; then
  curl -fsSL -o /tmp/glpi.tgz https://github.com/glpi-project/glpi/releases/download/$GLPI_VER/glpi-$GLPI_VER.tgz \
    || { echo "  ERROR descargando GLPI"; exit 1; }
  tar -C /var/www -xzf /tmp/glpi.tgz; rm -f /tmp/glpi.tgz
fi
chown -R root:www-data /var/www/glpi; chmod -R g+rX /var/www/glpi
chown -R www-data:www-data /var/www/glpi/files /var/www/glpi/config /var/www/glpi/marketplace
cat > /etc/apache2/conf-available/glpi.conf <<'A'
Alias /glpi /var/www/glpi/public
<Directory /var/www/glpi/public>
    Require all granted
    RewriteEngine On
    RewriteBase /glpi
    RewriteCond %{HTTP:Authorization} ^(.+)$
    RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
    RewriteCond %{REQUEST_FILENAME} !-f
    RewriteRule ^(.*)$ index.php [QSA,L]
</Directory>
A
a2enconf glpi >/dev/null
if [ -f /var/www/glpi/config/config_db.php ]; then echo "  GLPI ya estaba instalado: se conserva"
else
  su -s /bin/bash www-data -c "php /var/www/glpi/bin/console database:install --db-host=$DBH --db-name=glpi --db-user=glpi \
    --db-password='$PWG' --default-language=es_ES --no-interaction" >$BK/glpi-install.log 2>&1 \
    && echo "  GLPI instalado en la base glpi de SRV-BD" \
    || echo "  AVISO: la instalacion por consola fallo (ver $BK/glpi-install.log); termina en el asistente web /glpi"
fi
rm -f /var/www/glpi/install/install.php

paso "5 Nextcloud"
if [ ! -d /var/www/nextcloud ]; then
  curl -fsSL -o /tmp/nc.tar.bz2 https://download.nextcloud.com/server/releases/latest.tar.bz2 || { echo "  ERROR descargando Nextcloud"; exit 1; }
  tar -C /var/www -xjf /tmp/nc.tar.bz2; rm -f /tmp/nc.tar.bz2
fi
mkdir -p /srv/nextcloud-data; chown -R www-data:www-data /var/www/nextcloud /srv/nextcloud-data; chmod 750 /srv/nextcloud-data
cat > /etc/apache2/conf-available/nextcloud.conf <<'A'
Alias /nube "/var/www/nextcloud/"
<Directory /var/www/nextcloud/>
    Require all granted
    AllowOverride All
    Options FollowSymLinks MultiViews
    <IfModule mod_dav.c>
        Dav off
    </IfModule>
</Directory>
A
a2enconf nextcloud >/dev/null; systemctl reload apache2
OCC() { su -s /bin/bash www-data -c "php /var/www/nextcloud/occ $*"; }
IP=$(tailscale ip -4 2>/dev/null | head -1)
if OCC status 2>/dev/null | grep -q "installed: true"; then echo "  Nextcloud ya estaba instalado: se conserva"
else
  ADMPW=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
  OCC maintenance:install --database=mysql --database-host=$DBH --database-name=nextcloud --database-user=nextcloud \
    --database-pass="'$PWN'" --admin-user=admin --admin-pass="'$ADMPW'" --data-dir=/srv/nextcloud-data >$BK/nc-install.log 2>&1 \
    || { echo "  ERROR instalando Nextcloud (ver $BK/nc-install.log)"; exit 1; }
  umask 077; echo "NEXTCLOUD_ADMIN=admin / $ADMPW" >> $SECRETOS
  echo "  Nextcloud instalado (clave de admin guardada en $SECRETOS)"
fi
OCC config:system:set trusted_domains 0 --value=localhost >/dev/null
OCC config:system:set trusted_domains 1 --value=$IP >/dev/null
OCC config:system:set trusted_domains 2 --value=srv-apps >/dev/null
OCC config:system:set trusted_domains 3 --value=192.168.40.21 >/dev/null
OCC config:system:set trusted_domains 4 --value=nube.mejoland.edu.ec >/dev/null
OCC config:system:set overwrite.cli.url --value=http://$IP/nube >/dev/null
OCC config:system:set htaccess.RewriteBase --value=/nube >/dev/null
OCC config:system:set default_phone_region --value=EC >/dev/null
OCC config:system:set default_language --value=es >/dev/null
OCC config:system:set memcache.local --value='\\OC\\Memcache\\APCu' >/dev/null
OCC maintenance:update:htaccess >/dev/null 2>&1
OCC background:cron >/dev/null
echo "*/5 * * * * www-data php -f /var/www/nextcloud/cron.php" > /etc/cron.d/nextcloud

paso "6 Nextcloud con cuenta institucional (LDAP)"
OCC app:enable user_ldap >/dev/null 2>&1
CID=$(OCC ldap:show-config 2>/dev/null | grep -oE 's[0-9]{2}' | head -1)
[ -n "$CID" ] || CID=$(OCC ldap:create-empty-config | grep -oE 's[0-9]{2}' | head -1)
S() { OCC ldap:set-config $CID "$1" "\"$2\"" >/dev/null; }
S ldapHost "ldap://srv-bd.proyecto.local"; S ldapPort 389
S ldapBackupHost "ldap://srv-bd-replica.proyecto.local"; S ldapBackupPort 389
S ldapAgentName "$LECTOR"; S ldapAgentPassword "$PWL"
S ldapBase "ou=personas,$BASE"; S ldapBaseUsers "ou=personas,$BASE"; S ldapBaseGroups "ou=grupos,$BASE"
S ldapUserFilterObjectclass inetOrgPerson
S ldapUserFilter "(objectClass=inetOrgPerson)"
S ldapLoginFilter "(&(objectClass=inetOrgPerson)(|(uid=%uid)(mail=%uid)))"
S ldapGroupFilter "(objectClass=groupOfNames)"; S ldapGroupMemberAssocAttr member
S ldapUserDisplayName cn; S ldapEmailAttribute mail
S ldapExpertUsernameAttr uid; S ldapTLS 0; S turnOffCertCheck 1
S ldapConfigurationActive 1
OCC ldap:test-config $CID | sed 's/^/  /'
echo "  Cuentas LDAP vistas: $(OCC ldap:search --limit 500 '' 2>/dev/null | grep -c '(' )"
unset PWG PWN PWL ADMPW

paso "7 Revision"
systemctl restart apache2; sleep 2
echo -n "  GLPI:      "; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1/glpi/
echo -n "  Nextcloud: "; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1/nube/status.php
echo
echo "LISTO."
echo "  GLPI:      http://$IP/glpi/   (usuario glpi / clave glpi  -> cambiala; desactiva tech, normal y post-only)"
echo "  Nextcloud: http://$IP/nube/   (entra con tu cuenta institucional, o admin: ver $SECRETOS)"
