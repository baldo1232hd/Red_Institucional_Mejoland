#!/bin/bash
# =====================================================================
#  VERIFICAR LABORATORIO (Centro Educativo Mejoland) - solo lectura.
#  Ejecutar en cualquier servidor despues de modo-lab:   verificar-lab
#  Tiene en cuenta los equipos que van por Tailscale (REMOTOS en /etc/mejoland/red/lab.conf).
# =====================================================================
. /etc/mejoland/red/funciones.sh 2>/dev/null || { echo "Falta preparar-lab / corregir-modos en este equipo"; exit 1; }
B=0; M=0
si() { echo "  [OK]    $*"; B=$((B+1)); }
no() { echo "  [FALLA] $*"; M=$((M+1)); }
prueba() { local d=$1; shift; if "$@" >/dev/null 2>&1; then si "$d"; else no "$d"; fi; }
puerto() { timeout 3 bash -c "</dev/tcp/$1/$2" 2>/dev/null; }
ipde() { getent hosts "$1.proyecto.local" | awk '{print $1; exit}'; }
web() { curl -sk -o /dev/null -m 10 -w '%{http_code}' --resolve mejoland.edu.ec:443:$1 "https://mejoland.edu.ec/$2"; }
I=$(if_actual)
echo "################ VERIFICAR LABORATORIO: $ROL ($(date '+%F %T')) ################"
echo "== Red";  modo-red | sed 's/^/  /'
if es_remoto; then echo "  (este equipo va por Tailscale: no necesita modo lab)"
else
  [ "$(modo_actual)" = lab ] && si "modo laboratorio" || no "este equipo sigue en modo $(modo_actual) (ejecutar modo-lab)"
  ip -4 -o addr show dev $I | grep -q " $LAB_IP/" && si "$I tiene $LAB_IP" || no "$I no tiene $LAB_IP"
  n=$(ip -4 -o addr show | grep -c " $LAB_IP/"); [ "$n" -le 1 ] && si "$LAB_IP en una sola interfaz" || no "$LAB_IP repetida en $n interfaces"
  [ "$(cat /sys/class/net/$I/carrier 2>/dev/null)" = 1 ] && si "$I con cable (enlace arriba)" || no "$I sin enlace"
  prueba "puerta de enlace HSRP $LAB_GW" ping -c 2 -W 2 $LAB_GW
fi
echo "== DNS (srv-bd y damian deben responder lo mismo)"
for n in srv-bd correo srv-apps srv-monitoreo; do
  a=$(dig +short +time=2 +tries=1 @192.168.40.10 $n.proyecto.local 2>/dev/null | tail -1)
  b=$(dig +short +time=2 +tries=1 @192.168.40.13 $n.proyecto.local 2>/dev/null | tail -1)
  [ -n "$a" ] && [ "$a" = "$b" ] && si "$n.proyecto.local = $a (srv-bd y damian)" || no "$n.proyecto.local: srv-bd='${a:-nada}' damian='${b:-nada}'"
done
for n in mejoland.edu.ec webmail.mejoland.edu.ec glpi.mejoland.edu.ec; do
  a=$(dig +short +time=2 +tries=1 @192.168.40.10 $n 2>/dev/null | tail -1)
  b=$(dig +short +time=2 +tries=1 @192.168.40.13 $n 2>/dev/null | tail -1)
  [ "$a" = 192.168.60.10 ] && [ "$b" = 192.168.60.10 ] && si "$n = 192.168.60.10 (proxy DMZ)" || no "$n: srv-bd='${a:-nada}' damian='${b:-nada}' (esperado 192.168.60.10)"
done
echo "== Servicios entre servidores"
prueba "EduNova en la IP virtual 192.168.40.100:3001" puerto 192.168.40.100 3001
prueba "LDAP srv-bd :389"          puerto 192.168.40.10 389
prueba "LDAP damian :389"          puerto 192.168.40.13 389
prueba "MariaDB srv-bd :3306"      puerto 192.168.40.10 3306
prueba "Correo SMTP :25"           puerto 192.168.60.10 25
prueba "Correo IMAP :993"          puerto 192.168.60.10 993
prueba "Proxy DMZ HTTPS :443"      puerto 192.168.60.10 443
prueba "GLPI/nube srv-apps :80 ($(ipde srv-apps))"            puerto "$(ipde srv-apps)" 80
prueba "Zabbix srv-monitoreo :10051 ($(ipde srv-monitoreo))"  puerto "$(ipde srv-monitoreo)" 10051
prueba "RADIUS srv-aaa-1 (ping)"   ping -c 1 -W 2 192.168.40.11
case " $REMOTOS " in *" srv-aaa-2 "*) echo "  [INFO]  srv-aaa-2 va por Tailscale: los routers solo usan srv-aaa-1 para RADIUS";;
  *) prueba "RADIUS srv-aaa-2 (ping)" ping -c 1 -W 2 192.168.40.12;; esac
case $ROL in
  srv-bd|damian)
    echo "== Alta disponibilidad"
    /usr/local/sbin/mejoland-ha estado 2>/dev/null | head -4 | sed 's/^/  /'
    if systemctl is-active -q mejoland-ha.timer; then si "vigilancia HA activa"
    elif systemctl is-active -q mejoland-ha-espera; then echo "  [ESPERA] HA se reanuda sola cuando el otro servidor responda"
    else no "vigilancia HA en pausa (systemctl start mejoland-ha.timer)"; fi
    ip -4 addr show | grep -q ' 192.168.40.100/' && echo "  IP virtual: la tiene ESTE equipo" || echo "  IP virtual: la tiene el otro servidor"
    python3 -c "import json;[print(s['id'],s.get('url','')) for s in json.load(open('/etc/edunova/servicios.json'))['servicios']]" 2>/dev/null \
      | grep -E '100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|ts\.net' >/dev/null && no "EduNova tiene enlaces a Tailscale (ejecutar modo-actualizar)" || si "enlaces de EduNova del laboratorio"
    if [ "$ROL" = damian ]; then
      S=$(mariadb -e "SHOW SLAVE STATUS\G" 2>/dev/null)
      echo "$S" | grep -q "Slave_IO_Running: Yes" && echo "$S" | grep -q "Slave_SQL_Running: Yes" && si "replica MariaDB Yes/Yes desde $(echo "$S" | awk '/Master_Host/{print $2}')" || no "replica MariaDB detenida"
      c=$(ldapsearch -x -LLL -H ldap://127.0.0.1 -b dc=proyecto,dc=local -s base contextCSN 2>/dev/null | awk '/contextCSN/{print $2}' | head -1)
      p=$(ldapsearch -x -LLL -H ldap://192.168.40.10 -b dc=proyecto,dc=local -s base contextCSN 2>/dev/null | awk '/contextCSN/{print $2}' | head -1)
      [ -n "$c" ] && [ "$c" = "$p" ] && si "replica LDAP al dia" || no "replica LDAP distinta (local $c / srv-bd $p)"
    fi ;;
  correo)
    echo "== Publicacion (proxy de la DMZ)"
    for p in plataforma/ webmail/ glpi/ nube/ zabbix/; do
      c=$(web 127.0.0.1 $p)
      case $c in 200|301|302|303) si "https://mejoland.edu.ec/$p -> $c";; *) no "https://mejoland.edu.ec/$p -> $c";; esac
    done
    grep -q 192.168.40.100 /etc/apache2/conf-available/mejoland-destinos.conf && si "proxy apunta a la IP virtual" || no "proxy no esta en destinos de laboratorio" ;;
esac
echo "== Salida a Internet y VPN"
prueba "ping 8.8.8.8" ping -c 2 -W 3 8.8.8.8
tailscale status >/dev/null 2>&1 && si "Tailscale conectado ($(tailscale ip -4 2>/dev/null))" || no "Tailscale no conectado (sin el no se llega a: ${REMOTOS:-nadie})"
echo; echo "Resultado: $B correctas, $M fallas."
