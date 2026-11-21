#!/bin/bash
# =====================================================================
#  Zona DNS mejoland.edu.ec en el BIND de SRV-BD (valores iniciales con IP de Tailscale;
#  modo-lab y modo-casa la regeneran). No toca la zona proyecto.local ni las opciones de BIND.
#  Se recarga con rndc (sin reiniciar el servicio).
#  Uso (root en SRV-BD):  bash 04-dns-mejoland.sh
#  Cambios manuales: editar /etc/bind/db.mejoland.edu.ec, subir el serial y ejecutar: rndc reload mejoland.edu.ec
#  Deshacer: bash /root/proyecto/dns-mejoland-backup-*/deshacer.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
SRV=100.89.203.22      # srv-bd   (Tailscale)
MAIL=100.65.119.48     # correo   (Tailscale)
Z=mejoland.edu.ec; F=/etc/bind/db.$Z; LOCAL=/etc/bind/named.conf.local
grep -q "zone \"$Z\"" $LOCAL && { echo "La zona $Z ya existe en $LOCAL. No se cambio nada."; exit 1; }

BK=/root/proyecto/dns-mejoland-backup-$(date +%Y%m%d-%H%M)
mkdir -p "$BK"; chmod 700 "$BK"; cp -a $LOCAL "$BK/"
cat > "$BK/deshacer.sh" <<EOF
#!/bin/bash
cp -a $BK/named.conf.local $LOCAL; rm -f $F
named-checkconf && rndc reconfig && echo "Zona $Z quitada."
EOF
chmod 700 "$BK/deshacer.sh"; echo "Respaldo en $BK"

SERIAL=$(date +%Y%m%d)01
cat > $F <<EOF
; Zona $Z - Centro Educativo Mejoland
\$TTL 300
@       IN SOA  ns1.$Z. admin.$Z. ( $SERIAL 3600 900 604800 300 )
@       IN NS   ns1.$Z.
@       IN MX   10 correo.$Z.
@       IN TXT  "v=spf1 mx -all"
ns1     IN A    $SRV
; --- SRV-BD: LDAP, MariaDB, EduNova, Panel, LAM, CUPS
srv-bd      IN A     $SRV
ldap        IN CNAME srv-bd
bd          IN CNAME srv-bd
impresion   IN CNAME srv-bd
secretaria  IN CNAME srv-bd
plataforma  IN CNAME srv-bd
; --- Servidor de correo (HP): Postfix, Dovecot, Roundcube
correo      IN A     $MAIL
webmail     IN CNAME correo
mail        IN CNAME correo
smtp        IN CNAME correo
imap        IN CNAME correo
EOF
chown root:bind $F; chmod 644 $F
named-checkzone $Z $F || { echo "ERROR en la zona. Deshaciendo."; bash "$BK/deshacer.sh"; exit 1; }

cat >> $LOCAL <<EOF

// Centro Educativo Mejoland (agregado por dns-mejoland.sh)
zone "$Z" {
        type master;
        file "$F";
        allow-transfer { 192.168.40.13/32; };
};
EOF
named-checkconf || { echo "ERROR en la configuracion. Deshaciendo."; bash "$BK/deshacer.sh"; exit 1; }
rndc reconfig && sleep 1

echo; echo "== Pruebas (preguntando a BIND por la IP de Tailscale)"
for n in srv-bd plataforma correo webmail impresion; do
  printf '  %-26s -> %s\n' "$n.$Z" "$(dig +short @$SRV $n.$Z | tail -1)"
done
printf '  %-26s -> %s\n' "MX $Z" "$(dig +short @$SRV MX $Z)"
echo -n "  proyecto.local sigue:       "; dig +short @$SRV SOA proyecto.local | cut -d' ' -f1
echo
echo "LISTO en SRV-BD. Falta activar el Split DNS en la consola de Tailscale (ver instrucciones)."
echo "Si algo falla:  bash $BK/deshacer.sh"
