#!/bin/bash
# =====================================================================
#  Crea la cuenta institucional de una persona de SECRETARIA (SRV-BD, root)
#  - Cuenta LDAP en ou=personas con correo usuario@mejoland.edu.ec
#  - Grupo cn=secretaria (se crea si no existe) -> EduNova rol Secretaria
#    y acceso al Panel de Secretaria con esta misma cuenta.
#  - Tambien sirve para AGREGAR al grupo una cuenta que ya existe.
#  No reinicia OpenLDAP ni modifica ACL.
#  Uso:  bash crear-cuenta-secretaria.sh
# =====================================================================
set -u
BASE=dc=proyecto,dc=local; PERS="ou=personas,$BASE"; GRP="cn=secretaria,ou=grupos,$BASE"
ADMIN="cn=admin,$BASE"; H=ldap://127.0.0.1; DOM=mejoland.edu.ec
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
read -rsp "Clave del administrador LDAP (cn=admin): " PW; echo
ldapwhoami -x -H $H -D "$ADMIN" -w "$PW" >/dev/null 2>&1 || { echo "Clave incorrecta. No se cambio nada."; exit 1; }
L() { ldapsearch -x -LLL -o ldif-wrap=no -H $H -D "$ADMIN" -w "$PW" "$@"; }
M() { ldapmodify -x -H $H -D "$ADMIN" -w "$PW" "$@"; }

echo; echo "1) Cuenta NUEVA   2) Cuenta que YA EXISTE (solo agregarla a Secretaria)"
read -rp "Opcion [1/2]: " OP
if [ "$OP" = "2" ]; then
  read -rp "Usuario existente (uid): " U
  DN=$(L -b "$BASE" "(&(objectClass=inetOrgPerson)(uid=$U))" dn | sed -n 's/^dn: //p')
  [ -n "$DN" ] || { echo "No existe el usuario $U."; exit 1; }
  CLAVE=""
else
  read -rp "Nombres: " NOM; read -rp "Apellidos: " APE
  [ -n "$NOM" ] && [ -n "$APE" ] || { echo "Faltan datos."; exit 1; }
  sug=$(python3 -c 'import sys,unicodedata,re;a=lambda t:unicodedata.normalize("NFKD",t).encode("ascii","ignore").decode().lower();n,ap=sys.argv[1],sys.argv[2].split();print(re.sub("[^a-z]","",a(n)[:1]+a(ap[0])))' "$NOM" "$APE")
  read -rp "Usuario [$sug]: " U; U=${U:-$sug}
  [[ "$U" =~ ^[a-z][a-z0-9._-]{2,30}$ ]] || { echo "Usuario no valido."; exit 1; }
  L -b "$BASE" "(uid=$U)" dn | grep -q '^dn:' && { echo "El usuario $U ya existe. Usa la opcion 2."; exit 1; }
  L -b "$BASE" "(mail=$U@$DOM)" dn | grep -q '^dn:' && { echo "El correo $U@$DOM ya existe."; exit 1; }
  read -rp "Cedula (opcional): " CED
  MAXU=$(L -b "$BASE" "(uidNumber=*)" uidNumber | awk '/^uidNumber:/{if($2>m && $2<60000)m=$2}END{print m+0}')
  UIDN=$(( MAXU < 10000 ? 10000 : MAXU + 1 ))
  CLAVE="$(tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | head -c4)-$(tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | head -c4)-$(tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | head -c4)-$(tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | head -c4)"
  HASH=$(slappasswd -h '{SSHA}' -s "$CLAVE")
  DN="uid=$U,$PERS"
  { echo "dn: $DN"; echo "objectClass: inetOrgPerson"; echo "objectClass: posixAccount"
    echo "uid: $U"; echo "cn: $NOM $APE"; echo "givenName: $NOM"; echo "sn: $APE"; echo "mail: $U@$DOM"
    echo "title: Secretaria"; echo "uidNumber: $UIDN"; echo "gidNumber: $UIDN"; echo "homeDirectory: /home/$U"
    echo "loginShell: /usr/sbin/nologin"; [ -n "${CED:-}" ] && echo "employeeNumber: $CED"
    echo "userPassword: $HASH"; } | ldapadd -x -H $H -D "$ADMIN" -w "$PW" >/dev/null || { echo "ERROR creando la cuenta."; exit 1; }
  echo "Cuenta creada: $DN"
fi

if L -b "$GRP" -s base dn 2>/dev/null | grep -q '^dn:'; then
  L -b "$GRP" -s base "(member=$DN)" dn | grep -q '^dn:' && echo "Ya estaba en el grupo secretaria." || \
  printf 'dn: %s\nchangetype: modify\nadd: member\nmember: %s\n' "$GRP" "$DN" | M >/dev/null && echo "Agregada al grupo secretaria."
else
  printf 'dn: %s\nobjectClass: groupOfNames\ncn: secretaria\ndescription: Personal de Secretaria (EduNova rol Secretaria, Panel de Secretaria)\nmember: %s\n' "$GRP" "$DN" | ldapadd -x -H $H -D "$ADMIN" -w "$PW" >/dev/null && echo "Grupo secretaria creado con $U."
fi
unset PW

echo
echo "================ DATOS DE LA CUENTA ================"
echo " Usuario:  $U"
echo " Correo:   $U@$DOM"
[ -n "$CLAVE" ] && echo " Clave temporal (se muestra UNA vez, entregala en persona): $CLAVE"
echo " Entra a:  EduNova  https://srv-bd.tailae692e.ts.net/plataforma/"
echo "           Panel    https://srv-bd.tailae692e.ts.net/secretaria/"
echo "           Correo   http://100.65.119.48/roundcube/"
echo " Al primer ingreso: EduNova -> Mi perfil -> Cambiar mi contraseña."
echo "===================================================="
