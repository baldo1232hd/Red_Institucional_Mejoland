#!/bin/bash
# =====================================================================
#  SRV-BD (Toshiba Satellite L55-A) - servidor central del proyecto
#  MariaDB (base conjunta) + OpenLDAP + DNS + DHCP + NTP + Syslog + CUPS
#  Ejecutar como root:  bash 01-configurar-srv-bd.sh
#  No cambia la red actual. La red del laboratorio queda lista en
#  /root/proyecto/interfaces.lab y se aplica despues con: modo-lab
# =====================================================================

if [ "$(id -u)" -ne 0 ]; then echo "Ejecutar como root (su -)"; exit 1; fi
paso() { echo; echo "=================== $1 ==================="; }

IF_LAB=enp1s0            # puerto de cable de esta laptop
IP_CORREO_TS=100.65.119.48   # IP Tailscale del servidor de correo (modo casa)
IP_AAA1_TS=100.75.163.23     # IP Tailscale de SRV-AAA-1 (modo casa)

paso "0 Revisar /srv/datos"
FS=$(findmnt -n -o FSTYPE /srv/datos 2>/dev/null)
if [ "$FS" != "ext4" ]; then
  echo "ERROR: /srv/datos no esta montado como ext4 (tiene: '${FS:-nada}')."
  echo "Revisa con: df -T /srv/datos   y avisa antes de seguir."
  exit 1
fi
df -h /srv/datos

echo
echo "== Claves (no se muestran al escribir). Usa las mismas que en la HP y en SRV-AAA-1 =="
read -rsp "Clave del administrador de LDAP (cn=admin): " CLAVE_LDAP_ADMIN; echo
read -rsp "Clave de cn=lector (la misma de la HP y SRV-AAA-1): " CLAVE_LECTOR; echo
read -rsp "Clave del usuario radius de MariaDB (la misma de SRV-AAA-1): " CLAVE_BD_RADIUS; echo
read -rsp "Clave del usuario roundcube de MariaDB (la misma de la HP): " CLAVE_BD_ROUNDCUBE; echo
read -rsp "Clave para los usuarios de prueba de LDAP (acabezas, docente1, estudiante1, oxidized): " CLAVE_USUARIOS; echo

mkdir -p /root/proyecto && chmod 700 /root/proyecto
# Claves de servicios: se generan aleatoriamente y se guardan solo para root
CLAVES=/root/proyecto/claves.txt
if [ ! -f $CLAVES ]; then
  for n in REPL ZABBIX GLPI NEXTCLOUD INSTITUCION; do
    echo "CLAVE_BD_$n=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)" >> $CLAVES
  done
  chmod 600 $CLAVES
fi
. $CLAVES

paso "1 Paquetes"
cat <<EOF | debconf-set-selections
slapd slapd/no_configuration boolean false
slapd slapd/domain string proyecto.local
slapd shared/organization string Proyecto
slapd slapd/password1 password $CLAVE_LDAP_ADMIN
slapd slapd/password2 password $CLAVE_LDAP_ADMIN
slapd slapd/purge_database boolean false
slapd slapd/move_old_database boolean true
EOF
apt update
DEBIAN_FRONTEND=noninteractive apt install -y mariadb-server slapd ldap-utils bind9 bind9-utils \
  kea-dhcp4-server chrony rsyslog cups ufw zabbix-agent rsync openssl

paso "2 Nombre y carpeta del proyecto"
[ -f /root/proyecto/interfaces.casa ] || cp /etc/network/interfaces /root/proyecto/interfaces.casa
timedatectl set-timezone America/Guayaquil
hostnamectl set-hostname srv-bd
if grep -q '^127.0.1.1' /etc/hosts; then
  sed -i 's/^127.0.1.1.*/127.0.1.1 srv-bd.proyecto.local srv-bd/' /etc/hosts
else
  echo '127.0.1.1 srv-bd.proyecto.local srv-bd' >> /etc/hosts
fi
command -v tailscale >/dev/null && tailscale set --hostname=srv-bd

paso "3 Servidor de hora (NTP)"
if ! grep -q 'PROYECTO-BD' /etc/chrony/chrony.conf; then
cat >> /etc/chrony/chrony.conf <<'EOF'
# PROYECTO-BD
allow 192.168.0.0/16
allow 10.255.0.0/29
allow 100.64.0.0/10
local stratum 10
EOF
fi
systemctl restart chrony

paso "4 Servidor de registros (Syslog)"
cat > /etc/rsyslog.d/10-remoto.conf <<'EOF'
module(load="imudp")
input(type="imudp" port="514")
template(name="PorEquipo" type="string" string="/var/log/remoto/%FROMHOST-IP%.log")
if $fromhost-ip != '127.0.0.1' then {
    action(type="omfile" dynaFile="PorEquipo")
    stop
}
EOF
mkdir -p /var/log/remoto
systemctl restart rsyslog

paso "5 MariaDB en /srv/datos"
cat > /etc/mysql/mariadb.conf.d/60-proyecto.cnf <<'EOF'
[mysqld]
bind-address      = 0.0.0.0
datadir           = /srv/datos/mysql
server-id         = 1
log_bin           = mysql-bin
binlog_format     = ROW
log_slave_updates = ON
expire_logs_days  = 7
log_bin_trust_function_creators = 1
character-set-server = utf8mb4
collation-server     = utf8mb4_unicode_ci
EOF
if [ ! -d /srv/datos/mysql/mysql ]; then
  systemctl stop mariadb
  mkdir -p /srv/datos/mysql
  rsync -a /var/lib/mysql/ /srv/datos/mysql/
  chown -R mysql:mysql /srv/datos/mysql
fi
systemctl restart mariadb
mariadb -e "SELECT @@datadir;"

mariadb <<EOF
CREATE DATABASE IF NOT EXISTS institucion;
CREATE DATABASE IF NOT EXISTS radius;
CREATE DATABASE IF NOT EXISTS roundcube;
CREATE DATABASE IF NOT EXISTS zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE DATABASE IF NOT EXISTS glpi;
CREATE DATABASE IF NOT EXISTS nextcloud;
CREATE DATABASE IF NOT EXISTS impresion;

-- Usuarios del laboratorio (IP del diseno)
CREATE USER IF NOT EXISTS 'radius'@'192.168.40.11' IDENTIFIED BY '$CLAVE_BD_RADIUS';
CREATE USER IF NOT EXISTS 'radius'@'192.168.40.12' IDENTIFIED BY '$CLAVE_BD_RADIUS';
GRANT ALL ON radius.* TO 'radius'@'192.168.40.11';
GRANT ALL ON radius.* TO 'radius'@'192.168.40.12';
CREATE USER IF NOT EXISTS 'roundcube'@'192.168.60.10' IDENTIFIED BY '$CLAVE_BD_ROUNDCUBE';
GRANT ALL ON roundcube.* TO 'roundcube'@'192.168.60.10';
CREATE USER IF NOT EXISTS 'zabbix'@'192.168.40.20' IDENTIFIED BY '$CLAVE_BD_ZABBIX';
GRANT ALL ON zabbix.* TO 'zabbix'@'192.168.40.20';
CREATE USER IF NOT EXISTS 'glpi'@'192.168.40.21' IDENTIFIED BY '$CLAVE_BD_GLPI';
GRANT ALL ON glpi.* TO 'glpi'@'192.168.40.21';
GRANT SELECT ON mysql.time_zone_name TO 'glpi'@'192.168.40.21';
CREATE USER IF NOT EXISTS 'nextcloud'@'192.168.40.21' IDENTIFIED BY '$CLAVE_BD_NEXTCLOUD';
GRANT ALL ON nextcloud.* TO 'nextcloud'@'192.168.40.21';
CREATE USER IF NOT EXISTS 'app_institucion'@'192.168.10.%' IDENTIFIED BY '$CLAVE_BD_INSTITUCION';
CREATE USER IF NOT EXISTS 'app_institucion'@'192.168.20.%' IDENTIFIED BY '$CLAVE_BD_INSTITUCION';
GRANT SELECT, INSERT, UPDATE, DELETE ON institucion.* TO 'app_institucion'@'192.168.10.%';
GRANT SELECT, INSERT, UPDATE, DELETE ON institucion.* TO 'app_institucion'@'192.168.20.%';
CREATE USER IF NOT EXISTS 'repl'@'192.168.40.13' IDENTIFIED BY '$CLAVE_BD_REPL';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'192.168.40.13';

-- Modo casa: los mismos usuarios desde las IP de Tailscale (se eliminan en modo-lab)
CREATE USER IF NOT EXISTS 'radius'@'$IP_AAA1_TS' IDENTIFIED BY '$CLAVE_BD_RADIUS';
GRANT ALL ON radius.* TO 'radius'@'$IP_AAA1_TS';
CREATE USER IF NOT EXISTS 'roundcube'@'$IP_CORREO_TS' IDENTIFIED BY '$CLAVE_BD_ROUNDCUBE';
GRANT ALL ON roundcube.* TO 'roundcube'@'$IP_CORREO_TS';

CREATE TABLE IF NOT EXISTS impresion.trabajos (
  clave VARCHAR(100) PRIMARY KEY,
  impresora VARCHAR(64), usuario VARCHAR(64), trabajo INT, paginas INT,
  importado TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
FLUSH PRIVILEGES;
EOF
mariadb-tzinfo-to-sql /usr/share/zoneinfo 2>/dev/null | mariadb mysql
echo "Bases creadas:"; mariadb -N -e "SHOW DATABASES;" | tr '\n' ' '; echo

paso "6 OpenLDAP: estructura, usuarios y grupos"
ldapsearch -x -b dc=proyecto,dc=local -s base >/dev/null 2>&1 || dpkg-reconfigure -f noninteractive slapd
H_LECTOR=$(slappasswd -s "$CLAVE_LECTOR")
H_USR=$(slappasswd -s "$CLAVE_USUARIOS")
cat > /root/proyecto/base.ldif <<EOF
dn: ou=personas,dc=proyecto,dc=local
objectClass: organizationalUnit
ou: personas

dn: ou=grupos,dc=proyecto,dc=local
objectClass: organizationalUnit
ou: grupos

dn: cn=lector,dc=proyecto,dc=local
objectClass: organizationalRole
objectClass: simpleSecurityObject
cn: lector
userPassword: $H_LECTOR

dn: uid=acabezas,ou=personas,dc=proyecto,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
uid: acabezas
cn: Ariel Cabezas
sn: Cabezas
mail: acabezas@proyecto.local
uidNumber: 10001
gidNumber: 10001
homeDirectory: /home/acabezas
loginShell: /bin/bash
userPassword: $H_USR

dn: uid=docente1,ou=personas,dc=proyecto,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
uid: docente1
cn: Docente Prueba
sn: Prueba
mail: docente1@proyecto.local
uidNumber: 10101
gidNumber: 10101
homeDirectory: /home/docente1
loginShell: /bin/bash
userPassword: $H_USR

dn: uid=estudiante1,ou=personas,dc=proyecto,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
uid: estudiante1
cn: Estudiante Prueba
sn: Prueba
mail: estudiante1@proyecto.local
uidNumber: 10201
gidNumber: 10201
homeDirectory: /home/estudiante1
loginShell: /bin/bash
userPassword: $H_USR

dn: uid=oxidized,ou=personas,dc=proyecto,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
uid: oxidized
cn: Oxidized
sn: Respaldo
uidNumber: 10900
gidNumber: 10900
homeDirectory: /nonexistent
userPassword: $H_USR

dn: cn=admins-red,ou=grupos,dc=proyecto,dc=local
objectClass: groupOfNames
cn: admins-red
member: uid=acabezas,ou=personas,dc=proyecto,dc=local
member: uid=oxidized,ou=personas,dc=proyecto,dc=local

dn: cn=administracion,ou=grupos,dc=proyecto,dc=local
objectClass: groupOfNames
cn: administracion
member: uid=acabezas,ou=personas,dc=proyecto,dc=local

dn: cn=docentes,ou=grupos,dc=proyecto,dc=local
objectClass: groupOfNames
cn: docentes
member: uid=docente1,ou=personas,dc=proyecto,dc=local

dn: cn=estudiantes,ou=grupos,dc=proyecto,dc=local
objectClass: groupOfNames
cn: estudiantes
member: uid=estudiante1,ou=personas,dc=proyecto,dc=local
EOF
chmod 600 /root/proyecto/base.ldif
ldapadd -c -x -D cn=admin,dc=proyecto,dc=local -w "$CLAVE_LDAP_ADMIN" -f /root/proyecto/base.ldif 2>&1 | grep -E 'adding|Already' | sed 's/^/  /'

# Replicacion hacia SRV-BD-REPLICA (syncprov)
if ! ldapsearch -Q -Y EXTERNAL -H ldapi:/// -b cn=config '(olcOverlay=syncprov)' dn 2>/dev/null | grep -q '^dn:'; then
cat > /root/proyecto/syncprov.ldif <<'EOF'
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: syncprov

dn: olcOverlay=syncprov,olcDatabase={1}mdb,cn=config
changetype: add
objectClass: olcOverlayConfig
objectClass: olcSyncProvConfig
olcOverlay: syncprov
olcSpCheckpoint: 100 10
olcSpSessionLog: 100

dn: olcDatabase={1}mdb,cn=config
changetype: modify
add: olcDbIndex
olcDbIndex: entryCSN eq
olcDbIndex: entryUUID eq
EOF
ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f /root/proyecto/syncprov.ldif
fi
echo "Usuarios en LDAP:"; ldapsearch -x -LLL -b ou=personas,dc=proyecto,dc=local uid | grep '^uid:' | sed 's/^/  /'

paso "7 DNS principal (bind9)"
cat > /etc/bind/named.conf.options <<'EOF'
options {
    directory "/var/cache/bind";
    listen-on { any; };
    listen-on-v6 { none; };
    allow-query { 192.168.0.0/16; 10.255.0.0/29; 100.64.0.0/10; localhost; };
    recursion yes;
    allow-recursion { 192.168.0.0/16; 10.255.0.0/29; 100.64.0.0/10; localhost; };
    forwarders { 8.8.8.8; 1.1.1.1; };
    dnssec-validation auto;
};
EOF
cat > /etc/bind/named.conf.local <<'EOF'
zone "proyecto.local" {
    type master;
    file "/etc/bind/db.proyecto.local";
    allow-transfer { 192.168.40.13; };
    also-notify { 192.168.40.13; };
};
EOF
cat > /etc/bind/db.proyecto.local <<'EOF'
$TTL 86400
@   IN SOA srv-bd.proyecto.local. admin.proyecto.local. (
        2026102501 ; serie
        3600 900 604800 86400 )
@                  IN NS  srv-bd.proyecto.local.
@                  IN NS  srv-bd-replica.proyecto.local.
@                  IN MX  10 correo.proyecto.local.
srv-bd             IN A   192.168.40.10
srv-aaa-1          IN A   192.168.40.11
srv-aaa-2          IN A   192.168.40.12
srv-bd-replica     IN A   192.168.40.13
monitoreo          IN A   192.168.40.20
apps               IN A   192.168.40.21
glpi               IN CNAME apps
nube               IN CNAME apps
impresora          IN A   192.168.40.30
correo             IN A   192.168.60.10
webmail            IN CNAME correo
www                IN CNAME correo
r1-borde           IN A   192.168.40.2
r2-borde           IN A   192.168.40.3
sw-nucleo-1        IN A   192.168.50.252
sw-nucleo-2        IN A   192.168.50.253
sw-acc-admin       IN A   192.168.50.247
sw-acc-docentes    IN A   192.168.50.248
sw-acc-estudiantes IN A   192.168.50.249
ap-estudiantes     IN A   192.168.50.240
EOF
if named-checkconf && named-checkzone proyecto.local /etc/bind/db.proyecto.local; then
  systemctl restart named
else
  echo "bind9: ERROR en la configuracion (ver arriba)"
fi

paso "8 DHCP (Kea, principal del par)"
HOOKS=$(dirname "$(find /usr/lib -name libdhcp_ha.so 2>/dev/null | head -1)")
[ -n "$HOOKS" ] || HOOKS=/usr/lib/x86_64-linux-gnu/kea/hooks
[ -f /etc/kea/kea-dhcp4.conf.orig ] || cp /etc/kea/kea-dhcp4.conf /etc/kea/kea-dhcp4.conf.orig
cat > /etc/kea/kea-dhcp4.conf <<EOF
{
"Dhcp4": {
  "interfaces-config": { "interfaces": [ "$IF_LAB" ], "dhcp-socket-type": "udp" },
  "lease-database": { "type": "memfile", "persist": true, "name": "/var/lib/kea/kea-leases4.csv" },
  "valid-lifetime": 86400,
  "option-data": [
    { "name": "domain-name-servers", "data": "192.168.40.10, 192.168.40.13" },
    { "name": "domain-name", "data": "proyecto.local" },
    { "name": "ntp-servers", "data": "192.168.40.10" }
  ],
  "hooks-libraries": [
    { "library": "$HOOKS/libdhcp_lease_cmds.so" },
    { "library": "$HOOKS/libdhcp_ha.so",
      "parameters": { "high-availability": [ {
        "this-server-name": "srv-bd",
        "mode": "hot-standby",
        "heartbeat-delay": 10000,
        "max-response-delay": 60000,
        "max-ack-delay": 5000,
        "max-unacked-clients": 5,
        "multi-threading": { "enable-multi-threading": true, "http-dedicated-listener": true,
                             "http-listener-threads": 2, "http-client-threads": 2 },
        "peers": [
          { "name": "srv-bd", "url": "http://192.168.40.10:8000/", "role": "primary" },
          { "name": "srv-bd-replica", "url": "http://192.168.40.13:8000/", "role": "standby" }
        ] } ] } }
  ],
  "subnet4": [
    { "id": 10, "subnet": "192.168.10.0/24", "pools": [ { "pool": "192.168.10.100 - 192.168.10.199" } ],
      "option-data": [ { "name": "routers", "data": "192.168.10.1" } ] },
    { "id": 20, "subnet": "192.168.20.0/24", "pools": [ { "pool": "192.168.20.100 - 192.168.20.199" } ],
      "option-data": [ { "name": "routers", "data": "192.168.20.1" } ] },
    { "id": 30, "subnet": "192.168.30.0/24", "pools": [ { "pool": "192.168.30.100 - 192.168.30.199" } ],
      "option-data": [ { "name": "routers", "data": "192.168.30.1" } ] }
  ]
}
}
EOF
if kea-dhcp4 -t /etc/kea/kea-dhcp4.conf >/dev/null 2>&1; then
  echo "kea: configuracion OK (en casa queda esperando a la replica; es normal)"
  systemctl restart kea-dhcp4-server
else
  echo "kea: ERROR"; kea-dhcp4 -t /etc/kea/kea-dhcp4.conf | tail -5
fi

paso "9 Impresion (CUPS)"
cupsctl --remote-admin --remote-any --share-printers
for u in $(getent group sudo | cut -d: -f4 | tr ',' ' '); do usermod -aG lpadmin "$u"; done
cat > /usr/local/bin/importar-impresiones.sh <<'EOF'
#!/bin/bash
[ -f /var/log/cups/page_log ] || exit 0
awk '$6=="total" {printf "INSERT IGNORE INTO trabajos (clave,impresora,usuario,trabajo,paginas) VALUES (\"%s-%s\",\"%s\",\"%s\",%s,%s);\n",$1,$3,$1,$2,$3,$7}' /var/log/cups/page_log | mariadb impresion
EOF
chmod +x /usr/local/bin/importar-impresiones.sh
echo '0 * * * * root /usr/local/bin/importar-impresiones.sh' > /etc/cron.d/impresiones
echo "La impresora (192.168.40.30) se agrega en el laboratorio con: agregar-impresora"
cat > /usr/local/sbin/agregar-impresora <<'EOF'
#!/bin/bash
lpadmin -p IMPRESORA -E -v ipp://192.168.40.30/ipp/print -m everywhere && lpoptions -d IMPRESORA && lpstat -p
EOF
chmod +x /usr/local/sbin/agregar-impresora

paso "10 Respaldos diarios (hacia SRV-BD-REPLICA cuando exista)"
cat > /usr/local/bin/respaldo.sh <<'EOF'
#!/bin/bash
F=$(date +%F); D=/srv/datos/respaldos
mkdir -p $D
mariadb-dump --all-databases --single-transaction --routines --events | gzip > $D/bd-$F.sql.gz
slapcat -n 1 | gzip > $D/ldap-$F.ldif.gz
tar czf $D/config-$F.tgz /etc/bind /etc/kea /etc/cups /etc/ldap /etc/mysql 2>/dev/null
find $D -type f -mtime +14 -delete
rsync -a -e "ssh -o BatchMode=yes -o ConnectTimeout=10" $D/ respaldo@192.168.40.13:/srv/respaldos/srv-bd/ 2>/dev/null || echo "replica no disponible; respaldo local en $D"
EOF
chmod +x /usr/local/bin/respaldo.sh
[ -f /root/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519
echo '0 2 * * * root /usr/local/bin/respaldo.sh' > /etc/cron.d/respaldo
/usr/local/bin/respaldo.sh
ls -lh /srv/datos/respaldos | tail -3

paso "11 Agente de monitoreo"
sed -i "s/^Server=.*/Server=monitoreo.proyecto.local/; s/^ServerActive=.*/ServerActive=monitoreo.proyecto.local/; s/^Hostname=.*/Hostname=srv-bd/" /etc/zabbix/zabbix_agentd.conf
systemctl enable zabbix-agent >/dev/null 2>&1
systemctl restart zabbix-agent

paso "12 SSH sin root"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart ssh

paso "13 Firewall (reglas del laboratorio + dos de casa)"
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow in on tailscale0
ufw allow from 192.168.10.0/24 to any port 22 proto tcp
ufw allow 53
ufw allow 67/udp
ufw allow 123/udp
ufw allow 514/udp
ufw allow from 192.168.0.0/16 to any port 631 proto tcp
for ip in 192.168.40.11 192.168.40.12 192.168.40.13 192.168.40.20 192.168.40.21 192.168.60.10; do
  ufw allow from $ip to any port 3306,389 proto tcp
done
ufw allow from 192.168.10.0/24 to any port 3306 proto tcp
ufw allow from 192.168.20.0/24 to any port 3306 proto tcp
ufw allow from 192.168.40.13 to any port 8000 proto tcp
ufw allow from 192.168.40.20 to any port 10050 proto tcp
sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw
ufw --force enable

paso "14 Red del laboratorio (solo se guarda, no se aplica)"
cat > /root/proyecto/interfaces.lab <<EOF
auto lo
iface lo inet loopback

auto $IF_LAB
iface $IF_LAB inet static
    address 192.168.40.10/24
    gateway 192.168.40.1
    dns-nameservers 127.0.0.1 192.168.40.13
    dns-search proyecto.local
EOF

paso "15 Scripts modo-lab y modo-casa (solo se crean)"
cat > /usr/local/sbin/modo-lab <<EOF
#!/bin/bash
# Cambia SRV-BD a la red del laboratorio. Ejecutar desde el teclado de la laptop.
cp /root/proyecto/interfaces.lab /etc/network/interfaces
ufw delete allow in on tailscale0 >/dev/null 2>&1
ufw delete allow 22/tcp >/dev/null 2>&1
mariadb -e "DROP USER IF EXISTS 'radius'@'$IP_AAA1_TS'; DROP USER IF EXISTS 'roundcube'@'$IP_CORREO_TS'; FLUSH PRIVILEGES;"
systemctl restart networking
sleep 5
systemctl restart chrony rsyslog named kea-dhcp4-server mariadb slapd cups zabbix-agent
echo "== Prueba de red =="
ping -c 2 192.168.40.1
dig @127.0.0.1 correo.proyecto.local +short
echo "Para agregar la impresora: agregar-impresora"
EOF
cat > /usr/local/sbin/modo-casa <<EOF
#!/bin/bash
cp /root/proyecto/interfaces.casa /etc/network/interfaces
ufw allow in on tailscale0
ufw allow 22/tcp
systemctl restart networking
sleep 5
systemctl restart chrony rsyslog named mariadb slapd zabbix-agent
ping -c 2 8.8.8.8
EOF
chmod +x /usr/local/sbin/modo-lab /usr/local/sbin/modo-casa

paso "16 Revision final"
for s in mariadb slapd named kea-dhcp4-server chrony rsyslog cups zabbix-agent; do printf '%-18s %s\n' "$s" "$(systemctl is-active $s)"; done
echo
echo "LDAP con cn=lector:"
ldapsearch -x -LLL -D cn=lector,dc=proyecto,dc=local -w "$CLAVE_LECTOR" -b ou=personas,dc=proyecto,dc=local '(uid=acabezas)' mail | grep mail || echo "  FALLO"
echo "DNS:"; dig @127.0.0.1 correo.proyecto.local +short
echo "IP de Tailscale de este servidor: $(tailscale ip -4 2>/dev/null)"
echo
echo "LISTO. Claves generadas para Zabbix, GLPI, Nextcloud y replica en: $CLAVES"
