#!/bin/bash
# =====================================================================
#  SRV-CORREO (HP Pavilion g4) - configuracion individual (modo casa)
#  Ejecutar como root:  bash 01-configurar-correo.sh
#  No cambia la red actual. La red del laboratorio queda lista en
#  /root/proyecto/interfaces.lab y se aplica despues con: modo-lab
# =====================================================================

if [ "$(id -u)" -ne 0 ]; then echo "Ejecutar como root (su -)"; exit 1; fi

echo "== Claves del proyecto (no se muestran al escribir) =="
read -rsp "Clave de cn=lector (LDAP): " CLAVE_LECTOR; echo
read -rsp "Clave del usuario roundcube (MariaDB): " CLAVE_BD_ROUNDCUBE; echo

paso() { echo; echo "=================== $1 ==================="; }

paso "A1 Carpeta del proyecto y copia de la red de casa"
mkdir -p /root/proyecto
[ -f /root/proyecto/interfaces.casa ] || cp /etc/network/interfaces /root/proyecto/interfaces.casa

paso "A2 Nombre y zona horaria"
timedatectl set-timezone America/Guayaquil
hostnamectl set-hostname correo
if grep -q '^127.0.1.1' /etc/hosts; then
  sed -i 's/^127.0.1.1.*/127.0.1.1 correo.proyecto.local correo/' /etc/hosts
else
  echo '127.0.1.1 correo.proyecto.local correo' >> /etc/hosts
fi

paso "A3 Marcas para los nombres por Tailscale (vacias por ahora)"
[ -f /root/proyecto/hosts-tailscale.txt ] || printf '# >>> TAILSCALE (solo en casa)\n# <<< TAILSCALE\n' > /root/proyecto/hosts-tailscale.txt
grep -q '>>> TAILSCALE' /etc/hosts || cat /root/proyecto/hosts-tailscale.txt >> /etc/hosts

paso "A4 Usuario de los buzones"
getent group vmail >/dev/null || groupadd -g 5000 vmail
id vmail >/dev/null 2>&1 || useradd -u 5000 -g vmail -s /usr/sbin/nologin -d /var/mail/vhosts -m vmail

paso "A5 Postfix"
postconf -e 'myhostname = correo.proyecto.local'
postconf -e 'mydomain = proyecto.local'
postconf -e 'mydestination = localhost'
postconf -e 'mynetworks = 127.0.0.0/8'
postconf -e 'virtual_mailbox_domains = proyecto.local'
postconf -e 'virtual_mailbox_maps = ldap:/etc/postfix/ldap-usuarios.cf'
postconf -e 'virtual_transport = lmtp:unix:private/dovecot-lmtp'
postconf -e 'smtpd_sasl_type = dovecot'
postconf -e 'smtpd_sasl_path = private/auth'
postconf -M submission/inet="submission inet n - y - - smtpd"
postconf -P "submission/inet/syslog_name=postfix/submission" \
            "submission/inet/smtpd_tls_security_level=encrypt" \
            "submission/inet/smtpd_sasl_auth_enable=yes" \
            "submission/inet/smtpd_recipient_restrictions=permit_sasl_authenticated,reject"

cat > /etc/postfix/ldap-usuarios.cf <<EOF
server_host      = ldap://srv-bd.proyecto.local ldap://srv-bd-replica.proyecto.local
search_base      = ou=personas,dc=proyecto,dc=local
bind             = yes
bind_dn          = cn=lector,dc=proyecto,dc=local
bind_pw          = $CLAVE_LECTOR
query_filter     = (mail=%s)
result_attribute = mail
EOF
chmod 640 /etc/postfix/ldap-usuarios.cf
chgrp postfix /etc/postfix/ldap-usuarios.cf
postfix check && systemctl restart postfix

paso "A6 Dovecot 2.4"
sed -i 's/^!include auth-system.conf.ext/#&/' /etc/dovecot/conf.d/10-auth.conf
cat > /etc/dovecot/local.conf <<EOF
protocols = imap lmtp

mail_driver = maildir
mail_home   = /var/mail/vhosts/%{user | domain}/%{user | username}
mail_path   = ~/Maildir

ldap_uris             = ldap://srv-bd.proyecto.local ldap://srv-bd-replica.proyecto.local
ldap_auth_dn          = cn=lector,dc=proyecto,dc=local
ldap_auth_dn_password = $CLAVE_LECTOR
ldap_base             = ou=personas,dc=proyecto,dc=local

passdb ldap {
  bind   = yes
  filter = (&(objectClass=inetOrgPerson)(mail=%{user}))
}

userdb static {
  fields {
    uid  = vmail
    gid  = vmail
    home = /var/mail/vhosts/%{user | domain}/%{user | username}
  }
}

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode  = 0660
    user  = postfix
    group = postfix
  }
}

service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode  = 0600
    user  = postfix
    group = postfix
  }
}
EOF
chmod 640 /etc/dovecot/local.conf
chgrp dovecot /etc/dovecot/local.conf
if doveconf -n > /dev/null; then echo "dovecot: configuracion OK"; systemctl restart dovecot; else echo "dovecot: ERROR EN LA CONFIGURACION (ver mensaje arriba)"; fi

paso "A7 Roundcube"
if ! grep -q 'PROYECTO-CORREO' /etc/roundcube/config.inc.php; then
cat >> /etc/roundcube/config.inc.php <<EOF

// PROYECTO-CORREO
\$config['db_dsnw'] = 'mysql://roundcube:$CLAVE_BD_ROUNDCUBE@srv-bd.proyecto.local/roundcube';
\$config['imap_host'] = 'ssl://localhost:993';
\$config['smtp_host'] = 'tls://localhost:587';
\$config['smtp_user'] = '%u';
\$config['smtp_pass'] = '%p';
\$config['username_domain'] = 'proyecto.local';
\$config['imap_conn_options'] = ['ssl' => ['verify_peer' => false, 'verify_peer_name' => false]];
\$config['smtp_conn_options'] = ['ssl' => ['verify_peer' => false, 'verify_peer_name' => false]];
EOF
fi
sed -i 's|^\s*#\s*Alias /roundcube|    Alias /roundcube|' /etc/roundcube/apache.conf
grep -n "Alias" /etc/roundcube/apache.conf
a2enconf roundcube >/dev/null
apache2ctl configtest && systemctl reload apache2

paso "A8 Pagina web"
cat > /var/www/html/index.html <<'EOF'
<!doctype html><html lang="es"><meta charset="utf-8"><title>Proyecto</title>
<h1>Red corporativa - Proyecto</h1><p>Servidor web publicado desde la DMZ.</p></html>
EOF

paso "A9 Hora, registros y monitoreo"
echo 'server srv-bd.proyecto.local iburst prefer' > /etc/chrony/sources.d/proyecto.sources
systemctl restart chrony
echo '*.* @srv-bd.proyecto.local:514' > /etc/rsyslog.d/90-remoto.conf
systemctl restart rsyslog
sed -i "s/^Server=.*/Server=monitoreo.proyecto.local/; s/^ServerActive=.*/ServerActive=monitoreo.proyecto.local/; s/^Hostname=.*/Hostname=correo/" /etc/zabbix/zabbix_agentd.conf
systemctl enable zabbix-agent >/dev/null 2>&1
systemctl restart zabbix-agent || echo "zabbix-agent: aviso normal hasta que exista SRV-MONITOREO"

paso "A10 SSH sin root"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart ssh

paso "A11 Firewall (reglas del laboratorio + dos de casa)"
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow in on tailscale0
ufw allow from 192.168.10.0/24 to any port 22 proto tcp
ufw allow 25/tcp
ufw allow 80/tcp
ufw allow from 192.168.0.0/16 to any port 587,993 proto tcp
ufw allow from 192.168.40.20 to any port 10050 proto tcp
ufw --force enable

paso "A12 Red del laboratorio (solo se guarda, no se aplica)"
cat > /root/proyecto/interfaces.lab <<'EOF'
auto lo
iface lo inet loopback

auto eno1
iface eno1 inet static
    address 192.168.60.10/24
    gateway 192.168.60.1
    dns-nameservers 192.168.40.10 192.168.40.13
    dns-search proyecto.local
EOF

paso "A13 Scripts modo-lab y modo-casa (solo se crean)"
cat > /usr/local/sbin/modo-lab <<'EOF'
#!/bin/bash
# Cambia el servidor a la red del laboratorio. Ejecutar desde el teclado de la laptop.
cp /root/proyecto/interfaces.lab /etc/network/interfaces
sed -i '/# >>> TAILSCALE/,/# <<< TAILSCALE/d' /etc/hosts
ufw delete allow in on tailscale0 >/dev/null 2>&1
ufw delete allow 22/tcp >/dev/null 2>&1
systemctl restart networking
sleep 5
systemctl restart chrony rsyslog postfix dovecot apache2 zabbix-agent
echo "== Prueba de red =="
ping -c 2 192.168.60.1
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
systemctl restart chrony rsyslog postfix dovecot apache2 zabbix-agent
ping -c 2 8.8.8.8
EOF
chmod +x /usr/local/sbin/modo-lab /usr/local/sbin/modo-casa

paso "A14 Revision final"
postfix check && echo "postfix: OK"
doveconf -n > /dev/null && echo "dovecot: OK"
apache2ctl configtest
for s in postfix dovecot apache2 chrony rsyslog zabbix-agent; do printf '%-14s %s\n' "$s" "$(systemctl is-active $s)"; done
ufw status numbered
swaks --to prueba@localhost --server 127.0.0.1 --quit-after RCPT >/dev/null 2>&1 && echo "SMTP local: responde"
echo
echo "LISTO. Pendiente: A15 (pruebas con SRV-BD por Tailscale) y modo-lab en el laboratorio."
