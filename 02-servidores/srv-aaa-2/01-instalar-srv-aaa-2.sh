#!/bin/bash
# =====================================================================
#  MAC - PASO 2 (srv-aaa-2, root): RADIUS secundario, copia exacta de SRV-AAA-1
#  - Nombres de Tailscale en /etc/hosts (mismo esquema que los demas servidores)
#  - FreeRADIUS con la configuracion de AAA-1: clientes, LDAP (srv-bd y replica),
#    SQL (base radius en SRV-BD), EAP-TTLS para el Wi-Fi
#  - Hora (chrony) y registros (rsyslog) hacia SRV-BD
#  Antes: /tmp/radius-conf.tgz (copia de /etc/freeradius de AAA-1)
#  Uso:  bash 01-instalar-srv-aaa-2.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
[ -f /tmp/radius-conf.tgz ] || { echo "Falta /tmp/radius-conf.tgz (copialo desde srv-aaa-1)"; exit 1; }
paso() { echo; echo "=================== $1 ==================="; }
BK=/root/proyecto/aaa2-$(date +%Y%m%d-%H%M); mkdir -p $BK; chmod 700 $BK

paso "1 Nombres (Tailscale)"
cp -a /etc/hosts $BK/hosts
sed -i '/# >>> TAILSCALE/,/# <<< TAILSCALE/d' /etc/hosts
cat >> /etc/hosts <<'H'
# >>> TAILSCALE (solo en casa)
100.89.203.22   srv-bd.proyecto.local srv-bd
100.93.52.67    srv-bd-replica.proyecto.local srv-bd-replica
100.65.119.48   correo.proyecto.local correo
100.75.163.23   srv-aaa-1.proyecto.local srv-aaa-1
# <<< TAILSCALE
H
for h in srv-bd srv-bd-replica; do timeout 3 bash -c "</dev/tcp/$h/389" 2>/dev/null && echo "  LDAP $h: OK" || echo "  LDAP $h: NO RESPONDE"; done

paso "2 Paquetes"
DEBIAN_FRONTEND=noninteractive apt-get install -y -q freeradius freeradius-ldap freeradius-mysql freeradius-utils ldap-utils chrony rsyslog >/dev/null \
  || { echo "ERROR instalando paquetes"; exit 1; }
echo "  $(freeradius -v | head -1)"

paso "3 Configuracion de SRV-AAA-1"
systemctl stop freeradius
tar -C /etc -czf $BK/freeradius-original.tgz freeradius
rm -rf /etc/freeradius; tar -C /etc -xzf /tmp/radius-conf.tgz
chown -R freerad:freerad /etc/freeradius
if ! freeradius -XC >/tmp/rad-check.log 2>&1; then
  echo "  ERROR en la configuracion copiada (ver /tmp/rad-check.log). Restaurando la original."
  rm -rf /etc/freeradius; tar -C /etc -xzf $BK/freeradius-original.tgz; exit 1
fi
echo "  freeradius -XC: configuracion valida"
systemctl enable --now freeradius >/dev/null 2>&1; sleep 2
echo "  freeradius: $(systemctl is-active freeradius)   puertos: $(ss -ulnH | awk '{print $4}' | grep -E ':181[23]$' | tr '\n' ' ')"
shred -u /tmp/radius-conf.tgz 2>/dev/null || rm -f /tmp/radius-conf.tgz

paso "4 Hora y registros hacia SRV-BD"
echo "server srv-bd.proyecto.local iburst" > /etc/chrony/conf.d/srv-bd.conf; systemctl restart chrony
echo '*.* @srv-bd.proyecto.local:514' > /etc/rsyslog.d/90-srv-bd.conf; systemctl restart rsyslog
echo "  chrony y rsyslog apuntan a srv-bd"

paso "5 Prueba (radtest)"
SEC=$(awk '/^[[:space:]]*client[[:space:]]+localhost[[:space:]]*\{/{f=1} f&&/^[[:space:]]*secret[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/,""); gsub(/["[:space:]]/,""); print; exit} f&&/^[[:space:]]*}/{f=0}' /etc/freeradius/3.0/clients.conf)
read -rp "  Usuario de prueba (ej. acabezas): " U
read -rsp "  Su clave: " P; echo
radtest -t pap "$U" "$P" 127.0.0.1 0 "$SEC" 2>&1 | grep -E "Access-(Accept|Reject)|Cisco-AVPair|no response" | sed 's/^/  /'
unset P SEC
echo
echo "LISTO. SRV-AAA-2 es el RADIUS secundario. Original guardado en $BK"
echo "En el laboratorio: agregar 192.168.40.12 como segundo servidor RADIUS en R1, R2, switches y AP."
