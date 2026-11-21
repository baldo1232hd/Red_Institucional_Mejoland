#!/bin/bash
# =====================================================================
#  Dominio de correo proyecto.local -> mejoland.edu.ec   (PARTE 1: SRV-BD)
#  - Cambia el atributo mail de cada cuenta en LDAP (no toca la base,
#    las ACL ni reinicia OpenLDAP).
#  - Panel de secretaria: las cuentas nuevas se crean @mejoland.edu.ec.
#  - EduNova: texto de ejemplo del login.
#  Uso (root en SRV-BD):  bash 03-dominio-srvbd.sh
#  Despues, ENSEGUIDA, ejecutar la PARTE 2 en el servidor de correo.
#  Deshacer: bash /root/proyecto/dominio-backup-*/deshacer-srvbd.sh
# =====================================================================
set -u
VIEJO=proyecto.local
NUEVO=mejoland.edu.ec
BASE=dc=proyecto,dc=local
ADMIN="cn=admin,$BASE"
H=ldap://127.0.0.1
PANEL=/var/www/secretaria/index.php
LMSF=/var/www/lms-frontend/index.html
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }

read -rsp "Clave del administrador LDAP (cn=admin): " PW; echo
ldapwhoami -x -H $H -D "$ADMIN" -w "$PW" >/dev/null 2>&1 || { echo "Clave incorrecta. No se cambio nada."; exit 1; }
L() { ldapsearch -x -LLL -o ldif-wrap=no -H $H -D "$ADMIN" -w "$PW" "$@"; }

BK=/root/proyecto/dominio-backup-$(date +%Y%m%d-%H%M)
mkdir -p "$BK"; chmod 700 "$BK"
L -b "$BASE" "(mail=*@$VIEJO)" mail > "$BK/mail-anterior.ldif"
cp -a $PANEL "$BK/panel-index.php"
cp -a $LMSF "$BK/lms-index.html"

echo; echo "== Cuentas a cambiar =="
PLAN=()
while IFS='|' read -r DN M; do
  [ -z "$DN" ] && continue
  N="${M%@*}@$NUEVO"
  if L -b "$BASE" "(mail=$N)" dn | grep -q '^dn:'; then
    echo "  $M  -> OMITIDA: ya existe otra cuenta con $N"; continue
  fi
  printf '  %-32s -> %s\n' "$M" "$N"
  PLAN+=("$DN|$M|$N")
done < <(L -b "$BASE" "(mail=*@$VIEJO)" mail | awk '/^dn: /{d=substr($0,5)} /^mail: /{print d"|"substr($0,7)}' | grep -i "@$VIEJO\$")
[ ${#PLAN[@]} -eq 0 ] && echo "  (ninguna)"
echo; read -rp "Escribe SI para aplicar el cambio: " OK
[ "$OK" = "SI" ] || { echo "Cancelado. No se cambio nada."; exit 0; }

# Script para deshacer (devuelve cada correo a su valor anterior)
{
  echo '#!/bin/bash'
  echo 'read -rsp "Clave del administrador LDAP (cn=admin): " PW; echo'
} > "$BK/deshacer-srvbd.sh"

echo; echo "== LDAP =="
for P in "${PLAN[@]}"; do
  IFS='|' read -r DN M N <<<"$P"
  if ldapmodify -x -H $H -D "$ADMIN" -w "$PW" >/dev/null <<EOF
dn: $DN
changetype: modify
delete: mail
mail: $M
-
add: mail
mail: $N
EOF
  then
    echo "  OK  $N"
    cat >> "$BK/deshacer-srvbd.sh" <<EOF
ldapmodify -x -H $H -D "$ADMIN" -w "\$PW" <<'X'
dn: $DN
changetype: modify
delete: mail
mail: $N
-
add: mail
mail: $M
X
EOF
  else
    echo "  ERROR en $M (se queda como estaba)"
  fi
done

echo; echo "== Panel de secretaria y EduNova =="
sed -i "s/const MAIL_DOMAIN = '$VIEJO';/const MAIL_DOMAIN = '$NUEVO';/; s/Servicios tecnológicos institucionales · $VIEJO/Servicios tecnológicos institucionales · $NUEVO/; s/OpenLDAP <code>$VIEJO<\/code>/Correo <code>@$NUEVO<\/code>/" $PANEL
php -l $PANEL >/dev/null && echo "  Panel: sintaxis OK ($(grep -c "MAIL_DOMAIN = '$NUEVO'" $PANEL) cambio de dominio)" || { echo "  ERROR de sintaxis en el panel: restaurando"; cp -a "$BK/panel-index.php" $PANEL; }
sed -i "s/usuario@$VIEJO/usuario@$NUEVO/g; s/acabezas@$VIEJO/acabezas@$NUEVO/g" $LMSF
echo "  EduNova: $(grep -c "@$NUEVO" $LMSF) texto(s) actualizado(s)"
cat >> "$BK/deshacer-srvbd.sh" <<EOF
cp -a $BK/panel-index.php $PANEL
cp -a $BK/lms-index.html $LMSF
echo "SRV-BD volvio a @$VIEJO"
EOF
chmod 700 "$BK/deshacer-srvbd.sh"

echo; echo "== Revision =="
L -b "$BASE" "(mail=*)" uid mail | grep -E '^(uid|mail):'
echo
echo "LISTO. Ahora ejecuta ENSEGUIDA la parte 2 en el servidor de correo (HP)."
echo "Para volver atras: bash $BK/deshacer-srvbd.sh"
