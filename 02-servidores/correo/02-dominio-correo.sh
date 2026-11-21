#!/bin/bash
# =====================================================================
#  Dominio de correo proyecto.local -> mejoland.edu.ec   (PARTE 2: HP)
#  - Postfix: mejoland.edu.ec es el dominio de los buzones;
#    proyecto.local queda como ALIAS (lo que llegue ahi se entrega
#    al mismo usuario @mejoland.edu.ec).
#  - Buzones: /var/mail/vhosts/proyecto.local -> mejoland.edu.ec
#    (se mueve la carpeta, NO se pierde ningun correo).
#  - Roundcube: completa el usuario con @mejoland.edu.ec.
#  Uso (root en el servidor de correo), DESPUES de la parte 1:
#      bash 02-dominio-correo.sh
#  Deshacer: bash /root/proyecto/dominio-backup-*/deshacer-correo.sh
# =====================================================================
set -u
VIEJO=proyecto.local
NUEVO=mejoland.edu.ec
VH=/var/mail/vhosts
RC=/etc/roundcube/config.inc.php
MAPA=/etc/postfix/dominio-anterior.regexp
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
postconf -m | grep -qx regexp || { echo "Postfix no tiene soporte regexp. No se cambio nada."; exit 1; }
[ -d "$VH/$VIEJO" ] || { echo "No existe $VH/$VIEJO. No se cambio nada."; exit 1; }
[ -e "$VH/$NUEVO" ] && { echo "Ya existe $VH/$NUEVO (¿ya se ejecuto?). No se cambio nada."; exit 1; }
VAM=$(postconf -n -h virtual_alias_maps 2>/dev/null)
[ -n "$VAM" ] && { echo "Ya hay virtual_alias_maps = $VAM; revisalo antes. No se cambio nada."; exit 1; }

BK=/root/proyecto/dominio-backup-$(date +%Y%m%d-%H%M)
mkdir -p "$BK"; chmod 700 "$BK"
cp -a /etc/postfix/main.cf "$BK/main.cf"
cp -a $RC "$BK/config.inc.php"
cat > "$BK/deshacer-correo.sh" <<EOF
#!/bin/bash
systemctl stop postfix dovecot
mv $VH/$NUEVO $VH/$VIEJO
cp -a $BK/main.cf /etc/postfix/main.cf
cp -a $BK/config.inc.php $RC
rm -f $MAPA
systemctl start dovecot postfix; systemctl reload apache2
echo "Correo volvio a @$VIEJO"
EOF
chmod 700 "$BK/deshacer-correo.sh"
echo "Respaldo en $BK"

echo; echo "== Buzones (servicio detenido unos segundos) =="
systemctl stop postfix dovecot
mv "$VH/$VIEJO" "$VH/$NUEVO"
ls -l "$VH"

echo; echo "== Postfix =="
echo "/^(.+)@proyecto\.local\$/   \${1}@$NUEVO" > $MAPA
postconf -e "mydomain = $NUEVO" \
            "virtual_mailbox_domains = $NUEVO" \
            "virtual_alias_domains = $VIEJO" \
            "virtual_alias_maps = regexp:$MAPA"
postfix check && echo "  postfix check OK"

echo; echo "== Roundcube =="
sed -i "s/\$config\['username_domain'\] = '$VIEJO';/\$config['username_domain'] = '$NUEVO';/" $RC
php -l $RC >/dev/null && echo "  config.inc.php: sintaxis OK" || { echo "  ERROR de sintaxis: restaurando"; cp -a "$BK/config.inc.php" $RC; }
grep "username_domain" $RC

systemctl start dovecot postfix
systemctl reload apache2

echo; echo "== Revision =="
systemctl is-active postfix dovecot
echo -n "Alias viejo -> nuevo:   "; postmap -q "acabezas@$VIEJO" regexp:$MAPA
echo -n "Buzon en LDAP (nuevo):  "; postmap -q "acabezas@$NUEVO" ldap:/etc/postfix/ldap-usuarios.cf || echo "NO ENCONTRADO (¿ejecutaste la parte 1 en SRV-BD?)"
echo -n "Usuario en Dovecot:     "; doveadm user "acabezas@$NUEVO" 2>&1 | grep -E 'home|error' | head -2
echo
echo "LISTO. Entra a Roundcube con Ctrl+F5 como 'acabezas' (o acabezas@$NUEVO)."
echo "Para volver atras: bash $BK/deshacer-correo.sh"
