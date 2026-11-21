#!/bin/bash
# =====================================================================
#  RECOLECTAR CONFIGURACION - Centro Educativo Mejoland   (root, en cada uno de los 7 servidores)
#  Solo lectura. Reune en un archivo la configuracion activa del servidor,
#  con las claves eliminadas, para documentar hardware, red, servicios y seguridad.
#  Resultado: /root/final-<servidor>-<fecha>.tar.gz
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root (sudo -i)"; exit 1; }
H=$(hostname -s | tr 'A-Z' 'a-z'); F=$(date +%Y%m%d-%H%M)
D=/root/final-$H-$F; mkdir -p $D/sistema $D/archivos; chmod 700 $D
echo "################ RECOLECTAR VERSION FINAL: $H ################"
c() { local f=$1; shift; { echo "# $*"; "$@" 2>&1; } > "$D/sistema/$f.txt"; }

echo "== 1 Hardware y sistema"
c 01-equipo        hostnamectl
c 02-modelo        bash -c 'dmidecode -t system -t baseboard 2>/dev/null | grep -E "Manufacturer|Product Name|Version|Serial" | grep -v Serial'
c 03-cpu           lscpu
c 04-memoria       free -h
c 05-discos        lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL
c 06-espacio       df -h -x tmpfs -x devtmpfs
c 07-red-hardware  bash -c 'lspci -nnk 2>/dev/null | grep -iA3 "ethernet\|network"; lsusb 2>/dev/null'
c 08-sistema       bash -c 'cat /etc/os-release; uname -r; uptime'
c 09-velocidad     bash -c 'for i in /sys/class/net/*; do n=$(basename $i); [ -e $i/device ] || [ "${n#enx}" != "$n" ] || continue; echo "$n: $(cat $i/speed 2>/dev/null) Mbps, enlace=$(cat $i/carrier 2>/dev/null)"; done'
echo "== 2 Red"
c 10-ip            ip -4 addr
c 11-rutas         ip route
c 12-modo          bash -c 'cat /etc/mejoland/modo 2>/dev/null; modo-red 2>/dev/null'
c 13-tailscale     bash -c 'tailscale ip -4 2>/dev/null; tailscale status 2>/dev/null | head -20'
c 14-dns           bash -c 'cat /etc/resolv.conf; for n in srv-bd correo srv-apps srv-monitoreo mejoland.edu.ec; do getent hosts $n.proyecto.local $n | head -1; done'
echo "== 3 Servicios, puertos y seguridad"
c 20-servicios     systemctl list-units --type=service --state=running --no-pager --no-legend
c 21-temporizadores systemctl list-timers --all --no-pager
c 22-puertos       ss -tlnup
c 23-ufw           ufw status verbose
c 24-nftables      nft list ruleset
c 25-fail2ban      bash -c 'fail2ban-client status 2>/dev/null'
c 26-paquetes      bash -c "dpkg-query -W -f='\${Package} \${Version}\n' 2>/dev/null | grep -E '^(apache2|nginx|mariadb-server|slapd|bind9|kea|postfix|dovecot-core|roundcube|freeradius|zabbix|php8|nodejs|cups|samba|chrony|rsyslog|fail2ban|ufw|nftables|tailscale|openssh-server|glpi|redis)'"
c 27-cron          bash -c 'crontab -l 2>/dev/null; ls -la /etc/cron.d/ 2>/dev/null; cat /etc/cron.d/* 2>/dev/null'
c 28-mejoland-ha   bash -c '/usr/local/sbin/mejoland-ha estado 2>/dev/null'
c 29-bd            bash -c 'mariadb -N -e "SELECT @@version; SHOW DATABASES; SELECT User,Host FROM mysql.user ORDER BY User" 2>/dev/null; mariadb -e "SHOW SLAVE STATUS\G" 2>/dev/null | grep -E "Master_Host|Running:|Gtid|Seconds_Behind"'
c 30-ldap          bash -c 'ldapsearch -x -LLL -H ldap://127.0.0.1 -b dc=proyecto,dc=local "(|(objectClass=organizationalUnit)(objectClass=posixGroup)(objectClass=groupOfNames))" dn cn member memberUid 2>/dev/null | head -200'

echo "== 4 Archivos de configuracion (claves borradas)"
for p in /etc/network/interfaces /etc/hosts /etc/ssh/sshd_config /etc/ssh/sshd_config.d /etc/sysctl.d /etc/fail2ban/jail.local /etc/fail2ban/jail.d \
         /etc/mejoland /etc/mejoland-ha /usr/local/sbin /etc/edunova /var/www/lms-backend/server.js /var/www/lms-backend/.env /var/www/lms-backend/package.json \
         /etc/bind /etc/kea /etc/chrony /etc/rsyslog.d /etc/ldap/ldap.conf /etc/mysql/mariadb.conf.d /etc/apache2/sites-available /etc/apache2/conf-available \
         /etc/postfix/main.cf /etc/postfix/master.cf /etc/postfix/ldap /etc/dovecot/conf.d /etc/dovecot/dovecot-ldap.conf.ext /etc/roundcube/config.inc.php \
         /etc/freeradius/3.0/clients.conf /etc/freeradius/3.0/mods-enabled /etc/freeradius/3.0/sites-enabled /etc/freeradius/3.0/users \
         /etc/zabbix /etc/cups/cupsd.conf /etc/samba/smb.conf /var/www/nextcloud/config/config.php /var/www/glpi/config /etc/glpi \
         /etc/systemd/system/lms.service /etc/systemd/system/mejoland-ha.service /etc/systemd/system/mejoland-ha.timer /etc/systemd/system/print-api.service; do
  [ -e "$p" ] || continue
  # sin llaves privadas, certificados, sesiones ni copias pesadas
  tar -C / --exclude='*.key' --exclude='*.pem' --exclude='*.crt' --exclude='*.p12' --exclude='*token*' --exclude='*.db' \
      --exclude='node_modules' --exclude='sessions' --exclude='*.jnl' -cf - "${p#/}" 2>/dev/null | tar -C $D/archivos -xf - 2>/dev/null
done
# slapd: configuracion sin las claves del administrador
slapcat -n 0 2>/dev/null > $D/archivos/slapd-config.ldif
python3 - "$D" <<'PY'
import os, re, sys
D = sys.argv[1]
clave = re.compile(r'(?i)^(\s*[#;]?\s*[\w.\-\[\]\'"$]*(pass(word|wd)?|secret|token|clave|bind_?pw|bindpw|credentials|des_key|apikey|api_key|rootpw|olcRootPW|DBPassword|PSK)[\w.\-\[\]\'"]*\s*(=>|=|:|\s)\s*)(.+)$')
n = 0
for raiz, _, archivos in os.walk(D):
    for a in archivos:
        f = os.path.join(raiz, a)
        try: s = open(f, encoding='utf-8').read()
        except Exception: continue
        lineas = []
        for l in s.splitlines():
            m = clave.match(l)
            if m and not re.match(r'(?i).*(pass(word)?_?(min|max|len|length|attempts|retries|hash|scheme|method)|passdb|password_query|userdb|PasswordAuthentication|PermitEmptyPasswords|login_rate)', l):
                l = m.group(1) + '***BORRADO***'; n += 1
            l2 = re.sub(r'(://[^:/@\s]+:)[^@\s]+@', r'\1***BORRADO***@', l)
            if l2 != l: l = l2; n += 1
            lineas.append(l)
        open(f, 'w', encoding='utf-8').write('\n'.join(lineas) + '\n')
print(f"  [OK] {n} lineas con claves borradas")
PY
tar -C /root -czf $D.tar.gz $(basename $D) && rm -rf $D
chmod 600 $D.tar.gz
echo
echo "LISTO: $D.tar.gz  ($(du -h $D.tar.gz | cut -f1))"
echo "Revisar el contenido antes de compartirlo:  tar -tzf $D.tar.gz | less"
