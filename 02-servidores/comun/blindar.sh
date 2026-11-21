#!/bin/bash
# =====================================================================
#  BLINDAR SERVIDOR - Centro Educativo Mejoland  (ejecutar en los 7 servidores, root)
#
#  Capas que instala (cada una con respaldo y vuelta atras):
#   1. Nucleo: proteccion contra inundacion de SYN, ping y direcciones falsas.
#   2. Cortafuegos (ufw) en los servidores que no lo tenian, con red de seguridad para no perder el SSH.
#   3. ESCUDO anti-DDoS: limite por IP de conexiones y rafagas; quien se pasa queda bloqueado 10 min.
#   4. fail2ban: bloquea a quien falla la clave varias veces (SSH y, en el correo, SMTP/IMAP).
#   5. SSH: sin entrada directa de root, menos intentos.
#   6. Apache: corta conexiones lentas (ataque tipo slowloris) y oculta la version.
#   7. Correo: limites de conexiones por cliente en Postfix.
#  Los servidores del proyecto estan exentos entre si (replica, alta disponibilidad, Zabbix, proxy).
#
#  Uso:        bash blindar.sh
#  Despues:    escudo estado | escudo off | escudo on | escudo permitir IP | escudo quitar IP | escudo desbloquear IP
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root (sudo -i)"; exit 1; }
H=$(hostname -s | tr 'A-Z' 'a-z')
case "$H" in
  srv-bd) ROL=srv-bd;; damian*) ROL=damian;; correo*) ROL=correo;; srv-aaa-1) ROL=srv-aaa-1;; srv-aaa-2) ROL=srv-aaa-2;;
  srv-monitoreo) ROL=srv-monitoreo;; srv-apps) ROL=srv-apps;; *) echo "No reconozco este equipo ($H)."; exit 1;;
esac
E=/etc/mejoland; mkdir -p $E
BK=/root/proyecto/antes-de-blindar-$(date +%Y%m%d-%H%M%S); mkdir -p $BK; chmod 700 $BK
paso() { echo; echo "== $*"; }
ok()   { echo "  [OK] $*"; }
av()   { echo "  [AVISO] $*"; }
resp() { for f in "$@"; do [ -e "$f" ] && { mkdir -p "$BK$(dirname "$f")"; cp -a "$f" "$BK$f"; }; done; }
echo "################ BLINDAR: $ROL ($H) ################"

# IP de los servidores del proyecto (Tailscale y laboratorio): nunca se limitan ni se bloquean entre si
SERVIDORES="127.0.0.1 100.89.203.22 100.93.52.67 100.65.119.48 100.75.163.23 100.74.49.76 100.123.222.5 100.107.96.3
192.168.40.10 192.168.40.13 192.168.60.10 192.168.40.11 192.168.40.12 192.168.40.20 192.168.40.21 192.168.40.100"

paso "0 Paquetes"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq ufw nftables fail2ban python3-systemd >/dev/null 2>&1
for c in ufw nft fail2ban-client; do command -v $c >/dev/null && ok "$c" || av "falta $c"; done
systemctl disable --now nftables >/dev/null 2>&1   # su archivo por defecto borraria las reglas de ufw y Tailscale

# ---------------------------------------------------------------------
paso "1 Nucleo: inundacion de SYN, ping y direcciones falsas"
cat > /etc/sysctl.d/90-mejoland-escudo.conf <<'EOF'
# Centro Educativo Mejoland - proteccion de red (blindar.sh)
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.core.somaxconn = 4096
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_rfc1337 = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
-net.netfilter.nf_conntrack_max = 262144
-net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 20
EOF
sysctl --system >/dev/null 2>&1
ok "syncookies=$(sysctl -n net.ipv4.tcp_syncookies)  cola SYN=$(sysctl -n net.ipv4.tcp_max_syn_backlog)  ping a difusion ignorado=$(sysctl -n net.ipv4.icmp_echo_ignore_broadcasts)"

# ---------------------------------------------------------------------
paso "2 Cortafuegos (ufw)"
r() { ufw "$@" >/dev/null 2>&1; }
reglas_rol() {
  r allow in on tailscale0                       # acceso de administracion por Tailscale
  r allow 41641/udp                              # conexion directa de Tailscale
  r limit 22/tcp                                 # SSH (con limite de intentos)
  r allow from 192.168.40.20 to any port 10050 proto tcp      # agente Zabbix (laboratorio)
  case $ROL in
    damian)
      r allow from 192.168.0.0/16 to any port 53; r allow 67/udp
      r allow from 192.168.0.0/16 to any port 80,3001 proto tcp
      for o in 192.168.40.0/24 192.168.60.10; do r allow from $o to any port 389,3306 proto tcp; done ;;
    srv-apps)      r allow from 192.168.0.0/16 to any port 80 proto tcp ;;
    srv-monitoreo) r allow from 192.168.0.0/16 to any port 80,10051 proto tcp ;;
    srv-aaa-1|srv-aaa-2) r allow from 192.168.0.0/16 to any port 1812,1813 proto udp ;;
  esac
}
if ufw status 2>/dev/null | grep -q "Status: active"; then
  ok "ya estaba activo: no se tocan sus reglas ($(ufw status | grep -c ALLOW) permisos)"
  r allow in on tailscale0; r allow 41641/udp
else
  resp /etc/ufw/user.rules /etc/ufw/user6.rules /etc/default/ufw
  r default deny incoming; r default allow outgoing
  reglas_rol
  # Proteccion: si se pierde el acceso SSH al activarlo, se desactiva solo en 3 minutos
  systemctl stop mejoland-ufw-seguro.timer mejoland-ufw-seguro.service >/dev/null 2>&1; systemctl reset-failed mejoland-ufw-seguro.service >/dev/null 2>&1
  systemd-run --quiet --on-active=180 --unit=mejoland-ufw-seguro /usr/sbin/ufw disable
  ufw --force enable >/dev/null 2>&1
  echo "  Cortafuegos activado. Si lees esto y puedes escribir, tu conexion sigue viva."
  resp_usuario=""
  # Descarta la entrada pendiente y lee la confirmacion desde el teclado
  while read -r -t 0.2 -n 10000 _ </dev/tty 2>/dev/null; do :; done
  read -r -t 150 -p "  Escribe OK y pulsa Enter para dejarlo activo (si no, se apaga solo en 3 min): " resp_usuario </dev/tty || true
  if [ "$(echo "$resp_usuario" | tr 'a-z' 'A-Z')" = OK ]; then
    systemctl stop mejoland-ufw-seguro.timer >/dev/null 2>&1; ok "cortafuegos activo y permanente"
  else
    ufw disable >/dev/null 2>&1; systemctl stop mejoland-ufw-seguro.timer >/dev/null 2>&1; av "no confirmaste: cortafuegos apagado. Vuelve a ejecutar el script."
  fi
fi
ufw status 2>/dev/null | sed -n '1,4p' | sed 's/^/  /'

# ---------------------------------------------------------------------
paso "3 ESCUDO anti-DDoS (limites por IP)"
[ -f $E/escudo-permitidos.txt ] || : > $E/escudo-permitidos.txt
echo "$SERVIDORES" | tr ' ' '\n' | grep . > $E/escudo-servidores.txt
cat > /usr/local/sbin/escudo <<'EOF'
#!/bin/bash
# ESCUDO anti-DDoS del Centro Educativo Mejoland (tabla nftables propia: no toca ufw ni Tailscale)
#   escudo estado            que esta bloqueando y cuanto ha descartado
#   escudo on | off          encender / apagar (off = sin limites, p. ej. para una prueba de carga)
#   escudo permitir IP       esa IP no tiene limites (maquina de la prueba de esfuerzo)
#   escudo quitar IP         vuelve a tener limites
#   escudo desbloquear IP    saca una IP de la lista de bloqueadas (o 'todas')
E=/etc/mejoland; T="inet mejoland_escudo"
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
lista() { grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' "$1" 2>/dev/null | sort -u | paste -sd, -; }
generar() {
  local S P; S=$(lista $E/escudo-servidores.txt); P=$(lista $E/escudo-permitidos.txt)
  local PE=""; [ -n "$P" ] && PE="elements = { $P }"
  cat <<NFT
table $T
delete table $T
table $T {
  set servidores { type ipv4_addr; elements = { ${S:-127.0.0.1} } }
  set permitidos { type ipv4_addr; flags interval; $PE }
  set bloqueados { type ipv4_addr; flags dynamic,timeout; timeout 10m; size 65535; }
  set c_web    { type ipv4_addr; flags dynamic; size 65535; }
  set c_correo { type ipv4_addr; flags dynamic; size 65535; }
  set r_web    { type ipv4_addr; flags dynamic,timeout; timeout 1m; size 65535; }
  set r_ssh    { type ipv4_addr; flags dynamic,timeout; timeout 2m; size 65535; }
  set r_icmp   { type ipv4_addr; flags dynamic,timeout; timeout 1m; size 65535; }
  set r_dns    { type ipv4_addr; flags dynamic,timeout; timeout 1m; size 65535; }
  chain entrada {
    type filter hook input priority -5; policy accept;
    iif "lo" accept
    ip saddr @servidores accept
    ip saddr @permitidos accept
    ip saddr @bloqueados counter drop comment "IP bloqueadas (10 min)"
    ct state invalid counter drop comment "paquetes invalidos"
    ct state established,related accept
    icmp type echo-request add @r_icmp { ip saddr limit rate over 20/second burst 40 packets } counter drop comment "inundacion de ping"
    tcp dport { 80, 443, 3000, 3001 } ct state new add @c_web { ip saddr ct count over 300 } add @bloqueados { ip saddr } log prefix "ESCUDO-MEJOLAND bloqueo: " counter drop comment "mas de 300 conexiones web de una IP (bloqueo)"
    tcp dport { 80, 443, 3000, 3001 } ct state new add @r_web { ip saddr limit rate over 200/second burst 400 packets } counter drop comment "rafaga de conexiones web"
    tcp dport { 25, 143, 587, 993 } ct state new add @c_correo { ip saddr ct count over 60 } counter drop comment "mas de 60 conexiones de correo de una IP"
    tcp dport 22 ct state new add @r_ssh { ip saddr limit rate over 30/minute burst 30 packets } counter drop comment "rafaga de SSH"
    udp dport 53 add @r_dns { ip saddr limit rate over 200/second burst 400 packets } counter drop comment "inundacion de DNS"
  }
}
NFT
}
encender() { generar > $E/escudo.nft && nft -f $E/escudo.nft; }
case "${1:-estado}" in
  on)  encender && systemctl enable mejoland-escudo >/dev/null 2>&1 && echo "Escudo ENCENDIDO" ;;
  off) nft delete table $T 2>/dev/null; systemctl disable mejoland-escudo >/dev/null 2>&1; echo "Escudo APAGADO (sin limites por IP; el cortafuegos sigue activo)" ;;
  recargar) encender ;;
  permitir) [ -n "${2:-}" ] || { echo "Uso: escudo permitir IP"; exit 1; }
    echo "$2" >> $E/escudo-permitidos.txt; nft list table $T >/dev/null 2>&1 && encender; echo "$2 sin limites" ;;
  quitar) [ -n "${2:-}" ] || { echo "Uso: escudo quitar IP"; exit 1; }
    grep -vxF "$2" $E/escudo-permitidos.txt > $E/.p; mv $E/.p $E/escudo-permitidos.txt; nft list table $T >/dev/null 2>&1 && encender; echo "$2 vuelve a tener limites" ;;
  desbloquear)
    if [ "${2:-}" = todas ]; then nft flush set $T bloqueados && echo "Lista de bloqueadas vaciada"
    else nft delete element $T bloqueados "{ ${2:-} }" && echo "${2:-} desbloqueada"; fi ;;
  estado)
    if nft list table $T >/dev/null 2>&1; then echo "Escudo: ENCENDIDO"; else echo "Escudo: APAGADO"; exit 0; fi
    echo "Descartado por regla (paquetes):"
    nft list chain $T entrada | sed -n 's/.*counter packets \([0-9]*\) bytes [0-9]* drop comment "\(.*\)"/  \1\t\2/p'
    B=$(nft list set $T bloqueados | tr ',' '\n' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ (timeout [^ ]+ )?expires [^ ,}]+' | sed 's/timeout [^ ]* //')
    echo "IP bloqueadas ahora: $(echo "$B" | grep -c .)"; [ -n "$B" ] && echo "$B" | sed 's/^/  /'
    echo "Sin limites (permitidas): $(lista $E/escudo-permitidos.txt)"
    command -v fail2ban-client >/dev/null && fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:/fail2ban vigila:/p'
    for j in $(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:\s*//p' | tr -d ','); do
      echo "  $j: $(fail2ban-client status $j 2>/dev/null | sed -n 's/.*Currently banned:\s*//p') bloqueada(s) por claves fallidas"; done ;;
  *) sed -n '3,8p' "$0" ;;
esac
EOF
chmod 755 /usr/local/sbin/escudo
cat > /etc/systemd/system/mejoland-escudo.service <<'EOF'
[Unit]
Description=Escudo anti-DDoS del Centro Educativo Mejoland (limites por IP)
After=network-pre.target ufw.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/escudo recargar
ExecStop=/usr/sbin/nft delete table inet mejoland_escudo
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
if escudo on >/dev/null 2>&1 && nft list table inet mejoland_escudo >/dev/null 2>&1; then ok "escudo encendido (y arranca solo al iniciar)"
else av "no se pudo cargar el escudo:"; escudo recargar 2>&1 | tail -3; fi

# ---------------------------------------------------------------------
paso "4 fail2ban: bloqueo por claves fallidas"
IGN="127.0.0.1/8 ::1 $(echo $SERVIDORES)"
jaula() {   # $1 = jaulas adicionales (texto)
  cat > /etc/fail2ban/jail.d/mejoland.conf <<EOF
# Centro Educativo Mejoland (blindar.sh)
[DEFAULT]
ignoreip = $IGN
bantime  = 10m
findtime = 10m
maxretry = 6

[sshd]
enabled = true
backend = systemd
# Debian 13: los intentos los registra "sshd-session", no "sshd"; se lee todo el servicio ssh
journalmatch = _SYSTEMD_UNIT=ssh.service
$1
EOF
}
EXTRA=""
if [ "$ROL" = correo ]; then
  EXTRA="
[postfix]
enabled = true
mode    = aggressive
backend = systemd

[dovecot]
enabled = true
backend = systemd
"
fi
resp /etc/fail2ban/jail.d/mejoland.conf
jaula "$EXTRA"
if ! fail2ban-client -t >/dev/null 2>&1; then av "las jaulas del correo no cargan aqui: dejo solo SSH"; jaula ""; fi
if fail2ban-client -t >/dev/null 2>&1; then
  systemctl enable fail2ban >/dev/null 2>&1; systemctl restart fail2ban; sleep 3
  ok "$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:\s*/vigilando: /p')  (6 fallos en 10 min = 10 min bloqueado)"
else av "fail2ban no valida su configuracion:"; fail2ban-client -t 2>&1 | tail -3; rm -f /etc/fail2ban/jail.d/mejoland.conf; fi

# ---------------------------------------------------------------------
paso "5 SSH"
if [ -d /etc/ssh/sshd_config.d ] && grep -q '^Include /etc/ssh/sshd_config.d' /etc/ssh/sshd_config 2>/dev/null; then
  cat > /etc/ssh/sshd_config.d/90-mejoland.conf <<'EOF'
# Centro Educativo Mejoland (blindar.sh)
PermitRootLogin no
MaxAuthTries 4
LoginGraceTime 30
MaxStartups 10:30:60
X11Forwarding no
PermitEmptyPasswords no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
  if sshd -t 2>/dev/null; then systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
    ok "root no entra directo por SSH (se entra con tu usuario y luego su - / sudo -i); 4 intentos por conexion"
  else rm -f /etc/ssh/sshd_config.d/90-mejoland.conf; av "sshd no acepto los cambios: se dejaron como estaban"; fi
else av "este sshd no usa sshd_config.d: sin cambios"; fi

# ---------------------------------------------------------------------
if command -v apache2ctl >/dev/null 2>&1; then
  paso "6 Apache: conexiones lentas y version oculta"
  cat > /etc/apache2/conf-available/mejoland-escudo.conf <<'EOF'
# Centro Educativo Mejoland (blindar.sh)
ServerTokens Prod
ServerSignature Off
TraceEnable Off
Timeout 60
KeepAliveTimeout 3
MaxKeepAliveRequests 200
<IfModule reqtimeout_module>
    # Quien abre la conexion y no envia la peticion completa a tiempo, se corta (slowloris)
    RequestReadTimeout handshake=5-10,MinRate=500 header=10-20,MinRate=500 body=20,MinRate=500
</IfModule>
EOF
  a2enmod -q reqtimeout >/dev/null 2>&1; a2enconf -q mejoland-escudo >/dev/null 2>&1
  if apache2ctl configtest >/dev/null 2>&1; then systemctl reload apache2 && ok "limites de tiempo activos"
  else a2disconf -q mejoland-escudo >/dev/null 2>&1; systemctl reload apache2; av "Apache no acepto la configuracion: retirada"; fi
fi

# ---------------------------------------------------------------------
if [ "$ROL" = correo ] && command -v postconf >/dev/null 2>&1; then
  paso "7 Postfix: limites por cliente"
  resp /etc/postfix/main.cf
  postconf -e "smtpd_client_connection_count_limit=20" "smtpd_client_connection_rate_limit=60" \
              "smtpd_client_message_rate_limit=100" "anvil_rate_time_unit=60s" "smtpd_error_sleep_time=2s" \
              "smtpd_soft_error_limit=5" "smtpd_hard_error_limit=10"
  postfix check 2>/dev/null && systemctl reload postfix && ok "maximo 20 conexiones y 60 conexiones/min por cliente (la red propia esta exenta)"
fi

# ---------------------------------------------------------------------
paso "Resumen"
ufw status 2>/dev/null | head -1 | sed 's/^/  Cortafuegos: /'
escudo estado | sed 's/^/  /'
echo "  Puertos abiertos al exterior: $(ss -tulnH 2>/dev/null | awk '$5 !~ /^(127\.|\[::1\])/ {n=split($5,a,":"); print a[n]}' | sort -un | paste -sd' ' -)"
echo; echo "LISTO en $ROL. Respaldo: $BK"
echo "Para la prueba de esfuerzo: 'escudo permitir IP_DE_LA_MAQUINA' (o 'escudo off' mientras dure)."
