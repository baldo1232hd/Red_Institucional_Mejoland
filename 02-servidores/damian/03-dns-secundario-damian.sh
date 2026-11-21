#!/bin/bash
# =====================================================================
#  DNS secundario - PASO 2 (damian-1, root): BIND copia la zona mejoland.edu.ec
#  de SRV-BD y la mantiene al dia sola (notify).
#  Uso:  bash 03-dns-secundario-damian.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
SRV=100.89.203.22; Z=mejoland.edu.ec; LOCAL=/etc/bind/named.conf.local
if ! command -v named >/dev/null; then
  echo "== Instalando BIND9"; apt-get install -y -q bind9 bind9-dnsutils >/dev/null || { echo "No se pudo instalar bind9"; exit 1; }
fi
grep -q "zone \"$Z\"" $LOCAL 2>/dev/null && { echo "La zona $Z ya existe en damian-1. No se cambio nada."; exit 1; }
BK=/root/proyecto/dns-secundario-$(date +%Y%m%d-%H%M); mkdir -p "$BK"; chmod 700 "$BK"; cp -a $LOCAL "$BK/"
cat >> $LOCAL <<EOF

// Secundario de la zona institucional (copia automatica desde SRV-BD)
zone "$Z" {
        type slave;
        masters { $SRV; };
        file "/var/cache/bind/db.$Z";
        allow-transfer { none; };
};
EOF
named-checkconf || { echo "ERROR: restaurando"; cp -a "$BK/named.conf.local" $LOCAL; exit 1; }
systemctl enable --now named >/dev/null 2>&1 || systemctl enable --now bind9 >/dev/null 2>&1
rndc reconfig 2>/dev/null; sleep 3; rndc retransfer $Z 2>/dev/null; sleep 2
echo "== Pruebas (preguntando al BIND de damian-1)"
for n in correo webmail srv-bd plataforma; do printf '  %-24s -> %s\n' "$n.$Z" "$(dig +short @127.0.0.1 $n.$Z | tail -1)"; done
P=$(dig +short @$SRV SOA $Z | awk '{print $3}'); R=$(dig +short @127.0.0.1 SOA $Z | awk '{print $3}')
echo "  Serial SRV-BD: $P   Serial damian-1: $R"
[ -n "$R" ] && [ "$P" = "$R" ] && echo "LISTO: damian-1 es DNS secundario de $Z." || echo "ATENCION: aun no copia la zona; revisa: journalctl -u named -n 20"
echo "Falta: en Tailscale (DNS) agregar 100.93.52.67 como segundo servidor de mejoland.edu.ec."
