#!/bin/bash
# =====================================================================
#  PRUEBAS DE ESFUERZO - Paso 1: datos de prueba (ejecutar en SRV-BD, root)
#  Crea, separado de las cuentas reales:
#   - LDAP  ou=Pruebas,ou=Personas : 200 estudiantes (est001..est200) y 50 docentes (doc01..doc50)
#           todos con la MISMA clave (aleatoria, guardada en /root/proyecto/pruebas-clave.txt)
#   - EduNova: 50 cursos "PRB-..." (5 paralelos x 10 asignaturas de 10mo EGB, 1 docente por curso,
#           40 estudiantes por paralelo), 2 actividades y 1 anuncio por curso, 2 libros y 3 recursos en la Biblioteca.
#  Todo llega solo a damian-1 (replica de MariaDB y de LDAP).
#  No hace falta que correo ni srv-aaa-1 esten prendidos: leen LDAP cuando el usuario entra.
#  Para borrar todo despues:  bash borrar-datos-prueba.sh
#  Uso:  bash crear-datos-prueba.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
BASE=dc=proyecto,dc=local; ADM=cn=admin,$BASE; OU=ou=Pruebas,ou=Personas,$BASE
E=/var/www/lms-backend/.env
DBN=$(sed -n 's/^DB_NAME=//p' $E 2>/dev/null | tr -d "\"'"); DBN=${DBN:-institucion}
for c in ldapadd ldapmodify ldapsearch slappasswd mysql; do command -v $c >/dev/null || { echo "Falta $c"; exit 1; }; done
paso() { echo; echo "=================== $1 ==================="; }

read -r -s -p "Clave de $ADM: " LP; echo
PF=$(mktemp); chmod 600 $PF; printf '%s' "$LP" > $PF; trap 'rm -f $PF' EXIT
L="-x -H ldap://127.0.0.1 -D $ADM -y $PF"
ldapsearch $L -b "$BASE" -s base dn >/dev/null 2>&1 || { echo "Clave de LDAP incorrecta (o slapd apagado). No se cambio nada."; exit 1; }

if ldapsearch $L -b "$OU" -s base dn >/dev/null 2>&1; then
  echo "Ya existen datos de prueba ($OU). Para recrearlos: bash borrar-datos-prueba.sh"; exit 1
fi
USADOS=$(ldapsearch $L -LLL -b "$BASE" "(uidNumber=*)" uidNumber | sed -n 's/^uidNumber: //p')
for n in $(seq 20001 20250); do echo "$USADOS" | grep -qx "$n" && { echo "El uidNumber $n ya esta usado. No se cambio nada."; exit 1; }; done
for u in est001 est200 doc01 doc50; do
  [ -n "$(ldapsearch $L -LLL -b "$BASE" "(uid=$u)" dn)" ] && { echo "Ya existe un usuario '$u' fuera de ou=Pruebas. No se cambio nada."; exit 1; }
done
mysql -N "$DBN" -e "SELECT COUNT(*) FROM lms_cursos WHERE codigo LIKE 'PRB-%'" | grep -qx 0 || { echo "Ya hay cursos PRB- en EduNova. Ejecuta antes borrar-datos-prueba.sh"; exit 1; }

paso "1 Cuentas LDAP"
mkdir -p /root/proyecto; chmod 700 /root/proyecto
CLAVE="Mj$(head -c 64 /dev/urandom | tr -dc 'a-z' | head -c 4)$(head -c 64 /dev/urandom | tr -dc '0-9' | head -c 4)$(head -c 64 /dev/urandom | tr -dc 'A-Z' | head -c 2)"
printf 'Clave de TODAS las cuentas de prueba (est001..est200, doc01..doc50): %s\n' "$CLAVE" > /root/proyecto/pruebas-clave.txt
chmod 600 /root/proyecto/pruebas-clave.txt
H=$(slappasswd -s "$CLAVE")
LD=$(mktemp); chmod 600 $LD
{ printf 'dn: %s\nobjectClass: organizationalUnit\nou: Pruebas\ndescription: Cuentas para pruebas de esfuerzo (borrar al terminar)\n\n' "$OU"
  n=20000
  for i in $(seq -w 1 200); do n=$((n+1))
    printf 'dn: uid=est%s,%s\nobjectClass: top\nobjectClass: person\nobjectClass: organizationalPerson\nobjectClass: inetOrgPerson\nobjectClass: posixAccount\nuid: est%s\ncn: Estudiante Prueba %s\ngivenName: Estudiante\nsn: Prueba %s\nmail: est%s@proyecto.local\nuidNumber: %s\ngidNumber: 12000\nhomeDirectory: /home/est%s\nloginShell: /bin/false\ndescription: Estudiante - PRUEBA DE ESFUERZO\nuserPassword: %s\n\n' "$i" "$OU" "$i" "$i" "$i" "$i" "$n" "$i" "$H"; done
  for i in $(seq -w 1 50); do n=$((n+1))
    printf 'dn: uid=doc%s,%s\nobjectClass: top\nobjectClass: person\nobjectClass: organizationalPerson\nobjectClass: inetOrgPerson\nobjectClass: posixAccount\nuid: doc%s\ncn: Docente Prueba %s\ngivenName: Docente\nsn: Prueba %s\nmail: doc%s@proyecto.local\nuidNumber: %s\ngidNumber: 12001\nhomeDirectory: /home/doc%s\nloginShell: /bin/false\ndescription: Docente - PRUEBA DE ESFUERZO\nuserPassword: %s\n\n' "$i" "$OU" "$i" "$i" "$i" "$i" "$n" "$i" "$H"; done
} > $LD
ldapadd $L -f $LD >/dev/null || { echo "ERROR creando cuentas. Ejecuta borrar-datos-prueba.sh y repite."; rm -f $LD; exit 1; }
rm -f $LD
for g in estudiantes:est:200:3 docentes:doc:50:2; do
  IFS=: read -r grp pre tot w <<<"$g"
  { printf 'dn: cn=%s,ou=Grupos,%s\nchangetype: modify\nadd: member\n' "$grp" "$BASE"
    for i in $(seq -f "%0${w}g" 1 $tot); do printf 'member: uid=%s%s,%s\n' "$pre" "$i" "$OU"; done; } | ldapmodify $L >/dev/null \
    && echo "  $tot cuentas en el grupo $grp" || { echo "ERROR agregando al grupo $grp"; exit 1; }
done
echo "  Clave comun guardada en /root/proyecto/pruebas-clave.txt (no se muestra aqui)"

paso "2 Cursos, matriculas, actividades y anuncios en EduNova"
SQL=$(mktemp)
{ echo "SET NAMES utf8mb4; START TRANSACTION;"
  ASIG=("Matemáticas:MAT" "Lengua y Literatura:LEN" "Ciencias Naturales:CCN" "Estudios Sociales:EES" "Inglés:ING" "Educación Física:EFI" "Computación:COM" "Educación Artística:ART" "Física:FIS" "Química:QUI")
  PAR=(A B C D E); d=0
  for p in 0 1 2 3 4; do P=${PAR[$p]}
    for a in "${ASIG[@]}"; do d=$((d+1)); N=${a%%:*}; C=${a##*:}; DOC=$(printf 'doc%02d' $d)
      echo "INSERT INTO lms_cursos (codigo,nombre,asignatura,nivel,paralelo,periodo,capacidad,docente_uid) VALUES ('PRB-$C-10$P','$N 10mo $P (prueba)','$N','10mo EGB','$P','2026-2027',45,'$DOC');"
      echo "SET @c=LAST_INSERT_ID();"
      for s in $(seq $((p*40+1)) $((p*40+40))); do printf "INSERT INTO lms_matriculas (curso_id, estudiante_uid) VALUES (@c,'est%03d');\n" $s; done
      echo "INSERT INTO lms_actividades (curso_id,titulo,descripcion,tipo,fecha_limite,puntaje_max,creado_por) VALUES (@c,'Tarea 1 - $N','Actividad de prueba: escribe un resumen corto.','tarea',NOW()+INTERVAL 30 DAY,10,'$DOC');"
      echo "INSERT INTO lms_actividades (curso_id,titulo,descripcion,tipo,fecha_limite,puntaje_max,creado_por) VALUES (@c,'Lección 1 - $N','Actividad de prueba para la carga del sistema.','leccion',NOW()+INTERVAL 45 DAY,10,'$DOC');"
      echo "INSERT INTO lms_anuncios (curso_id,autor_uid,titulo,cuerpo) VALUES (@c,'$DOC','Bienvenidos a $N','Curso creado para las pruebas de esfuerzo de la plataforma.');"
    done
  done
  echo "INSERT INTO lms_biblioteca (seccion,titulo,descripcion,categoria,libro_autor,libro_editorial,asignatura,nivel_educativo,nivel,tipo,url,autor_uid,autor_nombre) VALUES"
  echo " ('libros','[PRUEBA] Matemática 10mo EGB','Libro de prueba','Libro digital','Ministerio de Educación del Ecuador','MinEduc','Matemáticas','10mo EGB',1,'enlace','https://educacion.gob.ec','doc01','Docente Prueba 01'),"
  echo " ('libros','[PRUEBA] Lengua y Literatura 10mo EGB','Libro de prueba','Libro digital','Ministerio de Educación del Ecuador','MinEduc','Lengua y Literatura','10mo EGB',1,'enlace','https://educacion.gob.ec','doc02','Docente Prueba 02');"
  echo "INSERT INTO lms_biblioteca (titulo,descripcion,categoria,nivel,tipo,url,autor_uid,autor_nombre) VALUES"
  echo " ('[PRUEBA] Reglamento interno','Recurso de prueba','Reglamentos y normativa',1,'enlace','https://educacion.gob.ec','doc01','Docente Prueba 01'),"
  echo " ('[PRUEBA] Calendario académico','Recurso de prueba','Calendario académico',1,'enlace','https://educacion.gob.ec','doc01','Docente Prueba 01');"
  PDF=$(printf '%%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj 2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj 3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]>>endobj\ntrailer<</Root 1 0 R>>\n%%%%EOF\n' | base64 -w0)
  B=$(printf '%s' "$PDF" | base64 -d | wc -c)
  echo "INSERT INTO lms_biblioteca (titulo,descripcion,categoria,nivel,tipo,archivo_nombre,archivo_tipo,archivo_bytes,autor_uid,autor_nombre) VALUES ('[PRUEBA] Guía de estudio (PDF)','Archivo de prueba para medir descargas','Material de estudio',1,'archivo','guia-prueba.pdf','application/pdf',$B,'doc01','Docente Prueba 01');"
  echo "INSERT INTO lms_biblioteca_archivo (id,contenido) VALUES (LAST_INSERT_ID(),'$PDF');"
  echo "COMMIT;"
} > $SQL
if mysql "$DBN" < $SQL; then
  mysql -N "$DBN" -e "SELECT CONCAT('  cursos: ',COUNT(*)) FROM lms_cursos WHERE codigo LIKE 'PRB-%';
    SELECT CONCAT('  matriculas: ',COUNT(*)) FROM lms_matriculas m JOIN lms_cursos c ON c.id=m.curso_id WHERE c.codigo LIKE 'PRB-%';
    SELECT CONCAT('  actividades: ',COUNT(*)) FROM lms_actividades a JOIN lms_cursos c ON c.id=a.curso_id WHERE c.codigo LIKE 'PRB-%';
    SELECT CONCAT('  biblioteca (libros + recursos): ',COUNT(*)) FROM lms_biblioteca WHERE titulo LIKE '[PRUEBA]%';"
else echo "ERROR en EduNova (no se guardo nada de esta parte). Las cuentas LDAP si quedaron."; rm -f $SQL; exit 1; fi
rm -f $SQL

paso "3 Comprobacion"
U=$(ldapsearch $L -LLL -b "$OU" "(objectClass=posixAccount)" uid | grep -c '^uid:')
echo "  cuentas en ou=Pruebas: $U (esperado 250)"
ldapwhoami -x -H ldap://127.0.0.1 -D "uid=est001,$OU" -w "$CLAVE" >/dev/null 2>&1 && echo "  est001 inicia sesion en LDAP: OK" || echo "  AVISO: est001 no pudo autenticarse"
echo; echo "LISTO. Prueba en EduNova con est001 o doc01 (la clave: cat /root/proyecto/pruebas-clave.txt)."
