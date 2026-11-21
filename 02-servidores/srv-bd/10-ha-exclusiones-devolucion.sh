#!/bin/bash
# =====================================================================
#  Alta disponibilidad: exclusiones y devolucion controlada (ejecutar en SRV-BD y en damian-1, root)
#   1 La conmutacion solo copia los datos que residen en SRV-BD: se excluyen glpi, nextcloud
#     (sus datos reales estan en srv-apps y se respaldan alli y en SRV-BD) y db_prueba_gtid.
#     damian-1 no replica esas bases.
#   2 damian-1 devuelve el mando a SRV-BD solo cuando:  SRV-BD lleva 5 min estable  Y
#     nadie uso EduNova en los ultimos 5 min (sin inicios de sesion, entregas ni notas).
#     Se puede forzar con:  mejoland-ha devolver
#  Uso:  bash 10-ha-exclusiones-devolucion.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
H=/usr/local/sbin/mejoland-ha; C=/etc/mejoland-ha/ha.conf
[ -f $H ] && [ -f $C ] || { echo "No encuentro $H o $C"; exit 1; }
grep -q '^PRINCIPAL_TS=' $C && ROL=damian || ROL=srv-bd
grep -q "mejoland_ha|zabbix" $H || { echo "Primero ejecutar 09-ha-ajustes-vigilante.sh"; exit 1; }
echo "Equipo: $ROL"
TS=$(date +%Y%m%d-%H%M%S); cp -a $H /root/proyecto/mejoland-ha-antes-exclusiones-$TS; cp -a $C /root/proyecto/ha.conf-antes-exclusiones-$TS
DBN=$(sed -n 's/^DB_NAME=//p' /var/www/lms-backend/.env 2>/dev/null | tr -d "\"'"); DBN=${DBN:-institucion}

echo "== 1 Bases que se copian en los cambios de servidor"
ROL=$ROL DBN=$DBN python3 - "$H" <<'PY'
import os, sys
p = sys.argv[1]; s = open(p).read(); rol = os.environ['ROL']; dbn = os.environ['DBN']; c = 0
a = "|mejoland_ha|zabbix)$'"
if a in s: s = s.replace(a, "|mejoland_ha|zabbix|glpi|nextcloud|db_prueba_gtid)$'"); c += 1
if rol == 'damian' and 'sin_actividad()' not in s:
    fun = ('\n# hubo uso de EduNova en los ultimos 5 min? (0 = sin actividad, se puede regresar)\n'
           'sin_actividad() {\n'
           '  local n; n=$(mysql -N -e "SELECT COUNT(*) FROM ' + dbn + '.lms_auditoria WHERE cuando > NOW() - INTERVAL 5 MINUTE" 2>/dev/null)\n'
           '  [ -z "$n" ] && return 0\n'
           '  [ "$n" -eq 0 ] && { rm -f $D/regreso_pospuesto; return 0; }\n'
           '  [ -f $D/regreso_pospuesto ] || { touch $D/regreso_pospuesto; log "Regreso pospuesto: hay usuarios trabajando ($n acciones en 5 min); se hara en la primera pausa"; }\n'
           '  return 1\n'
           '}\n')
    a = "poner() { echo \"$1\" > $D/estado; ESTADO=$1; }\n"
    assert a in s, "no encuentro poner()"; s = s.replace(a, a + fun, 1); c += 1
    a = 'if [ $(( $(date +%s) - $(cat $D/estable_desde) )) -ge "$ESPERA_REGRESO" ]; then'
    assert a in s, "no encuentro la condicion de regreso"
    s = s.replace(a, a[:-6] + ' && sin_actividad; then', 1); c += 1
open(p, 'w').write(s); print(f"  cambios aplicados: {c}")
PY
[ $? -eq 0 ] && bash -n $H || { echo "ERROR: restaurando"; cp -a /root/proyecto/mejoland-ha-antes-exclusiones-$TS $H; exit 1; }
grep -q "zabbix|glpi|nextcloud|db_prueba_gtid" $H && echo "  excluidas de las copias: zabbix glpi nextcloud db_prueba_gtid"

if [ $ROL = damian ]; then
  grep -q "sin_actividad; then" $H && echo "  regreso solo sin actividad en EduNova: OK"
  sed -i '/^ESPERA_REGRESO=/d' $C; echo 'ESPERA_REGRESO=300' >> $C; echo "  SRV-BD debe estar estable 5 min (ESPERA_REGRESO=300)"
  echo "== 2 Replica: damian-1 deja de copiar glpi, nextcloud y db_prueba_gtid"
  L='zabbix.%,glpi.%,nextcloud.%,db_prueba_gtid.%'
  printf '# Mejoland: estas bases no son parte de la alta disponibilidad\n[mysqld]\nreplicate_wild_ignore_table = %s\n' "$L" > /etc/mysql/mariadb.conf.d/63-mejoland-sin-zabbix.cnf
  if [ "$(cat /var/lib/mejoland-ha/estado 2>/dev/null)" = ESPERA ]; then
    mysql -e "STOP SLAVE SQL_THREAD; SET GLOBAL replicate_wild_ignore_table='$L'; START SLAVE SQL_THREAD;" \
      && echo "  replicate_wild_ignore_table = $(mysql -N -e 'SELECT @@replicate_wild_ignore_table')"
    sleep 2; mysql -e "SHOW SLAVE STATUS\G" | grep -E "Slave_IO_Running:|Slave_SQL_Running:" | sed 's/^ */  /'
  else
    echo "  (damian no esta en ESPERA: el filtro queda guardado y se aplica al reiniciar MariaDB; avisame)"
  fi
fi
echo; echo "LISTO en $ROL. Respaldo: /root/proyecto/mejoland-ha-antes-exclusiones-$TS"
