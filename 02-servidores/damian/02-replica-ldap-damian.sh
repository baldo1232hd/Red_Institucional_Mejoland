#!/bin/bash
# =====================================================================
#  Replica OpenLDAP en damian-1 (consumidor syncrepl de SRV-BD) - como root
#  - Agrega EN CALIENTE (sin detener slapd) la base dc=proyecto,dc=local, que se
#    copia sola desde SRV-BD y se mantiene al dia en segundos.
#  - Mismos indices y permisos que SRV-BD. Solo lectura: las escrituras se
#    redirigen a SRV-BD (olcUpdateRef). La base vacia de instalacion queda sin uso.
#  - En SRV-BD no se cambia nada (ya tiene syncprov).
#  Uso:          bash 02-replica-ldap-damian.sh
#  Volver atras: bash /root/proyecto/replica-ldap-*/deshacer.sh
# =====================================================================
set -u
PRINCIPAL=${PRINCIPAL:-100.89.203.22}
BASE=dc=proyecto,dc=local; ADMIN="cn=admin,$BASE"
CONF=${SLAPD_D:-/etc/ldap/slapd.d}; DATA=${LDAP_DATA:-/var/lib/ldap}; DIR="$DATA/proyecto"
LDAPI=${LDAPI:-ldapi:///}
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
ldapsearch -Q -LLL -Y EXTERNAL -H "$LDAPI" -b cn=config -s base dn >/dev/null 2>&1 || { echo "No puedo leer cn=config de slapd en damian-1 (¿esta activo?)."; exit 1; }
if ldapsearch -Q -LLL -Y EXTERNAL -H "$LDAPI" -b cn=config "(olcSuffix=$BASE)" dn 2>/dev/null | grep -q '^dn:'; then
  echo "damian-1 ya tiene una base $BASE configurada. No se cambio nada."; exit 1
fi

read -rsp "Clave del administrador LDAP de SRV-BD (cn=admin): " PW; echo
case "$PW" in *\"*|*\\*) echo "La clave contiene comillas o barra invertida; no se puede usar en syncrepl. No se cambio nada."; exit 1;; esac
ldapwhoami -x -H "ldap://$PRINCIPAL" -D "$ADMIN" -w "$PW" >/dev/null 2>&1 || { echo "No puedo autenticarme en ldap://$PRINCIPAL con cn=admin. No se cambio nada."; exit 1; }
TOTAL=$(ldapsearch -x -LLL -H "ldap://$PRINCIPAL" -D "$ADMIN" -w "$PW" -b "$BASE" dn | grep -c '^dn:')
echo "SRV-BD tiene $TOTAL entradas en $BASE."
echo "Bases actuales en damian-1 (no se tocan): $(ldapsearch -Q -LLL -Y EXTERNAL -H "$LDAPI" -b cn=config '(olcSuffix=*)' olcSuffix | sed -n 's/^olcSuffix: //p' | tr '\n' ' ')"
read -rp "Escribe SI para continuar: " OK; [ "$OK" = "SI" ] || { echo "Cancelado."; exit 0; }

BK=/root/proyecto/replica-ldap-$(date +%Y%m%d-%H%M); mkdir -p "$BK"; chmod 700 "$BK"
cat > "$BK/deshacer.sh" <<EOF
#!/bin/bash
DN=\$(ldapsearch -Q -LLL -Y EXTERNAL -H "$LDAPI" -b cn=config "(olcSuffix=$BASE)" dn | sed -n 's/^dn: //p')
[ -n "\$DN" ] && ldapdelete -Q -Y EXTERNAL -H "$LDAPI" "\$DN" && echo "Base $BASE quitada de damian-1."
rm -rf "$DIR"
EOF
chmod 700 "$BK/deshacer.sh"

echo; echo "== 1 Respaldo de la configuracion de damian-1 (slapd sigue funcionando)"
slapcat -n0 -F "$CONF" > "$BK/config-antes.ldif" 2>/dev/null; chmod 600 "$BK/config-antes.ldif"
echo "   Respaldo en $BK"

echo; echo "== 2 Nueva base consumidora en $DIR"
install -d -m 750 -o openldap -g openldap "$DIR"
umask 077
cat > "$BK/nueva-base.ldif" <<EOF
dn: olcDatabase=mdb,cn=config
objectClass: olcDatabaseConfig
objectClass: olcMdbConfig
olcDatabase: mdb
olcDbDirectory: $DIR
olcSuffix: $BASE
olcRootDN: $ADMIN
olcDbMaxSize: 1073741824
olcDbIndex: objectClass eq
olcDbIndex: cn,uid eq
olcDbIndex: uidNumber,gidNumber eq
olcDbIndex: member,memberUid eq
olcDbIndex: mail eq
olcDbIndex: entryCSN eq
olcDbIndex: entryUUID eq
olcSyncrepl: {0}rid=101 provider=ldap://$PRINCIPAL:389 bindmethod=simple binddn="$ADMIN" credentials="$PW" searchbase="$BASE" scope=sub schemachecking=on type=refreshAndPersist retry="10 +" timeout=5 network-timeout=5 keepalive=240:10:30
olcUpdateRef: ldap://$PRINCIPAL:389
olcAccess: {0}to dn.onelevel="ou=Altas,ou=Personas,$BASE" attrs=userPassword by dn.exact="cn=svc-secretaria,$BASE" write by self write by anonymous auth by * none
olcAccess: {1}to attrs=userPassword by self write by anonymous auth by * none
olcAccess: {2}to attrs=shadowLastChange by self write by * read
olcAccess: {3}to dn.exact="ou=Altas,ou=Personas,$BASE" attrs=children by dn.exact="cn=svc-secretaria,$BASE" write by * read
olcAccess: {4}to dn.onelevel="ou=Altas,ou=Personas,$BASE" by dn.exact="cn=svc-secretaria,$BASE" write by * read
olcAccess: {5}to dn.exact="cn=estudiantes,ou=Grupos,$BASE" attrs=member val.regex="^uid=[a-z0-9_-]+,ou=altas,ou=personas,dc=proyecto,dc=local\$" by dn.exact="cn=svc-secretaria,$BASE" write by * read
olcAccess: {6}to dn.exact="cn=docentes,ou=Grupos,$BASE" attrs=member val.regex="^uid=[a-z0-9_-]+,ou=altas,ou=personas,dc=proyecto,dc=local\$" by dn.exact="cn=svc-secretaria,$BASE" write by * read
olcAccess: {7}to * by * read
EOF
unset PW
if ! ldapadd -Q -Y EXTERNAL -H "$LDAPI" -f "$BK/nueva-base.ldif" >"$BK/ldapadd.log" 2>&1; then
  echo "ERROR creando la base:"; tail -5 "$BK/ldapadd.log"; rm -f "$BK/nueva-base.ldif"; bash "$BK/deshacer.sh"; exit 1
fi
shred -u "$BK/nueva-base.ldif" 2>/dev/null || rm -f "$BK/nueva-base.ldif"
echo "   Creada: $(sed -n 's/^adding new entry //p' "$BK/ldapadd.log")"

echo; echo "== 3 Esperando la copia inicial desde SRV-BD"
N=0
for i in $(seq 1 30); do
  N=$(ldapsearch -x -LLL -H ldap://127.0.0.1 -b "$BASE" dn 2>/dev/null | grep -c '^dn:')
  [ "$N" -ge "$TOTAL" ] && break; sleep 2
done
echo "   damian-1 tiene $N de $TOTAL entradas."
CSN_P=$(ldapsearch -x -LLL -H "ldap://$PRINCIPAL" -b "$BASE" -s base contextCSN | sed -n 's/^contextCSN: //p')
CSN_R=$(ldapsearch -x -LLL -H ldap://127.0.0.1 -b "$BASE" -s base contextCSN | sed -n 's/^contextCSN: //p')
echo "   contextCSN SRV-BD:   $CSN_P"
echo "   contextCSN damian-1: $CSN_R"
if [ -n "$CSN_P" ] && [ "$CSN_P" = "$CSN_R" ]; then echo; echo "LISTO: la replica LDAP esta al dia."
else echo; echo "ATENCION: aun no coinciden. Espera un minuto y revisa: journalctl -u slapd -n 20"; fi
echo "Volver atras: bash $BK/deshacer.sh"
