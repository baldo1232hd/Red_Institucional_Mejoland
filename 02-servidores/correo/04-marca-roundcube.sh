#!/bin/bash
# =====================================================================
#  Roundcube con la imagen de Centro Educativo Mejoland (estilo EduNova)
#  Verde institucional + dorado, logo en sello, fondo con foto del campus.
#  Solo agrega un plugin con hoja de estilos: no cambia funciones.
#  Antes: copiar a /tmp  logo.jpg  biblioteca.jpg  y este script.
#  Uso (root en el servidor de correo):  bash 04-marca-roundcube.sh
#  Deshacer: bash /root/proyecto/roundcube-marca-backup/deshacer.sh
# =====================================================================
set -u
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar como root"; exit 1; }
for f in logo.jpg biblioteca.jpg; do [ -f /tmp/$f ] || { echo "Falta /tmp/$f"; exit 1; }; done
CFG=/etc/roundcube/config.inc.php
[ -f $CFG ] || { echo "No existe $CFG"; exit 1; }
# Debian: /var/lib/roundcube/plugins es la carpeta que Roundcube carga (con enlaces a /usr/share)
if [ -d /var/lib/roundcube/plugins ]; then PLUG=/var/lib/roundcube/plugins; else PLUG=/usr/share/roundcube/plugins; fi
[ -d "$PLUG" ] || { echo "No encuentro la carpeta de plugins de Roundcube. No se cambio nada."; exit 1; }
P=$PLUG/mejoland_tema

BK=/root/proyecto/roundcube-marca-backup
mkdir -p $BK; chmod 700 $BK
[ -f $BK/config.inc.php ] || cp -a $CFG $BK/config.inc.php
cat > $BK/deshacer.sh <<EOF
#!/bin/bash
cp -a $BK/config.inc.php $CFG
rm -rf $P
systemctl reload apache2
echo "Roundcube volvio a su aspecto original."
EOF
chmod 700 $BK/deshacer.sh

echo "== Plugin de tema en $P"
mkdir -p $P
install -m 644 /tmp/logo.jpg $P/logo.jpg
install -m 644 /tmp/biblioteca.jpg $P/fondo.jpg
cat > $P/mejoland_tema.php <<'EOF'
<?php
/** Tema Centro Educativo Mejoland: solo agrega una hoja de estilos (no cambia funciones). */
class mejoland_tema extends rcube_plugin
{
    public $task = '.*';
    function init() { $this->include_stylesheet('tema.css'); }
}
EOF
cat > $P/tema.css <<'EOF'
/* Centro Educativo Mejoland - verde #14532A / #0D3A1D, dorado #C9A227, crema #F7F4EC */
:root { --mj-verde:#14532A; --mj-osc:#0D3A1D; --mj-dorado:#C9A227; --mj-crema:#F7F4EC; }

/* ---------- Pantalla de ingreso ---------- */
body.task-login {
  background: linear-gradient(115deg, rgba(13,58,29,.93) 0%, rgba(20,83,42,.80) 55%, rgba(13,58,29,.55) 100%),
              url(fondo.jpg) center 30% / cover no-repeat fixed !important;
}
body.task-login #layout, body.task-login #layout-content { background: transparent !important; }
body.task-login #logo {
  width: 116px; height: 116px; max-height: none; object-fit: contain;
  background: #fff; border-radius: 50%; padding: 6px;
  border: 3px solid var(--mj-dorado); box-shadow: 0 10px 30px rgba(0,0,0,.35);
  margin-bottom: 1.25rem;
}
body.task-login #login-form {
  background: #fff; border-radius: 16px; padding: 2rem 2rem 1.5rem;
  border-top: 5px solid var(--mj-dorado); box-shadow: 0 24px 60px rgba(0,0,0,.38);
  max-width: 400px;
}
body.task-login #login-form::before {
  content: "Correo institucional"; display: block; margin-bottom: 1.1rem;
  font: 600 1.6rem/1.2 Georgia, "Times New Roman", serif; color: var(--mj-verde); text-align: center;
}
body.task-login #login-form input.form-control { background: var(--mj-crema); border-color: #d9d3c3; }
body.task-login #login-form input.form-control:focus { border-color: var(--mj-verde); box-shadow: 0 0 0 3px rgba(20,83,42,.18); }
body.task-login #login-footer, body.task-login #login-footer a { color: #6b7280 !important; font-size: .82rem; }
body.task-login #login-footer::before {
  content: "Centro Educativo Mejoland · Use su usuario y la clave institucional · ¿La olvidó? Acuda a Secretaría con su cédula";
  display: block; margin: .2rem 0 .4rem; padding-top: .9rem; border-top: 1px solid #ece7da; color: var(--mj-verde);
}

/* ---------- Botones ---------- */
.btn-primary, button.mainaction, input.mainaction, .button.mainaction, a.button.mainaction {
  background-color: var(--mj-verde) !important; border-color: var(--mj-verde) !important; color: #fff !important;
  border-radius: 10px;
}
.btn-primary:hover, button.mainaction:hover, .btn-primary:focus, button.mainaction:focus {
  background-color: var(--mj-osc) !important; border-color: var(--mj-osc) !important;
}

/* ---------- Menu lateral ---------- */
#layout-menu { background: var(--mj-osc) !important; }
#layout-menu #logo { background: #fff; border-radius: 50%; padding: 3px; border: 2px solid var(--mj-dorado); max-height: 64px; object-fit: contain; }
#layout-menu .menu a, #layout-menu .special-buttons a { color: rgba(255,255,255,.82) !important; }
#layout-menu .menu a:hover, #layout-menu .special-buttons a:hover { color: #fff !important; background: rgba(255,255,255,.08) !important; }
#layout-menu .menu a.selected { color: #fff !important; background: rgba(255,255,255,.12) !important; box-shadow: inset 3px 0 0 var(--mj-dorado); }

/* ---------- Encabezados, listas y detalles ---------- */
.header .header-title, #layout-content .header .header-title { font-family: Georgia, "Times New Roman", serif; color: var(--mj-verde); }
.listing li.selected, .listing li.selected > a, table.records-table tr.selected td, table.records-table tr.selected td a {
  background-color: #E7F1EA !important; color: var(--mj-osc) !important;
}
table.records-table tr.unread td span.subject a, table.records-table tr.unread td .subject a { color: var(--mj-verde); }
.listing li.mailbox.inbox > a .unreadcount, .unreadcount, .badge-primary { background-color: var(--mj-verde) !important; }
.custom-switch .custom-control-input:checked ~ .custom-control-label::before,
.custom-control-input:checked ~ .custom-control-label::before { background-color: var(--mj-verde) !important; border-color: var(--mj-verde) !important; }
a, .btn-link { color: var(--mj-verde); }
/* Contraste: texto oscuro y legible */
body.task-login #login-form input.form-control,
body.task-login #login-form input.form-control:-webkit-autofill {
  color: #111827 !important; -webkit-text-fill-color: #111827 !important; font-weight: 500; opacity: 1 !important;
  font-size: 1rem; -webkit-box-shadow: 0 0 0 40px #F7F4EC inset !important;
}
body.task-login #login-form input.form-control::placeholder { color: #4b5563 !important; -webkit-text-fill-color: #4b5563 !important; opacity: 1; }
body.task-login #login-form .input-group-text { background: #14532A !important; color: #fff !important; border-color: #14532A !important; opacity: 1 !important; }
body.task-login #login-footer, body.task-login #login-footer a { color: #374151 !important; font-size: .9rem; opacity: 1 !important; }
body.task-login #login-footer::before { color: #0D3A1D !important; font-weight: 600; }
.popover .listing a:hover, .menu a:focus { outline-color: var(--mj-dorado); }
#layout-menu .special-buttons, #layout-menu .popover-header { background: var(--mj-osc) !important; border-top: 1px solid rgba(255,255,255,.12); }
#layout-menu #logo { margin-top: 6px; }
/* ---------- Bandeja: modo claro ---------- */
#layout-sidebar .header .header-title, #layout-sidebar .header-title { color: var(--mj-verde); font-weight: 600; }
#layout-sidebar .header, #layout-list .header, #layout-content .header { border-bottom: 2px solid var(--mj-dorado) !important; }
#folderlist-content li.mailbox.selected > a, #folderlist-content li.selected > a {
  background: #E7F1EA !important; color: var(--mj-osc) !important; box-shadow: inset 3px 0 0 var(--mj-dorado); font-weight: 600;
}
#folderlist-content li.mailbox > a:hover { background: #F2F7F3 !important; }
#layout-menu .menu a.selected, #layout-menu .menu a.selected:before { color: #fff !important; }

/* ---------- Bandeja: modo oscuro ---------- */
html.dark-mode #layout-sidebar .header .header-title, html.dark-mode #layout-sidebar .header-title { color: #E9D48A !important; }
html.dark-mode #folderlist-content li.mailbox.selected > a, html.dark-mode #folderlist-content li.selected > a,
html.dark-mode .listing li.selected, html.dark-mode .listing li.selected > a,
html.dark-mode table.records-table tr.selected td, html.dark-mode table.records-table tr.selected td a {
  background: #1E4D2E !important; color: #fff !important;
}
html.dark-mode #folderlist-content li.mailbox > a:hover { background: #183F26 !important; }
html.dark-mode a, html.dark-mode .btn-link, html.dark-mode table.records-table tr.unread td .subject a { color: #9FD8B2; }
html.dark-mode .btn-primary, html.dark-mode button.mainaction { background-color: #1B6B37 !important; border-color: #1B6B37 !important; }
html.dark-mode .unreadcount, html.dark-mode .badge-primary { background-color: #1B6B37 !important; }
EOF
cat > $P/watermark.html <<'EOF'
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title></title>
<style>
html, body { height: 100%; margin: 0; overflow: hidden; font-family: Georgia, "Times New Roman", serif; }
body { display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 14px; background: #F7F4EC; color: #14532A; }
img { width: 170px; height: 170px; border-radius: 50%; background: #fff; padding: 6px; border: 3px solid #C9A227; object-fit: contain; opacity: .9; }
p { margin: 0; font-size: 20px; }
small { font-family: system-ui, sans-serif; font-size: 12px; letter-spacing: .2em; text-transform: uppercase; color: #8a7a3a; }
html.dark-mode body { background: #21292c; color: #E9D48A; }
html.dark-mode img { opacity: .75; }
html.dark-mode small { color: #9aa5a1; }
</style>
<script>
  try {
    if (document.cookie.indexOf('colorMode=dark') > -1
      || (document.cookie.indexOf('colorMode=light') === -1 && window.matchMedia('(prefers-color-scheme: dark)').matches))
      document.documentElement.className += ' dark-mode';
  } catch (e) {}
</script>
</head>
<body>
<img src="logo.jpg" alt="Centro Educativo Mejoland">
<p>Centro Educativo Mejoland</p>
<small>Correo institucional</small>
</body>
</html>
EOF
chmod -R a+rX $P

echo "== Configuracion (nombre, logo y plugin)"
# Reemplaza el bloque de marca existente por el actual
sed -i -e '/PROYECTO-MARCA/d' \
       -e "/^\$config\['plugins'\]\[\] = 'mejoland_tema';/d" \
       -e "/^\$config\['product_name'\] = 'Correo · Centro Educativo Mejoland';/d" \
       -e "/^\$config\['skin_logo'\] = .*mejoland/d" \
       -e "/^\$config\['blankpage_url'\] = .*mejoland_tema/d" $CFG
cat >> $CFG <<'EOF'
// PROYECTO-MARCA: Centro Educativo Mejoland
$config['product_name'] = 'Correo · Centro Educativo Mejoland';
$config['skin_logo'] = 'plugins/mejoland_tema/logo.jpg';
$config['blankpage_url'] = 'plugins/mejoland_tema/watermark.html';
$config['plugins'][] = 'mejoland_tema';
EOF
php -l $CFG >/dev/null && echo "config.inc.php: sintaxis OK" || { echo "ERROR de sintaxis: restaurando"; cp -a $BK/config.inc.php $CFG; exit 1; }
rm -f /var/www/html/logo-mejoland.jpg 2>/dev/null
systemctl reload apache2
echo
echo "LISTO. Abre el correo web con Ctrl+F5. Para volver atras: bash $BK/deshacer.sh"
