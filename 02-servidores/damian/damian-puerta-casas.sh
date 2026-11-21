#!/bin/bash
# =====================================================================
#  DAMIAN = PUERTA PARA LAS CASAS - Centro Educativo Mejoland   (ejecutar en DAMIAN como root)
#  SIN tocar la topologia: desde Internet (casas) solo se llega a damian (publicado 10.1.40.13).
#  Este script pone en damian un proxy HTTPS que sirve TODO por esa misma direccion:
#     https://10.1.40.13/plataforma/  -> EduNova de damian (127.0.0.1:3001)
#     https://10.1.40.13/webmail/     -> correo (192.168.60.10) por dentro
#     https://10.1.40.13/glpi/ /nube/ -> correo -> srv-apps
#  y marca a las casas como "Internet": EduNova les da enlaces relativos (/webmail/, /nube/, /glpi/)
#  y oculta Secretaria, LAM y Zabbix.
#  Deshacer:  bash /root/proyecto/puerta-casas-<fecha>/deshacer.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root (sudo -i)"; exit 1; }
case "$(hostname -s | tr A-Z a-z)" in damian*) ;; *) echo "Este script es para DAMIAN"; exit 1;; esac
PUB=10.1.40.13; CORREO=192.168.60.10; E=/var/www/lms-backend/.env
BK=/root/proyecto/puerta-casas-$(date +%Y%m%d-%H%M%S); mkdir -p $BK; chmod 700 $BK
ok() { echo "  [OK] $*"; }; av() { echo "  [AVISO] $*"; }
echo "################ DAMIAN: PUERTA PARA LAS CASAS ################"

echo; echo "== 1 Que hay en los puertos 80 y 443"
OCUP=$(ss -tlnpH '( sport = :80 or sport = :443 )' 2>/dev/null)
echo "$OCUP" | awk 'NF{print "    "$4"  "$6}'
if echo "$OCUP" | grep -q . && ! echo "$OCUP" | grep -q apache2; then
  av "otro programa (no Apache) usa el 80/443. No cambio nada: manda foto de este bloque."; exit 1; fi
if ! command -v apache2ctl >/dev/null; then
  echo "  Instalando Apache..."; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq apache2 >/dev/null 2>&1 \
    && ok "Apache instalado" || { av "no se pudo instalar Apache (sin Internet en damian?)"; exit 1; }
fi
a2enmod -q ssl proxy proxy_http headers substitute filter >/dev/null 2>&1 && ok "modulos ssl proxy headers substitute"

echo; echo "== 2 Certificado para $PUB"
C=/etc/mejoland/puerta; mkdir -p $C; chmod 700 $C
if [ ! -f $C/puerta.crt ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 825 -sha256 -subj "/O=Centro Educativo Mejoland/CN=$PUB" \
    -addext "subjectAltName=IP:$PUB,DNS:mejoland.edu.ec,DNS:damian.proyecto.local" \
    -keyout $C/puerta.key -out $C/puerta.crt 2>/dev/null && ok "certificado propio creado (el navegador avisara: Avanzado -> Continuar)"
fi
chmod 600 $C/puerta.key

echo; echo "== 3 Sitio de Apache 'mejoland-puerta'"
S=/etc/apache2/sites-available/mejoland-puerta.conf; [ -f $S ] && cp -a $S $BK/
cat > $S <<EOF
# Centro Educativo Mejoland - PUERTA DE LAS CASAS en damian (publicado como $PUB por R1/R3)
<VirtualHost *:80>
    ServerName $PUB
    ServerAlias 192.168.40.13 damian.proyecto.local
    RedirectMatch ^/(.*)\$ https://$PUB/\$1
</VirtualHost>
<VirtualHost *:443>
    ServerName $PUB
    ServerAlias 192.168.40.13 damian.proyecto.local
    SSLEngine on
    SSLCertificateFile    $C/puerta.crt
    SSLCertificateKeyFile $C/puerta.key
    Header always set X-Content-Type-Options nosniff
    # Red interna = VLAN del colegio, servidores y Tailscale. Las casas (192.168.100/200, 10.x) = Internet.
    SetEnvIf Remote_Addr "^(127\.|192\.168\.(10|20|30|40|50|60|99)\.|172\.16\.100\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)" red_interna
    RequestHeader set X-Mejoland-Internet "1" env=!red_interna
    RequestHeader unset X-Mejoland-Internet env=red_interna
    RequestHeader set X-Forwarded-Proto "https"
    RedirectMatch ^/\$ /plataforma/
    RedirectMatch ^/(plataforma|webmail|glpi|nube)\$ /\$1/
    <LocationMatch "^/(lam|secretaria|zabbix|phpmyadmin|grafana)">
        Require all denied
    </LocationMatch>
    SSLProxyEngine on
    SSLProxyVerify none
    SSLProxyCheckPeerName off
    SSLProxyCheckPeerCN off
    SSLProxyCheckPeerExpire off
    ProxyRequests off
    ProxyTimeout 120
    # EduNova de este servidor
    ProxyPass        /plataforma/ http://127.0.0.1:3001/
    ProxyPassReverse /plataforma/ http://127.0.0.1:3001/
    # Correo web, GLPI y nube: se piden al proxy del correo por dentro de la red
    <LocationMatch "^/(webmail|roundcube|glpi|nube)/">
        RequestHeader unset Accept-Encoding
        AddOutputFilterByType SUBSTITUTE text/html text/css application/javascript application/json
        Substitute "s|https://mejoland\.edu\.ec/|/|n"
        Substitute "s|https://$CORREO/|/|n"
    </LocationMatch>
EOF
for p in webmail roundcube glpi nube; do cat >> $S <<EOF
    ProxyPass        /$p/ https://$CORREO/$p/
    ProxyPassReverse /$p/ https://$CORREO/$p/
    ProxyPassReverse /$p/ https://mejoland.edu.ec/$p/
EOF
done
cat >> $S <<'EOF'
    ErrorLog ${APACHE_LOG_DIR}/mejoland-puerta-error.log
    CustomLog ${APACHE_LOG_DIR}/mejoland-puerta.log combined
</VirtualHost>
EOF
a2ensite -q mejoland-puerta >/dev/null 2>&1
if apache2ctl configtest >/dev/null 2>&1; then systemctl reload apache2 2>/dev/null || systemctl restart apache2; ok "Apache: sitio mejoland-puerta activo (80 -> 443)"
else av "error en Apache: desactivo el sitio"; apache2ctl configtest 2>&1 | tail -3; a2dissite -q mejoland-puerta; systemctl reload apache2; exit 1; fi

echo; echo "== 4 EduNova reconoce a este proxy (127.0.0.1) para marcar las visitas de Internet"
cp -a $E $BK/
if grep -q '^PROXY_DMZ=' $E; then
  grep -q '^PROXY_DMZ=.*127\.0\.0\.1' $E || sed -i 's/^PROXY_DMZ="\?\([^"]*\)"\?/PROXY_DMZ="\1,127.0.0.1"/' $E
else echo 'PROXY_DMZ="192.168.60.10,100.65.119.48,127.0.0.1"' >> $E; fi
grep '^PROXY_DMZ=' $E | sed 's/^/    /'
python3 - <<'PY'
import json
d = json.load(open('/etc/edunova/servicios.json', encoding='utf-8'))
for s in d['servicios']:
    print(f"    {s['id']:<12} url_publica: {s.get('url_publica') or '- (no se muestra desde Internet)'}")
PY
systemctl restart lms && sleep 3 && ok "EduNova reiniciado"

echo; echo "== 5 Cortafuegos"
if ufw status 2>/dev/null | grep -q "Status: active"; then ufw allow 80,443/tcp >/dev/null && ok "ufw: 80 y 443 abiertos"; else echo "  ufw no activo"; fi

cat > $BK/deshacer.sh <<EOF
#!/bin/bash
a2dissite -q mejoland-puerta; systemctl reload apache2
cp -a $BK/.env $E && systemctl restart lms
echo "Puerta de las casas quitada; EduNova como antes."
EOF
chmod 700 $BK/deshacer.sh

echo; echo "== 6 Pruebas como si fuera una casa (200/301/302 = bien; 000/502 = no llega al correo)"
for p in plataforma/ webmail/ glpi/ nube/; do
  printf '    %-36s %s\n' "https://$PUB/$p" "$(curl -sk -o /dev/null -m 15 -w '%{http_code}' --resolve $PUB:443:127.0.0.1 https://$PUB/$p)"
done
echo "    correo por dentro (https://$CORREO/webmail/): $(curl -sk -o /dev/null -m 8 -w '%{http_code}' https://$CORREO/webmail/)"
echo
echo "LISTO. Desde la casa (celular):  https://$PUB/plataforma/   (aviso de certificado: Avanzado -> Continuar)"
echo "Deshacer: bash $BK/deshacer.sh"
