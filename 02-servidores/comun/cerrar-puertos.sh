#!/bin/bash
# =====================================================================
#  CERRAR PUERTOS - Centro Educativo Mejoland  (ejecutar despues de blindar.sh, root)
#
#  Que un escaneo (nmap) desde estudiantes o desde Internet NO vea los servicios internos:
#   - Tabla nftables propia (no toca las reglas de ufw): cada puerto interno solo acepta
#     conexiones nuevas de quien lo necesita (servidores, administracion, Tailscale).
#   - Los servicios web publicos (80, 443, EduNova, correo) siguen abiertos.
#   - Oculta versiones (SSH, Postfix, Dovecot, DNS) y apaga avahi (mDNS, no se usa en servidores).
#  Nada se desinstala: 'puertos off' lo deja todo como antes.
#
#  Uso:      bash cerrar-puertos.sh
#  Despues:  puertos estado | puertos off | puertos on
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root (sudo -i)"; exit 1; }
H=$(hostname -s | tr 'A-Z' 'a-z')
case "$H" in
  srv-bd) ROL=srv-bd;; damian*) ROL=damian;; correo*) ROL=correo;; srv-aaa-1) ROL=srv-aaa-1;; srv-aaa-2) ROL=srv-aaa-2;;
  srv-monitoreo) ROL=srv-monitoreo;; srv-apps) ROL=srv-apps;; *) echo "No reconozco este equipo ($H)."; exit 1;;
esac
E=/etc/mejoland; mkdir -p $E
BK=/root/proyecto/antes-de-cerrar-puertos-$(date +%Y%m%d-%H%M%S); mkdir -p $BK; chmod 700 $BK
paso() { echo; echo "== $*"; }
ok()   { echo "  [OK] $*"; }
av()   { echo "  [AVISO] $*"; }
resp() { for f in "$@"; do [ -e "$f" ] && { mkdir -p "$BK$(dirname "$f")"; cp -a "$f" "$BK$f"; }; done; }
echo "################ CERRAR PUERTOS: $ROL ($H) ################"

paso "1 Lo que escucha hoy"
ss -tulnpH 2>/dev/null | awk '{split($5,a,":"); p=a[length(a)]; d=$5; sub(":"p"$","",d); match($0,/users:\(\("[^"]+"/); prog=substr($0,RSTART+9,RLENGTH-10);
  donde=(d ~ /^(127\.|\[::1\]|::1)/) ? "solo local" : "toda la red"; print $1, p, prog, donde}' | sort -k2 -n -u | awk '{printf "  %-4s %-6s %-18s %s\n",$1,$2,$3,$4}'

# ---------------------------------------------------------------------
#  Grupos de origen
#  SRV  = servidores del proyecto (Tailscale y laboratorio)
#  ADM  = administracion: VLAN 10 y Tailscale (equipos del equipo de trabajo)
#  RED  = toda la red interna (para DNS, hora, RADIUS)
#  MON  = srv-monitoreo (Zabbix)
SRV="127.0.0.1, 100.89.203.22, 100.93.52.67, 100.65.119.48, 100.75.163.23, 100.74.49.76, 100.123.222.5, 100.107.96.3, 192.168.40.10, 192.168.40.11, 192.168.40.12, 192.168.40.13, 192.168.40.20, 192.168.40.21, 192.168.40.100, 192.168.60.10"
ADM="192.168.10.0/24, 100.64.0.0/10"
RED="192.168.0.0/16, 100.64.0.0/10, 10.0.0.0/8"
MON="127.0.0.1, 192.168.40.20, 100.123.222.5"

# Reglas por servidor:  "proto puertos grupos-permitidos"   (grupos: srv adm red mon doc)
case $ROL in
  srv-bd) REGLAS="
tcp 3306 srv adm
tcp 389,636 srv adm
tcp,udp 137,138,139,445 adm doc srv
tcp 631,8000 srv adm
tcp 3000 adm
tcp 9090,9100,19999,8125,4317,19938 adm mon
udp 8125 adm mon
tcp,udp 514 srv
tcp 953 srv
tcp,udp 53 red
udp 123 red
tcp 10050 mon adm" ;;
  damian) REGLAS="
tcp 3306 srv adm
tcp 389,636 srv adm
tcp 631,8000 srv adm
tcp 953 srv
tcp,udp 53 red
tcp 10050 mon adm" ;;
  correo) REGLAS="
tcp 143 srv adm
tcp 631 srv adm
tcp 10050 mon adm" ;;
  srv-aaa-1|srv-aaa-2) REGLAS="
udp 1812,1813 red
tcp 631 srv adm
tcp 10050 mon adm" ;;
  srv-apps) REGLAS="
tcp 3306,6379 srv
tcp 10050 mon adm" ;;
  srv-monitoreo) REGLAS="
tcp 3306 srv
tcp 10051 srv red
tcp 10050 mon adm" ;;
esac
echo "$REGLAS" | grep . > $E/puertos-reglas.txt
cat > $E/puertos-grupos.txt <<EOF
srv=$SRV
adm=$ADM
red=$RED
mon=$MON
doc=192.168.20.0/24
EOF

paso "2 Comando 'puertos' (tabla nftables propia, reversible)"
cat > /usr/local/sbin/puertos <<'EOF'
#!/bin/bash
# Filtro de puertos internos del Centro Educativo Mejoland (no toca ufw)
#   puertos estado | puertos on | puertos off
E=/etc/mejoland; T="inet mejoland_puertos"
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
generar() {
  echo "table $T"; echo "delete table $T"; echo "table $T {"
  while IFS='=' read -r g v; do echo "  set g_$g { type ipv4_addr; flags interval; auto-merge; elements = { $v } }"; done < $E/puertos-grupos.txt
  echo "  chain entrada {"
  echo "    type filter hook input priority -8; policy accept;"
  echo '    iif "lo" accept'
  echo "    ct state established,related accept"
  while read -r proto puertos grupos; do
    [ -z "$proto" ] && continue
    for g in $grupos; do echo "    ip saddr @g_$g meta l4proto { ${proto//,/, } } th dport { $puertos } accept"; done
    echo "    meta l4proto { ${proto//,/, } } th dport { $puertos } ip version 4 counter drop comment \"$proto $puertos solo para: $grupos\""
  done < $E/puertos-reglas.txt
  echo "  }"; echo "}"
}
case "${1:-estado}" in
  on|recargar) generar > $E/puertos.nft && nft -f $E/puertos.nft && { [ "$1" = on ] && systemctl enable mejoland-puertos >/dev/null 2>&1; echo "Filtro de puertos ENCENDIDO"; } ;;
  off) nft delete table $T 2>/dev/null; systemctl disable mejoland-puertos >/dev/null 2>&1; echo "Filtro de puertos APAGADO (todo como antes)" ;;
  estado)
    nft list table $T >/dev/null 2>&1 || { echo "Filtro de puertos: APAGADO"; exit 0; }
    echo "Filtro de puertos: ENCENDIDO"; echo "Intentos rechazados por regla (paquetes):"
    nft list chain $T entrada | sed -n 's/.*counter packets \([0-9]*\) bytes [0-9]* drop comment "\(.*\)"/  \1\t\2/p' ;;
  *) sed -n '3,4p' "$0" ;;
esac
EOF
chmod 755 /usr/local/sbin/puertos
cat > /etc/systemd/system/mejoland-puertos.service <<'EOF'
[Unit]
Description=Filtro de puertos internos del Centro Educativo Mejoland
After=network-pre.target ufw.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/puertos recargar
ExecStop=/usr/sbin/nft delete table inet mejoland_puertos
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
if /usr/local/sbin/puertos on >/dev/null 2>&1 && nft list table inet mejoland_puertos >/dev/null 2>&1; then
  ok "filtro encendido (y arranca solo al iniciar)"
  sed 's/^/      /' $E/puertos-reglas.txt | sed 's/ \([a-z ]*\)$/  -> solo: \1/'
else av "no se pudo cargar el filtro:"; /usr/local/sbin/puertos recargar 2>&1 | tail -5; fi

# ---------------------------------------------------------------------
paso "3 Ocultar versiones (lo que muestra un escaneo)"
if [ -d /etc/ssh/sshd_config.d ]; then
  echo "DebianBanner no" > /etc/ssh/sshd_config.d/91-mejoland-version.conf
  sshd -t 2>/dev/null && { systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; ok "SSH ya no muestra la version de Debian"; } || rm -f /etc/ssh/sshd_config.d/91-mejoland-version.conf
fi
if command -v named >/dev/null 2>&1 && [ -f /etc/bind/named.conf.options ]; then
  resp /etc/bind/named.conf.options
  grep -q 'version "' /etc/bind/named.conf.options || sed -i '0,/options *{/s//options {\n\tversion "no disponible";/' /etc/bind/named.conf.options
  if named-checkconf 2>/dev/null; then rndc reconfig >/dev/null 2>&1 || systemctl reload named; ok "DNS no revela su version"
  else cp -a "$BK/etc/bind/named.conf.options" /etc/bind/named.conf.options; av "DNS: se dejo como estaba"; fi
fi
if command -v postconf >/dev/null 2>&1 && [ "$ROL" = correo ]; then
  postconf -e 'smtpd_banner = $myhostname ESMTP' && systemctl reload postfix && ok "Postfix no revela su version"
fi
if command -v doveconf >/dev/null 2>&1 && [ "$ROL" = correo ]; then
  echo 'login_greeting = Servidor de correo listo.' > /etc/dovecot/conf.d/99-mejoland-saludo.conf
  doveconf -n >/dev/null 2>&1 && systemctl reload dovecot && ok "Dovecot no revela su version" || rm -f /etc/dovecot/conf.d/99-mejoland-saludo.conf
fi

# ---------------------------------------------------------------------
paso "4 Servicios que sobran en un servidor"
if systemctl list-unit-files avahi-daemon.service >/dev/null 2>&1 && systemctl is-enabled -q avahi-daemon 2>/dev/null; then
  systemctl disable --now avahi-daemon.socket avahi-daemon.service >/dev/null 2>&1 && ok "avahi (mDNS, puerto 5353) apagado"
else ok "avahi no esta activo"; fi

# ---------------------------------------------------------------------
paso "Resumen"
/usr/local/sbin/puertos estado | sed 's/^/  /'
echo "  Abierto para todos: $(ss -tlnH | awk '$4 !~ /^(127\.|\[::1\])/ {n=split($4,a,":"); print a[n]}' | sort -un | while read -r p; do grep -qE "(^|[ ,])$p([ ,]|$)" $E/puertos-reglas.txt || echo -n "$p "; done)"
echo "  (los puertos de numero alto que cambian son de Tailscale)"
echo; echo "LISTO en $ROL. Respaldo: $BK"
echo "Si algo deja de funcionar: 'puertos off' y avisa."
