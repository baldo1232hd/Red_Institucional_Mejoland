#!/bin/bash
# =====================================================================
#  Alta disponibilidad: ajustes del vigilante para carga alta (ejecutar en SRV-BD y en damian-1, root)
#   1 Tolerancia a carga: 6 fallos seguidos y esperas de 10 s / 8 s antes de declarar caido a SRV-BD.
#   2 La base 'zabbix' (historial de monitoreo) no se copia en las conmutaciones ni se replica a damian-1.
#   3 SRV-BD calcula la epoca despues de copiar los datos, para que los dos servidores nunca
#     queden con la misma epoca.
#   4 damian-1 espera hasta 30 min a que SRV-BD retome el servicio.
#  Guarda respaldo en /root/proyecto/. Uso:  bash 09-ha-ajustes-vigilante.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
H=/usr/local/sbin/mejoland-ha; C=/etc/mejoland-ha/ha.conf
[ -f $H ] && [ -f $C ] || { echo "No encuentro $H o $C"; exit 1; }
grep -q '^PRINCIPAL_TS=' $C && ROL=damian || ROL=srv-bd
echo "Equipo: $ROL"
TS=$(date +%Y%m%d-%H%M%S); mkdir -p /root/proyecto
cp -a $H /root/proyecto/mejoland-ha-antes-ajustes-$TS; cp -a $C /root/proyecto/ha.conf-antes-ajustes-$TS

echo "== 1-3 Vigilante"
ROL=$ROL python3 - "$H" <<'PY'
import os, sys
p = sys.argv[1]; s = open(p).read(); rol = os.environ['ROL']; c = 0
def rep(a, b, todos=False):
    global s, c
    if b in s and a not in s: return
    if a in s: s = s.replace(a, b) if todos else s.replace(a, b, 1); c += 1
rep("|mejoland_ha)$'", "|mejoland_ha|zabbix)$'")
rep("--max-time 5 ", "--max-time 10 ", True)
rep("timeout 4 mysql $MON", "timeout 8 mysql $MON", True)
if rol == 'srv-bd':
    a = "  echo $N > $D/epoca; EPOCA=$N\n"
    b = ("  # epoca calculada despues de copiar (damian pudo incrementarla mientras tanto)\n"
         "  UP=$(num \"$(cat $D/epoca_par 2>/dev/null)\"); [ \"$(num \"$P_EPO\")\" -gt \"$UP\" ] && UP=$(num \"$P_EPO\")\n"
         "  N=$(( (UP > EPOCA ? UP : EPOCA) + 1 ))\n" + a)
    if "epoca calculada despues de copiar" not in s:
        assert a in s, "no encuentro el calculo de epoca"; s = s.replace(a, b, 1); c += 1
open(p, 'w').write(s); print(f"  cambios aplicados: {c}")
PY
[ $? -eq 0 ] && bash -n $H || { echo "ERROR: restaurando"; cp -a /root/proyecto/mejoland-ha-antes-ajustes-$TS $H; exit 1; }
grep -q "mejoland_ha|zabbix" $H && echo "  zabbix excluida de las copias: OK"
grep -q "timeout 8 mysql" $H && echo "  esperas 10 s / 8 s: OK"

echo "== 1/4 Configuracion"
sed -i '/^FALLOS_MAX=/d' $C; echo 'FALLOS_MAX=6' >> $C
if [ $ROL = damian ]; then sed -i '/^TIEMPO_MAX_ENTREGA=/d' $C; echo 'TIEMPO_MAX_ENTREGA=1800' >> $C; fi
grep -E '^(FALLOS_MAX|TIEMPO_MAX_ENTREGA)=' $C | sed 's/^/  /'

if [ $ROL = damian ]; then
  echo "== 2 Replica: damian-1 ya no copia la base zabbix"
  cat > /etc/mysql/mariadb.conf.d/63-mejoland-sin-zabbix.cnf <<'CNF'
# Mejoland: el historial de Zabbix no se replica (no es un servicio de alta disponibilidad)
[mysqld]
replicate_wild_ignore_table = zabbix.%
CNF
  mysql -e "STOP SLAVE SQL_THREAD; SET GLOBAL replicate_wild_ignore_table='zabbix.%'; START SLAVE SQL_THREAD;" \
    && echo "  replicate_wild_ignore_table = $(mysql -N -e 'SELECT @@replicate_wild_ignore_table')"
  sleep 2; mysql -e "SHOW SLAVE STATUS\G" | grep -E "Slave_IO_Running:|Slave_SQL_Running:|Seconds_Behind" | sed 's/^ */  /'
fi
echo; mejoland-ha estado | head -3
echo; echo "LISTO en $ROL. Respaldo: /root/proyecto/mejoland-ha-antes-ajustes-$TS"
