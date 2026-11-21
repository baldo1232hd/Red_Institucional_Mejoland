#!/bin/bash
# =====================================================================
#  SRV-AAA-1 (Toshiba L645D) - FreeRADIUS - configuracion individual
#  Ejecutar como root:  bash 01-configurar-aaa1.sh
#  No cambia la red actual. La red del laboratorio queda lista en
#  /root/proyecto/interfaces.lab y se aplica despues con: modo-lab
# =====================================================================

if [ "$(id -u)" -ne 0 ]; then echo "Ejecutar como root (su -)"; exit 1; fi

echo "== Claves del proyecto (no se muestran al escribir) =="
read -rsp "Clave de cn=lector (LDAP): " CLAVE_LECTOR; echo
read -rsp "Clave del usuario radius (MariaDB): " CLAVE_BD_RADIUS; echo
SECRETO=${RADIUS_SECRETO:-}   # clave compartida con routers, switches y AP (la misma de "radius server ... key")
[ -n "$SECRETO" ] || { read -rsp "Secreto RADIUS compartido con los equipos de red: " SECRETO; echo; }

paso() { echo; echo "=================== $1 ==================="; }
R=/etc/freeradius/3.0

paso "1 Paquetes"
apt update
apt install -y freeradius freeradius-ldap freeradius-mysql freeradius-utils \
  mariadb-client ldap-utils chrony rsyslog ufw zabbix-agent

paso "2 Carpeta del proyecto, nombre y marcas de Tailscale"
mkdir -p /root/proyecto
[ -f /root/proyecto/interfaces.casa ] || cp /etc/network/interfaces /root/proyecto/interfaces.casa
timedatectl set-timezone America/Guayaquil
hostnamectl set-hostname srv-aaa-1
if grep -q '^127.0.1.1' /etc/hosts; then
  sed -i 's/^127.0.1.1.*/127.0.1.1 srv-aaa-1.proyecto.local srv-aaa-1/' /etc/hosts
else
  echo '127.0.1.1 srv-aaa-1.proyecto.local srv-aaa-1' >> /etc/hosts
fi
[ -f /root/proyecto/hosts-tailscale.txt ] || printf '# >>> TAILSCALE (solo en casa)\n# <<< TAILSCALE\n' > /root/proyecto/hosts-tailscale.txt
grep -q '>>> TAILSCALE' /etc/hosts || cat /root/proyecto/hosts-tailscale.txt >> /etc/hosts

paso "3 Clientes RADIUS (routers, switches y AP)"
if ! grep -q 'PROYECTO-AAA' $R/clients.conf; then
cat >> $R/clients.conf <<EOF

# PROYECTO-AAA
client r1-borde {
    ipaddr    = 192.168.40.2
    secret    = $SECRETO
    shortname = r1
}
client r2-borde {
    ipaddr    = 192.168.40.3
    secret    = $SECRETO
    shortname = r2
}
client ap-estudiantes {
    ipaddr    = 192.168.50.240
    secret    = $SECRETO
    shortname = ap
}
client switches {
    ipaddr    = 192.168.50.0/24
    secret    = $SECRETO
    shortname = switches
}
EOF
fi

paso "4 Modulo LDAP (cuentas en SRV-BD y su replica)"
[ -f $R/mods-available/ldap.orig ] || cp $R/mods-available/ldap $R/mods-available/ldap.orig
cat > $R/mods-available/ldap <<EOF
# PROYECTO-AAA - original guardado en ldap.orig
ldap {
	server   = 'srv-bd.proyecto.local'
	server   = 'srv-bd-replica.proyecto.local'
	port     = 389
	identity = 'cn=lector,dc=proyecto,dc=local'
	password = '$CLAVE_LECTOR'
	base_dn  = 'dc=proyecto,dc=local'
	user_dn  = "LDAP-UserDn"

	user {
		base_dn = "ou=personas,\${..base_dn}"
		filter  = "(uid=%{%{Stripped-User-Name}:-%{User-Name}})"
	}

	group {
		base_dn = "ou=grupos,\${..base_dn}"
		filter  = '(objectClass=groupOfNames)'
		membership_filter = "(member=%{control:\${..user_dn}})"
	}

	options {
		chase_referrals = yes
		rebind = yes
		res_timeout = 5
		srv_timelimit = 3
		net_timeout = 3
		idle = 60
		probes = 3
		interval = 3
		ldap_debug = 0x0000
	}

	# start = 0: FreeRADIUS arranca aunque SRV-BD todavia no exista
	pool {
		start = 0
		min = 0
		max = 16
		spare = 2
		uses = 0
		retry_delay = 30
		lifetime = 0
		idle_timeout = 60
	}
}
EOF

paso "5 Modulo SQL (contabilidad en la base conjunta)"
[ -f $R/mods-available/sql.orig ] || cp $R/mods-available/sql $R/mods-available/sql.orig
cat > $R/mods-available/sql <<EOF
# PROYECTO-AAA - original guardado en sql.orig
sql {
	dialect = "mysql"
	driver  = "rlm_sql_mysql"

	mysql {
		warnings = auto
	}

	server    = "srv-bd.proyecto.local"
	port      = 3306
	login     = "radius"
	password  = "$CLAVE_BD_RADIUS"
	radius_db = "radius"

	acct_table1      = "radacct"
	acct_table2      = "radacct"
	postauth_table   = "radpostauth"
	authcheck_table  = "radcheck"
	groupcheck_table = "radgroupcheck"
	authreply_table  = "radreply"
	groupreply_table = "radgroupreply"
	usergroup_table  = "radusergroup"
	delete_stale_sessions = yes

	# start = 0: FreeRADIUS arranca aunque SRV-BD todavia no exista
	pool {
		start = 0
		min = 0
		max = 16
		spare = 2
		uses = 0
		retry_delay = 30
		lifetime = 0
		idle_timeout = 60
	}

	read_clients = no
	client_table = "nas"
	group_attribute = "SQL-Group"

	\$INCLUDE \${modconfdir}/\${.:name}/main/\${dialect}/queries.conf
}
EOF
ln -sf ../mods-available/ldap $R/mods-enabled/ldap
ln -sf ../mods-available/sql  $R/mods-enabled/sql

paso "6 Reglas de autenticacion"
for f in $R/sites-available/default $R/sites-available/inner-tunnel; do
  [ -f "$f.orig" ] || cp "$f" "$f.orig"
done

# default: LDAP + solo admins-red en routers/switches con privilegio 15
if ! grep -q 'PROYECTO-AAA' $R/sites-available/default; then
  sed -i '0,/^\s*-ldap\s*$/{s//\t-ldap\n\
\n\
\t# PROYECTO-AAA\n\
\tif ((ok || updated) \&\& User-Password \&\& !control:Auth-Type) {\n\
\t\tupdate {\n\
\t\t\t\&control:Auth-Type := ldap\n\
\t\t}\n\
\t}\n\
\tif ("%{client:shortname}" != "ap") {\n\
\t\tif (!(LDAP-Group == "admins-red")) {\n\
\t\t\treject\n\
\t\t}\n\
\t\tupdate reply {\n\
\t\t\t\&Cisco-AVPair := "shell:priv-lvl=15"\n\
\t\t}\n\
\t}/}' $R/sites-available/default
fi

# inner-tunnel (Wi-Fi EAP-TTLS): solo LDAP
if ! grep -q 'PROYECTO-AAA' $R/sites-available/inner-tunnel; then
  sed -i '0,/^\s*-ldap\s*$/{s//\t-ldap\n\
\n\
\t# PROYECTO-AAA\n\
\tif ((ok || updated) \&\& User-Password \&\& !control:Auth-Type) {\n\
\t\tupdate {\n\
\t\t\t\&control:Auth-Type := ldap\n\
\t\t}\n\
\t}/}' $R/sites-available/inner-tunnel
fi

# Auth-Type LDAP en la seccion authenticate de los dos sitios
for f in $R/sites-available/default $R/sites-available/inner-tunnel; do
  if ! grep -Eq '^\s*Auth-Type LDAP' "$f"; then
    sed -i '0,/^authenticate {/{s//authenticate {\n\tAuth-Type LDAP {\n\t\tldap\n\t}/}' "$f"
  fi
done

paso "7 Wi-Fi con EAP-TTLS"
sed -i '0,/default_eap_type = md5/s//default_eap_type = ttls/' $R/mods-available/eap

chown -R freerad:freerad /etc/freeradius
chmod 640 $R/mods-available/ldap $R/mods-available/sql

paso "8 Revisar y arrancar FreeRADIUS"
if freeradius -XC > /tmp/freeradius-check.txt 2>&1; then
  echo "FreeRADIUS: configuracion OK"
  systemctl restart freeradius
  systemctl enable freeradius >/dev/null 2>&1
else
  echo "FreeRADIUS: ERROR. Ultimas lineas de /tmp/freeradius-check.txt:"
  tail -15 /tmp/freeradius-check.txt
fi

paso "9 Hora, registros y monitoreo"
echo 'server srv-bd.proyecto.local iburst prefer' > /etc/chrony/sources.d/proyecto.sources
systemctl restart chrony
echo '*.* @srv-bd.proyecto.local:514' > /etc/rsyslog.d/90-remoto.conf
systemctl restart rsyslog
sed -i "s/^Server=.*/Server=monitoreo.proyecto.local/; s/^ServerActive=.*/ServerActive=monitoreo.proyecto.local/; s/^Hostname=.*/Hostname=srv-aaa-1/" /etc/zabbix/zabbix_agentd.conf
systemctl enable zabbix-agent >/dev/null 2>&1
systemctl restart zabbix-agent

paso "10 SSH sin root"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart ssh

paso "11 Firewall (reglas del laboratorio + dos de casa)"
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow in on tailscale0
ufw allow from 192.168.10.0/24 to any port 22 proto tcp
for ip in 192.168.40.2 192.168.40.3 192.168.50.0/24; do
  ufw allow from $ip to any port 1812,1813 proto udp
done
ufw allow from 192.168.40.20 to any port 10050 proto tcp
sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw
ufw --force enable

paso "12 Red del laboratorio (solo se guarda, no se aplica)"
cat > /root/proyecto/interfaces.lab <<'EOF'
auto lo
iface lo inet loopback

auto enp8s0
iface enp8s0 inet static
    address 192.168.40.11/24
    gateway 192.168.40.1
    dns-nameservers 192.168.40.10 192.168.40.13
    dns-search proyecto.local
EOF

paso "13 Scripts modo-lab y modo-casa (solo se crean)"
cat > /usr/local/sbin/modo-lab <<'EOF'
#!/bin/bash
# Cambia el servidor a la red del laboratorio. Ejecutar desde el teclado de la laptop.
cp /root/proyecto/interfaces.lab /etc/network/interfaces
sed -i '/# >>> TAILSCALE/,/# <<< TAILSCALE/d' /etc/hosts
ufw delete allow in on tailscale0 >/dev/null 2>&1
ufw delete allow 22/tcp >/dev/null 2>&1
systemctl restart networking
sleep 5
systemctl restart chrony rsyslog freeradius zabbix-agent
echo "== Prueba de red =="
ping -c 2 192.168.40.1
ping -c 2 192.168.40.10
getent hosts srv-bd.proyecto.local
EOF
cat > /usr/local/sbin/modo-casa <<'EOF'
#!/bin/bash
# Regresa a la red de casa con Tailscale
cp /root/proyecto/interfaces.casa /etc/network/interfaces
grep -q '>>> TAILSCALE' /etc/hosts || cat /root/proyecto/hosts-tailscale.txt >> /etc/hosts
ufw allow in on tailscale0
ufw allow 22/tcp
systemctl restart networking
sleep 5
systemctl restart chrony rsyslog freeradius zabbix-agent
ping -c 2 8.8.8.8
EOF
chmod +x /usr/local/sbin/modo-lab /usr/local/sbin/modo-casa

paso "14 Revision final"
for s in freeradius chrony rsyslog zabbix-agent; do printf '%-14s %s\n' "$s" "$(systemctl is-active $s)"; done
ss -ulnp | grep -E ':1812|:1813' && echo "RADIUS escuchando en 1812/1813"
ufw status numbered
echo
echo "LISTO. Pendiente cuando exista SRV-BD: crear las tablas radius y probar con radtest."
