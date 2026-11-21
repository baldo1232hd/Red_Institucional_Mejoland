#!/bin/bash
# =====================================================================
#  EduNova: LDAP de respaldo (ejecutar en SRV-BD, root)
#  Agrega la replica LDAP de damian (srv-bd-replica) a LDAP_URL de EduNova: si el LDAP de
#  SRV-BD no responde, la plataforma valida los inicios de sesion contra la replica.
#  Requisitos: EduNova instalada (edunova/instalar-edunova.sh) y la replica LDAP funcionando
#  (damian/02-replica-ldap-damian.sh).
#  Uso:  bash 04-respaldo-edunova.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
REPLICA=${REPLICA:-ldap://srv-bd-replica.proyecto.local:389}
B=/var/www/lms-backend; E=$B/.env
[ -f $E ] || { echo "No existe $E (EduNova no esta instalada)"; exit 1; }
ldapsearch -x -LLL -H $REPLICA -b dc=proyecto,dc=local -s base dn >/dev/null 2>&1 \
  || { echo "La replica $REPLICA no responde. No se cambio nada."; exit 1; }

BK=/root/proyecto/edunova-ldap-backup-$(date +%Y%m%d-%H%M); mkdir -p "$BK"; chmod 700 "$BK"
cp -a $E "$BK/"
printf '#!/bin/bash\ncp -a %s/.env %s/\nsystemctl restart lms; echo restaurado\n' "$BK" "$B" > "$BK/restaurar.sh"; chmod 700 "$BK/restaurar.sh"

ACT=$(sed -n 's/^LDAP_URL=//p' $E | tr -d "\"'" | tail -1); ACT=${ACT:-ldap://127.0.0.1:389}
case " $ACT " in *" $REPLICA "*) NUEVO="$ACT";; *) NUEVO="$(echo "$ACT" | awk '{print $1}') $REPLICA";; esac
sed -i '/^LDAP_URL=/d' $E; [ -n "$(tail -c1 $E)" ] && echo >> $E; echo "LDAP_URL=\"$NUEVO\"" >> $E
echo "LDAP_URL=\"$NUEVO\"  (principal primero, replica despues)"
systemctl restart lms; sleep 3
systemctl --no-pager status lms | sed -n '3p'
echo -n "Pagina: "; curl -s -o /dev/null -w "%{http_code} (esperado 200)\n" http://127.0.0.1:3001/
echo "LISTO. Si el LDAP de SRV-BD no responde, EduNova usa la replica (journalctl -u lms | grep LDAP)."
echo "Deshacer: bash $BK/restaurar.sh"
