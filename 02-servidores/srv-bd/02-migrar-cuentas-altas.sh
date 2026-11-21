#!/bin/bash
# =====================================================================
#  Mueve estudiantes y docentes existentes de ou=personas a ou=Altas
#  para que secretaria pueda gestionarlos (restablecer clave, cedula...).
#  - NO mueve al personal: administracion, admins-red ni cuentas de servicio.
#  - Actualiza la membresia de los grupos y deja gidNumber 12000/12001.
#  - Correo, RADIUS, EduNova y Roundcube buscan por uid/mail en todo
#    ou=personas (incluye ou=Altas): siguen funcionando igual.
#  Uso (root en SRV-BD):  bash 02-migrar-cuentas-altas.sh
# =====================================================================
set -u
BASE=dc=proyecto,dc=local
PERS="ou=personas,$BASE"
ALTAS="ou=Altas,ou=personas,$BASE"
GRP="ou=grupos,$BASE"
ADMIN="cn=admin,$BASE"
H=ldap://127.0.0.1

read -rsp "Clave del administrador LDAP (cn=admin): " PW; echo
ldapwhoami -x -H $H -D "$ADMIN" -w "$PW" >/dev/null 2>&1 || { echo "Clave incorrecta. No se cambio nada."; exit 1; }
L() { ldapsearch -x -LLL -o ldif-wrap=no -H $H -D "$ADMIN" -w "$PW" "$@"; }
miembro() { L -b "cn=$1,$GRP" -s base "(member=$2)" dn 2>/dev/null | grep -q '^dn:'; }

echo; echo "== Cuentas directamente en ou=personas (fuera de ou=Altas) =="
PLAN=()
while read -r DN; do
  [ -z "$DN" ] && continue
  U=$(L -b "$DN" -s base uid | sed -n 's/^uid: //p')
  if miembro administracion "$DN" || miembro admins-red "$DN"; then
    printf '  %-14s se queda (personal administrativo o de red)\n' "$U"; continue
  fi
  if miembro estudiantes "$DN"; then R=estudiantes; G=12000; T=Estudiante
  elif miembro docentes "$DN"; then R=docentes; G=12001; T=Docente
  else printf '  %-14s se queda (no es estudiante ni docente)\n' "$U"; continue; fi
  printf '  %-14s -> ou=Altas  (%s)\n' "$U" "$T"
  PLAN+=("$U|$DN|$R|$G|$T")
done < <(L -b "$PERS" -s one "(objectClass=inetOrgPerson)" dn | sed -n 's/^dn: //p')

[ ${#PLAN[@]} -eq 0 ] && { echo; echo "Nada que mover."; exit 0; }
echo; read -rp "Escribe SI para mover ${#PLAN[@]} cuenta(s): " OK
[ "$OK" = "SI" ] || { echo "Cancelado. No se cambio nada."; exit 0; }

for P in "${PLAN[@]}"; do
  IFS='|' read -r U OLD R G T <<<"$P"
  NEW="uid=$U,$ALTAS"
  echo; echo "== $U =="
  if ! ldapmodrdn -x -H $H -D "$ADMIN" -w "$PW" -s "$ALTAS" "$OLD" "uid=$U"; then
    echo "  ERROR al mover $U: se deja como estaba."; continue
  fi
  # Grupos: reemplazar el DN original por el nuevo (si el overlay refint ya lo hizo, se ignora el aviso).
  for GN in $(L -b "$GRP" "(member=$OLD)" cn | sed -n 's/^cn: //p') $R; do
    ldapmodify -x -c -H $H -D "$ADMIN" -w "$PW" >/dev/null 2>&1 <<EOF
dn: cn=$GN,$GRP
changetype: modify
delete: member
member: $OLD
EOF
    ldapmodify -x -c -H $H -D "$ADMIN" -w "$PW" >/dev/null 2>&1 <<EOF
dn: cn=$GN,$GRP
changetype: modify
add: member
member: $NEW
EOF
  done
  DESC=$(L -b "$NEW" -s base description | sed -n 's/^description: //p')
  {
    echo "dn: $NEW"; echo "changetype: modify"
    echo "replace: gidNumber"; echo "gidNumber: $G"
    if [ -z "$DESC" ]; then echo "-"; echo "add: description"; echo "description: $T - migrada a gestion de secretaria"; fi
  } | ldapmodify -x -H $H -D "$ADMIN" -w "$PW" >/dev/null && echo "  gidNumber=$G"
  miembro "$R" "$NEW" && echo "  OK: en ou=Altas y en el grupo $R" || echo "  REVISAR: no aparece en el grupo $R"
done
unset PW
echo; echo "LISTO. En el panel, esas cuentas ya muestran «Gestionar»."
