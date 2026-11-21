#!/bin/bash
# Centro Educativo Mejoland - Roundcube con base de datos LOCAL (SQLite) en el HP de correo
# Objetivo: que el correo web NO dependa del MariaDB de SRV-BD.
# Ejecutar como root en root@correo:  bash 03-roundcube-bd-local.sh
set -euo pipefail

CFG=/etc/roundcube/config.inc.php
DBDIR=/var/lib/roundcube/db
DBFILE=$DBDIR/roundcube.db
STAMP=$(date +%Y%m%d-%H%M)
BK=/root/proyecto/roundcube-bd-local-$STAMP

[ "$(id -u)" = 0 ] || { echo "Ejecuta como root"; exit 1; }
[ -f "$CFG" ] || { echo "No existe $CFG"; exit 1; }

echo "== 1. Respaldo en $BK"
mkdir -p "$BK"
cp -a "$CFG" "$BK/"
[ -f /etc/roundcube/debian-db.php ] && cp -a /etc/roundcube/debian-db.php "$BK/"
cat > "$BK/deshacer.sh" <<UNDO
#!/bin/bash
cp -a $BK/config.inc.php $CFG
echo "Roundcube vuelve a usar la base de SRV-BD."
UNDO
chmod +x "$BK/deshacer.sh"
grep -n "db_dsnw" "$CFG" | sed -E "s#(://[^:]+:)[^@]+@#\1***@#"

echo "== 2. Soporte SQLite en PHP"
if ! php -m 2>/dev/null | grep -qi '^pdo_sqlite$'; then
  echo "Instalando php-sqlite3..."
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq php-sqlite3
  REINICIAR=1
else
  echo "pdo_sqlite ya disponible"
  REINICIAR=0
fi

echo "== 3. Crear base local $DBFILE"
SQL=$(ls /usr/share/roundcube/SQL/sqlite.initial.sql 2>/dev/null || find / -path /proc -prune -o -name sqlite.initial.sql -print 2>/dev/null | head -1)
[ -n "$SQL" ] && [ -f "$SQL" ] || { echo "No encuentro sqlite.initial.sql de Roundcube"; exit 1; }
echo "Esquema: $SQL"
mkdir -p "$DBDIR"
if [ -s "$DBFILE" ]; then
  echo "La base ya existe, se conserva."
else
  php -r '$p=new PDO("sqlite:".$argv[1]); $p->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION); $p->exec(file_get_contents($argv[2])); echo "Tablas creadas\n";' "$DBFILE" "$SQL"
fi
chown -R www-data:www-data "$DBDIR"
chmod 750 "$DBDIR"; chmod 640 "$DBFILE"

echo "== 4. Apuntar Roundcube a la base local"
NUEVA="\$config['db_dsnw'] = 'sqlite:///$DBFILE?mode=0640';"
if grep -q "^\$config\['db_dsnw'\]" "$CFG"; then
  sed -i "s#^\$config\['db_dsnw'\].*#$NUEVA#" "$CFG"
else
  echo "$NUEVA" >> "$CFG"
fi
grep -n "db_dsnw" "$CFG"

echo "== 5. Comprobaciones"
sudo -u www-data php -r '$p=new PDO("sqlite:".$argv[1]); echo "Lectura OK como www-data, version esquema: ".$p->query("SELECT value FROM system WHERE name=\"roundcube-version\"")->fetchColumn()."\n";' "$DBFILE"

if [ "$REINICIAR" = 1 ]; then
  for s in apache2 nginx $(systemctl list-units --type=service --no-legend 'php*-fpm*' 2>/dev/null | awk '{print $1}'); do
    systemctl is-active -q "$s" 2>/dev/null && { systemctl restart "$s"; echo "Reiniciado $s"; }
  done
fi
sleep 1
CODE=$(curl -s -o /tmp/rc.html -w "%{http_code}" http://127.0.0.1/roundcube/ || true)
echo "Webmail local: HTTP $CODE"
if grep -qi "DATABASE ERROR\|CONNECTION FAILED" /tmp/rc.html 2>/dev/null; then
  echo "ERROR: Roundcube no abre la base. Deshaciendo..."; bash "$BK/deshacer.sh"; exit 1
fi
grep -q "rcmloginuser\|_user" /tmp/rc.html && echo "Pantalla de login OK"

echo
echo "LISTO. Roundcube ya no usa SRV-BD. Todos tendran que iniciar sesion de nuevo una vez"
echo "(las preferencias guardadas en la base vieja no se copian; los correos NO se tocan)."
echo "Para volver atras: bash $BK/deshacer.sh"
