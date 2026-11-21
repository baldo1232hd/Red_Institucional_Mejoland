#!/bin/bash
# =====================================================================
#  PRUEBAS DE ESFUERZO - Borrar TODOS los datos de prueba (SRV-BD, root)
#  Quita: ou=Pruebas (250 cuentas) y su pertenencia a los grupos; cursos PRB-* con sus
#  matriculas, actividades, entregas y anuncios; recursos [PRUEBA] de la Biblioteca.
#  No toca ninguna cuenta ni curso real. La auditoria se conserva.
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
BASE=dc=proyecto,dc=local; ADM=cn=admin,$BASE; OU=ou=Pruebas,ou=Personas,$BASE
DBN=$(sed -n 's/^DB_NAME=//p' /var/www/lms-backend/.env 2>/dev/null | tr -d "\"'"); DBN=${DBN:-institucion}
read -r -p "Esto borra todos los datos de prueba. Escribe BORRAR para seguir: " OK; [ "$OK" = BORRAR ] || { echo "Cancelado."; exit 1; }
read -r -s -p "Clave de $ADM: " LP; echo
PF=$(mktemp); chmod 600 $PF; printf '%s' "$LP" > $PF; trap 'rm -f $PF' EXIT
L="-x -H ldap://127.0.0.1 -D $ADM -y $PF"
ldapsearch $L -b "$BASE" -s base dn >/dev/null 2>&1 || { echo "Clave de LDAP incorrecta."; exit 1; }

echo "== EduNova"
IDS=$(mysql -N "$DBN" -e "SELECT GROUP_CONCAT(id) FROM lms_cursos WHERE codigo LIKE 'PRB-%'")
if [ -n "$IDS" ] && [ "$IDS" != NULL ]; then
  ACT=$(mysql -N "$DBN" -e "SELECT IFNULL(GROUP_CONCAT(id),0) FROM lms_actividades WHERE curso_id IN ($IDS)")
  for T in $(mysql -N -e "SELECT table_name FROM information_schema.columns WHERE table_schema='$DBN' AND column_name='actividad_id'"); do
    mysql "$DBN" -e "DELETE FROM \`$T\` WHERE actividad_id IN ($ACT)" && echo "  $T"; done
  for T in $(mysql -N -e "SELECT table_name FROM information_schema.columns WHERE table_schema='$DBN' AND column_name='curso_id' AND table_name NOT IN ('lms_biblioteca')"); do
    mysql "$DBN" -e "DELETE FROM \`$T\` WHERE curso_id IN ($IDS)" && echo "  $T"; done
  mysql "$DBN" -e "DELETE FROM lms_cursos WHERE id IN ($IDS)" && echo "  lms_cursos (PRB-*)"
else echo "  no hay cursos de prueba"; fi
mysql "$DBN" -e "DELETE a FROM lms_biblioteca_archivo a JOIN lms_biblioteca b ON b.id=a.id WHERE b.titulo LIKE '[PRUEBA]%' OR b.autor_uid REGEXP '^(est[0-9]{3}|doc[0-9]{2})\$';
  DELETE FROM lms_biblioteca WHERE titulo LIKE '[PRUEBA]%' OR autor_uid REGEXP '^(est[0-9]{3}|doc[0-9]{2})\$';" && echo "  biblioteca de prueba"
mysql "$DBN" -e "DELETE FROM lms_impresiones WHERE usuario REGEXP '^(est[0-9]{3}|doc[0-9]{2})\$'" 2>/dev/null || true

echo "== LDAP"
for g in estudiantes docentes; do
  M=$(ldapsearch $L -LLL -o ldif-wrap=no -b "cn=$g,ou=Grupos,$BASE" -s base member | sed -n 's/^member: //p' | grep -i ",ou=Pruebas,")
  [ -z "$M" ] && continue
  { printf 'dn: cn=%s,ou=Grupos,%s\nchangetype: modify\ndelete: member\n' "$g" "$BASE"; echo "$M" | sed 's/^/member: /'; } | ldapmodify $L >/dev/null \
    && echo "  quitados $(echo "$M" | wc -l) miembros de $g"
done
if ldapsearch $L -b "$OU" -s base dn >/dev/null 2>&1; then ldapdelete $L -r "$OU" && echo "  ou=Pruebas borrada"; else echo "  ou=Pruebas no existe"; fi
rm -f /root/proyecto/pruebas-clave.txt
echo; echo "LISTO. Datos de prueba eliminados."
