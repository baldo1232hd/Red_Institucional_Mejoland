<?php
/**
 * Panel de Secretaria - Centro Educativo Mejoland
 * Servidor: SRV-BD (Debian 13, PHP 8.4-FPM con el usuario secretariaweb, OpenLDAP dc=proyecto,dc=local).
 * Sin dependencias externas (no usa Composer ni base de datos adicional).
 *
 * Acceso con la cuenta institucional (LDAP, la misma del correo y de EduNova):
 *   grupo secretaria -> rol registro;   grupo administracion -> rol administrador.
 *   Las cuentas locales de /etc/secretaria/usuarios-web.json funcionan como respaldo.
 *
 * Funciones:
 *   - Alta de estudiantes y docentes en ou=Altas: usuario con primer apellido (compuestos y dobles),
 *     uidNumber unico, contrasena legible para dictar y documento de identidad obligatorio y unico
 *     (cedula ecuatoriana validada o pasaporte), con aviso de homonimos.
 *   - Restablecimiento de claves (verificando la cedula del titular), bloqueo temporal de altas
 *     recientes y rehabilitacion de cuentas suspendidas. Nunca elimina registros ni buzones.
 *   - Directorio con busqueda por nombre, rol o cedula (LDAP paginado) y ultimas altas.
 *   - Ficha institucional de entrega de cuenta en Word (.docx) con logo, datos de acceso,
 *     servicios y firmas de entrega y recepcion.
 *   - Auditoria de cada accion en /var/lib/secretaria/auditoria.tsv.
 *
 * Seguridad: sesion con expiracion por inactividad y maxima, CSRF, limite de intentos por cuenta,
 * contrasenas con password_hash y cuenta de servicio LDAP (cn=svc-secretaria) con permisos
 * de escritura solo sobre ou=Altas.
 */
declare(strict_types=1);

date_default_timezone_set('America/Guayaquil');

const LDAP_URI = 'ldap://127.0.0.1:389';
const LDAP_BASE = 'dc=proyecto,dc=local';
const PERSONAS_BASE = 'ou=Personas,dc=proyecto,dc=local';
const ALTAS_BASE = 'ou=Altas,ou=Personas,dc=proyecto,dc=local';
const SERVICE_DN = 'cn=svc-secretaria,dc=proyecto,dc=local';
const SERVICE_PASSWORD_FILE = '/etc/secretaria/ldap-service-password';
const MAIL_DOMAIN = 'mejoland.edu.ec';
const STATE_DIR = '/var/lib/secretaria';
const MAX_USERS_IN_TABLE = 100;
// Habilita el alta de cuentas nuevas.
const ENABLE_REGISTRATION = true;
// Archivo con [operadores] nombre_login = consulta|registro|administrador.
// Si no existe o el nombre no esta incluido, se deniega el acceso (HTTP 403).
const OPERATOR_ROLES_FILE = '/etc/secretaria/operadores.ini';
const WEB_USERS_FILE = '/etc/secretaria/usuarios-web.json';
const LOGIN_IDLE_SECONDS = 1200; // 20 minutos sin actividad.
const LOGIN_ABSOLUTE_SECONDS = 28800; // 8 horas maximo.
const LOGIN_MAX_FAILURES = 5;
const LOGIN_FAILURE_WINDOW = 900; // 15 minutos.
const LDAP_PAGE_SIZE = 150;
const LDAP_MAX_PAGES = 30;
const UID_MIN = 10903;
const UID_MAX = 11999;
// Particulas que forman parte del apellido: "de la Torre" -> delatorre
// El bloqueo de autenticacion de altas recientes solo se permite durante este tiempo.
const SUSPENDER_HORAS = 48;
// Datos que aparecen en la ficha del usuario. Cambiarlos aqui si cambia la red.
const WEBMAIL_URL = 'https://mejoland.edu.ec/webmail/';
const MAIL_SERVER = 'mejoland.edu.ec';
const WIFI_SSID = 'ESTUDIANTES';
const INSTITUCION = 'Centro Educativo Mejoland';
// Logo de la ficha (JPG o PNG). Si no existe, la ficha sale sin logo.
const LOGO_FILE = '/etc/secretaria/logo.jpg';
// Direccion de la plataforma EduNova (cambiar en el laboratorio si se publica en otra direccion).
const PLATAFORMA_URL = 'https://mejoland.edu.ec/plataforma/';
// Huella SHA-256 del certificado de FreeRADIUS, para que el usuario lo verifique al
// conectarse al Wi-Fi. Se obtiene en SRV-AAA-1 con:
//   openssl x509 -in /etc/freeradius/3.0/certs/server.pem -noout -fingerprint -sha256
// Dejar vacio ('') si todavia no se ha obtenido.
const RADIUS_CERT_SHA256 = '';
const SURNAME_PARTICLES = ['de', 'del', 'la', 'las', 'los', 'da', 'das', 'do', 'dos', 'san', 'santa', 'van', 'von', 'y'];

// Este mapeo procede de los grupos que ya existen en el laboratorio.
const GROUPS = [
    'estudiante' => [
        'label' => 'Estudiante',
        'gid' => 12000,
        'dn' => 'cn=estudiantes,ou=Grupos,dc=proyecto,dc=local',
        'unix' => 'unix-estudiantes',
    ],
    'docente' => [
        'label' => 'Docente',
        'gid' => 12001,
        'dn' => 'cn=docentes,ou=Grupos,dc=proyecto,dc=local',
        'unix' => 'unix-docentes',
    ],
];

header('Cache-Control: no-store, private, max-age=0');
header('Pragma: no-cache');
header('X-Robots-Tag: noindex, nofollow, noarchive');
header('X-Content-Type-Options: nosniff');
header('X-Frame-Options: DENY');
header('Referrer-Policy: no-referrer');
header('Content-Security-Policy: default-src \'none\'; style-src \'unsafe-inline\'; img-src data:; form-action \'self\'; base-uri \'none\'; frame-ancestors \'none\'');

if (!extension_loaded('ldap') || !extension_loaded('mbstring')) {
    http_response_code(503);
    exit('Falta la extensión PHP LDAP o mbstring.');
}

// Nombre de sesion propio del panel.
ini_set('session.use_strict_mode', '1');
session_name('secretaria_v9');
// Acceso del navegador por HTTPS.
// No aceptar X-Forwarded-Proto sin validar: un cliente podria falsificarlo.
// Las conexiones HTTPS (o reenviadas desde 127.0.0.1) usan cookie Secure; por HTTP directo
// en la LAN se usa sin Secure. Nunca se confia en X-Forwarded-Proto.
$remote = (string)($_SERVER['REMOTE_ADDR'] ?? '');
$viaTailscale = in_array($remote, ['127.0.0.1', '::1'], true);
$secureCookie = $viaTailscale || (($_SERVER['HTTPS'] ?? '') === 'on');
session_set_cookie_params([
    'lifetime' => 0,
    'path' => '/secretaria/',
    'secure' => $secureCookie,
    'httponly' => true,
    'samesite' => 'Strict',
]);
if (!session_start()) {
    http_response_code(500);
    exit('No se puede iniciar la sesión.');
}
if (empty($_SESSION['csrf'])) {
    session_regenerate_id(true);
    $_SESSION['csrf'] = bin2hex(random_bytes(32));
}

/** Identidad tomada UNICAMENTE de una sesion PHP autenticada por el formulario. */
function operatorName(): ?string {
    $name = $_SESSION['operator'] ?? null;
    return is_string($name) && preg_match('/^[A-Za-z0-9._@-]{1,100}$/D', $name) ? $name : null;
}
/** Rol consultado desde fichero protegido en CADA peticion (revocacion inmediata). */
function operatorRole(?string $operator): ?string {
    if ($operator === null) return null;
    // 0) Sesion iniciada con la cuenta institucional: el rol sale de los grupos LDAP en CADA peticion.
    if (($_SESSION['auth'] ?? '') === 'ldap' && ($_SESSION['operator'] ?? null) === $operator) {
        return ldapPanelRole($operator)['role'] ?? null;
    }
    // 1) Rol guardado junto a la cuenta web (usuarios-web.json).
    static $jsonRoles = null;
    if ($jsonRoles === null) {
        $jsonRoles = [];
        $raw = is_readable(WEB_USERS_FILE) ? @file_get_contents(WEB_USERS_FILE) : false;
        $data = is_string($raw) ? json_decode($raw, true) : null;
        foreach ((is_array($data['users'] ?? null) ? $data['users'] : []) as $n => $u) {
            if (is_array($u) && is_string($u['role'] ?? null)) $jsonRoles[(string)$n] = strtolower($u['role']);
        }
    }
    if (isset($jsonRoles[$operator])) {
        return in_array($jsonRoles[$operator], ['consulta', 'registro', 'administrador'], true) ? $jsonRoles[$operator] : null;
    }
    // 2) Respaldo: archivo operadores.ini.
    if (!is_file(OPERATOR_ROLES_FILE) || !is_readable(OPERATOR_ROLES_FILE)) {
        return null;
    }
    $config = @parse_ini_file(OPERATOR_ROLES_FILE, true, INI_SCANNER_RAW);
    if (!is_array($config) || !is_array($config['operadores'] ?? null)) {
        return null;
    }
    $role = $config['operadores'][$operator] ?? null;
    if (!is_string($role)) return null;
    $role = strtolower(trim($role));
    return in_array($role, ['consulta', 'registro', 'administrador'], true) ? $role : null;
}
function canWrite(?string $role): bool {
    return ENABLE_REGISTRATION && in_array($role, ['registro', 'administrador'], true);
}
function canAdmin(?string $role): bool {
    return ENABLE_REGISTRATION && $role === 'administrador';
}
/** Nunca borrar cuentas publicadas: conservar el uid protege datos en correo y servicios. */
function isSuspended(string $description): bool {
    return str_contains($description, '[SUSPENDIDA-SECRETARIA]');
}
function postString(string $key): string {
    $value = $_POST[$key] ?? '';
    if (!is_string($value)) {
        throw new RuntimeException('Datos de formulario inválidos.');
    }
    return $value;
}
function getString(string $key, string $default = ''): string {
    $value = $_GET[$key] ?? $default;
    return is_string($value) ? $value : $default;
}
function validUid(string $uid): bool {
    return (bool)preg_match('/^[a-z][a-z0-9]{2,29}$/D', $uid);
}
/** Cedula ecuatoriana: 10 digitos, provincia 01-24 o 30, tercer digito < 6 y digito verificador (modulo 10). */
function validCedula(string $c): bool {
    if (!preg_match('/^\d{10}$/D', $c)) return false;
    $prov = (int)substr($c, 0, 2);
    if (!(($prov >= 1 && $prov <= 24) || $prov === 30) || (int)$c[2] >= 6) return false;
    $sum = 0;
    for ($i = 0; $i < 9; $i++) {
        $v = (int)$c[$i] * ($i % 2 === 0 ? 2 : 1);
        $sum += $v > 9 ? $v - 9 : $v;
    }
    return (10 - $sum % 10) % 10 === (int)$c[9];
}
/** Documento normalizado para employeeNumber: "1712345678" (cedula) o "P-AB123456" (pasaporte). */
function documentId(string $type, string $raw): string {
    $raw = strtoupper(preg_replace('/[\s.\-]/', '', $raw) ?? '');
    if ($type === 'cedula') {
        if (!validCedula($raw)) throw new RuntimeException('La cédula no es válida: revisa los 10 dígitos (incluido el verificador).');
        return $raw;
    }
    if ($type === 'pasaporte') {
        if (!preg_match('/^[A-Z0-9]{5,20}$/D', $raw)) throw new RuntimeException('Pasaporte: entre 5 y 20 letras o números.');
        return 'P-' . $raw;
    }
    throw new RuntimeException('Selecciona el tipo de documento.');
}
/** Muestra solo los 4 ultimos caracteres (privacidad en listas y auditoria). */
function maskDoc(string $doc): string {
    if ($doc === '') return '';
    return str_repeat('•', max(0, strlen($doc) - 4)) . substr($doc, -4);
}
/** Busca la cuenta que ya tiene ese documento (en todo el directorio). */
function findByDocument(LDAP\Connection $ldap, string $doc): ?array {
    $r = searchEntries($ldap, LDAP_BASE, '(employeeNumber=' . ldap_escape($doc, '', LDAP_ESCAPE_FILTER) . ')', ['uid', 'cn']);
    return $r['count'] > 0 ? ['uid' => (string)($r[0]['uid'][0] ?? ''), 'cn' => (string)($r[0]['cn'][0] ?? '')] : null;
}
function sshaHash(string $password): string {
    // {SSHA} es compatible con la configuracion actual de este laboratorio LDAP.
    $salt = random_bytes(16);
    return '{SSHA}' . base64_encode(sha1($password . $salt, true) . $salt);
}
/** createTimestamp de LDAP (20261027061719Z) a segundos Unix. */
function ldapTime(string $value): ?int {
    $d = DateTime::createFromFormat('YmdHis\Z', $value, new DateTimeZone('UTC'));
    return $d instanceof DateTime && $d->format('YmdHis\Z') === $value ? $d->getTimestamp() : null;
}
function groupByGid(string $gid): ?array {
    foreach (GROUPS as $key => $g) {
        if ((string)$g['gid'] === $gid) {
            return ['key' => $key] + $g;
        }
    }
    return null;
}
function esc(string $value): string {
    return htmlspecialchars($value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}
function cleanName(string $raw, string $field): string {
    $value = preg_replace('/\s+/u', ' ', trim($raw));
    if (!is_string($value) || mb_strlen($value, 'UTF-8') < 2 || mb_strlen($value, 'UTF-8') > 60 ||
        !preg_match("/^[\\p{L}\\p{M}]+(?:[ '\\-][\\p{L}\\p{M}]+)*$/u", $value)) {
        throw new RuntimeException("El campo $field debe contener entre 2 y 60 caracteres alfabeticos.");
    }
    // "ANA PRUEBA" / "ana prueba" -> "Ana Prueba"; particulas en minuscula (de la Torre)
    $words = explode(' ', mb_convert_case(mb_strtolower($value, 'UTF-8'), MB_CASE_TITLE, 'UTF-8'));
    foreach ($words as $i => $w) {
        if ($i > 0 && in_array(mb_strtolower($w, 'UTF-8'), SURNAME_PARTICLES, true)) {
            $words[$i] = mb_strtolower($w, 'UTF-8');
        }
    }
    return implode(' ', $words);
}
function normalizeUsernamePart(string $name): string {
    $value = mb_strtolower($name, 'UTF-8');
    $value = strtr($value, [
        'á'=>'a','à'=>'a','ä'=>'a','â'=>'a','ã'=>'a',
        'é'=>'e','è'=>'e','ë'=>'e','ê'=>'e',
        'í'=>'i','ì'=>'i','ï'=>'i','î'=>'i',
        'ó'=>'o','ò'=>'o','ö'=>'o','ô'=>'o','õ'=>'o',
        'ú'=>'u','ù'=>'u','ü'=>'u','û'=>'u', 'ñ'=>'n',
    ]);
    $value = preg_replace('/[^a-z0-9]/', '', $value);
    return is_string($value) ? $value : '';
}
/** Devuelve [primer apellido, segundo apellido] respetando particulas (de, del, la...). */
function splitSurnames(string $last): array {
    $tokens = preg_split('/[\s\-]+/u', mb_strtolower($last, 'UTF-8')) ?: [];
    $tokens = array_values(array_filter($tokens, fn($t) => $t !== ''));
    $groups = [];
    $current = '';
    foreach ($tokens as $t) {
        $current .= $t;
        if (!in_array($t, SURNAME_PARTICLES, true)) {
            $groups[] = $current;
            $current = '';
        }
    }
    if ($current !== '') {
        $groups[] = $current;
    }
    return [normalizeUsernamePart($groups[0] ?? ''), normalizeUsernamePart($groups[1] ?? '')];
}
/** Clave aleatoria de 16 caracteres agrupada. Los guiones FORMAN PARTE de la clave. */
function generatePassword(): string {
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
    $lower = 'abcdefghijkmnpqrstuvwxyz';
    $digit = '23456789';
    $all = $upper . $lower . $digit;
    do {
        $chars = '';
        for ($i = 0; $i < 16; $i++) {
            $chars .= $all[random_int(0, strlen($all) - 1)];
        }
    } while (!preg_match('/[A-Z]/', $chars) || !preg_match('/[a-z]/', $chars) || !preg_match('/[2-9]/', $chars));
    return implode('-', str_split($chars, 4));
}
/** Consulta ultimas operaciones sin cargar en memoria todo el archivo. */
function recentRegistrations(int $limit): array {
    $file = STATE_DIR . '/auditoria.tsv';
    if (!is_readable($file)) return [];
    $out = [];
    try {
        $h = @fopen($file, 'rb');
        if (!$h) return [];
        try {
            $stat = fstat($h);
            $size = (int)($stat['size'] ?? 0);
            $start = max(0, $size - 131072);
            if (fseek($h, $start) !== 0) return [];
            if ($start > 0) fgets($h); // omitir primera linea posiblemente cortada
            $text = stream_get_contents($h, 131072);
            if (!is_string($text)) return [];
            foreach (array_reverse(explode("\n", $text)) as $line) {
                $line = trim($line);
                if ($line === '') continue;
                $parts = explode("\t", $line);
                $event = $parts[2] ?? '';
                $labels = [
                    'CREADO' => 'Alta', 'CLAVE_RESTABLECIDA' => 'Nueva contraseña',
                    'SUSPENDIDA' => 'Acceso bloqueado', 'REHABILITADA' => 'Rehabilitada', 'ANULADO' => 'Anulación histórica',
                ];
                if (!isset($labels[$event])) continue;
                $detail = $parts[4] ?? '';
                $role = preg_match('/(?:^|\s)(estudiante|docente)(?:\s|$)/i', $detail, $match)
                    ? ucfirst(strtolower($match[1])) : '';
                $stamp = strtotime($parts[0] ?? '');
                $out[] = [
                    'when' => $stamp ? date('Y-m-d H:i', $stamp) : ($parts[0] ?? ''),
                    'by' => $parts[1] ?? '', 'uid' => $parts[3] ?? '',
                    'type' => $event === 'CREADO' ? $role : '', 'event' => $labels[$event],
                ];
                if (count($out) >= $limit) break;
            }
        } finally {
            fclose($h);
        }
    } catch (Throwable $e) {
        error_log('Secretaria: fallo lectura de auditoria');
    }
    return $out;
}
/** Reserva UID historicos para evitar que un usuario nuevo herede buzones antiguos. */
function reservedUids(): array {
    $file = STATE_DIR . '/auditoria.tsv';
    if (!is_file($file)) return [];
    if (!is_readable($file) || filesize($file) === false || filesize($file) > 20 * 1024 * 1024) {
        throw new RuntimeException('Auditoría ausente o demasiado grande: no se puede verificar el historial de usuarios.');
    }
    $reserved = [];
    $handle = @fopen($file, 'r');
    if ($handle === false) throw new RuntimeException('No se puede revisar el historial de usuarios.');
    try {
        while (($line = fgets($handle)) !== false) {
            $parts = explode("\t", $line);
            if (in_array($parts[2] ?? '', ['CREADO', 'ANULADO', 'SUSPENDIDA'], true)) {
                $uid = $parts[3] ?? '';
                if (validUid($uid)) $reserved[$uid] = true;
            }
        }
    } finally {
        fclose($handle);
    }
    return $reserved;
}
/** ZIP sin compresion (suficiente para un .docx pequeno; no necesita la extension zip). */
function zipStore(array $files): string {
    $data = '';
    $central = '';
    $offset = 0;
    foreach ($files as $name => $content) {
        $crc = crc32($content);
        $len = strlen($content);
        $nlen = strlen($name);
        $local = pack('VvvvvvVVVvv', 0x04034b50, 20, 0x0800, 0, 0, 0x21, $crc, $len, $len, $nlen, 0) . $name;
        $data .= $local . $content;
        $central .= pack('VvvvvvvVVVvvvvvVV', 0x02014b50, 20, 20, 0x0800, 0, 0, 0x21, $crc, $len, $len, $nlen, 0, 0, 0, 0, 0, $offset) . $name;
        $offset += strlen($local) + $len;
    }
    $count = count($files);
    return $data . $central . pack('VvvvvVVv', 0x06054b50, 0, 0, $count, $count, strlen($central), $offset, 0);
}
function x(string $v): string {
    return htmlspecialchars($v, ENT_XML1 | ENT_QUOTES, 'UTF-8');
}
/**
 * Ficha institucional de entrega de cuenta (.docx) con logo, tabla de datos tipo formulario,
 * datos de acceso destacados, servicios, recomendaciones y firmas de entrega/recepcion.
 * El logo se toma de LOGO_FILE (JPG o PNG); si no existe, la ficha sale sin logo.
 */
function buildCredentialDocx(array $a, string $issuer, string $title = 'Ficha de entrega de cuenta institucional'): string {
    $reset = !str_starts_with($title, 'Ficha de entrega');
    $font = '<w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:cs="Arial"/>';
    $run = fn(string $t, array $o = []) => '<w:r><w:rPr>' . $font . (!empty($o['b']) ? '<w:b/>' : '') .
        (!empty($o['mono']) ? '<w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/>' : '') .
        (isset($o['color']) ? '<w:color w:val="' . $o['color'] . '"/>' : '') .
        '<w:sz w:val="' . ($o['sz'] ?? 19) . '"/></w:rPr><w:t xml:space="preserve">' . x($t) . '</w:t></w:r>';
    $par = fn(string $runs, string $jc = 'left', int $after = 60) =>
        '<w:p><w:pPr><w:spacing w:before="0" w:after="' . $after . '"/><w:jc w:val="' . $jc . '"/></w:pPr>' . $runs . '</w:p>';
    $p = fn(string $t, array $o = [], string $jc = 'left', int $after = 60) => $par($run($t, $o), $jc, $after);
    // Celda: ancho, contenido (parrafos), opciones: fill, span, vmerge (restart|continue), valign
    $cell = function (int $w, string $content, array $o = []) {
        $pr = '<w:tcW w:w="' . $w . '" w:type="dxa"/>' .
            (isset($o['span']) ? '<w:gridSpan w:val="' . $o['span'] . '"/>' : '') .
            (isset($o['vmerge']) ? ($o['vmerge'] === 'restart' ? '<w:vMerge w:val="restart"/>' : '<w:vMerge/>') : '') .
            (isset($o['fill']) ? '<w:shd w:val="clear" w:color="auto" w:fill="' . $o['fill'] . '"/>' : '') .
            '<w:vAlign w:val="' . ($o['valign'] ?? 'center') . '"/>';
        return '<w:tc><w:tcPr>' . $pr . '</w:tcPr>' . ($content !== '' ? $content : '<w:p/>') . '</w:tc>';
    };
    $table = function (array $cols, string $rows, bool $borders = true) {
        $b = $borders ? '<w:tblBorders><w:top w:val="single" w:sz="8" w:color="14532A"/><w:left w:val="single" w:sz="8" w:color="14532A"/>' .
            '<w:bottom w:val="single" w:sz="8" w:color="14532A"/><w:right w:val="single" w:sz="8" w:color="14532A"/>' .
            '<w:insideH w:val="single" w:sz="4" w:color="B8CBBE"/><w:insideV w:val="single" w:sz="4" w:color="B8CBBE"/></w:tblBorders>'
            : '<w:tblBorders><w:top w:val="nil"/><w:left w:val="nil"/><w:bottom w:val="nil"/><w:right w:val="nil"/><w:insideH w:val="nil"/><w:insideV w:val="nil"/></w:tblBorders>';
        return '<w:tbl><w:tblPr><w:tblW w:w="' . array_sum($cols) . '" w:type="dxa"/><w:jc w:val="center"/>' . $b .
            '<w:tblLayout w:type="fixed"/><w:tblCellMar><w:top w:w="50" w:type="dxa"/><w:left w:w="100" w:type="dxa"/><w:bottom w:w="50" w:type="dxa"/><w:right w:w="100" w:type="dxa"/></w:tblCellMar></w:tblPr>' .
            '<w:tblGrid>' . implode('', array_map(fn($c) => '<w:gridCol w:w="' . $c . '"/>', $cols)) . '</w:tblGrid>' . $rows . '</w:tbl>';
    };
    $row = fn(string $cells, int $h = 0) => '<w:tr>' . ($h ? '<w:trPr><w:trHeight w:val="' . $h . '"/></w:trPr>' : '') . $cells . '</w:tr>';
    // Colores institucionales (como EduNova): verde, dorado y crema.
    $navy = '14532A'; $light = 'E7F1EA'; $gold = 'FBF7E8';

    // ---- datos de la persona
    $name = trim((string)($a['name'] ?? ''));
    $first = trim((string)($a['first'] ?? ''));
    $last = trim((string)($a['last'] ?? ''));
    if ($first === '' && $last === '') {
        $parts = preg_split('/\s+/u', $name) ?: [];
        $first = (string)array_shift($parts);
        $last = implode(' ', $parts);
    }
    $doc = (string)($a['doc'] ?? '');
    $docTxt = $doc === '' ? '— (por registrar)' : (str_starts_with($doc, 'P-') ? 'Pasaporte ' . substr($doc, 2) : $doc);

    // ---- logo
    $media = [];
    $logoRun = '';
    if (defined('LOGO_FILE') && is_file(LOGO_FILE) && is_readable(LOGO_FILE)) {
        $info = @getimagesize(LOGO_FILE);
        $ext = ($info[2] ?? 0) === IMAGETYPE_PNG ? 'png' : (($info[2] ?? 0) === IMAGETYPE_JPEG ? 'jpeg' : '');
        if ($ext !== '') {
            $media['word/media/logo.' . $ext] = (string)file_get_contents(LOGO_FILE);
            $emu = 1080000; // 3 cm
            $cy = (int)round($emu * ($info[1] / max(1, $info[0])));
            $logoRun = '<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="' . $emu . '" cy="' . $cy . '"/><wp:docPr id="1" name="Logo"/>' .
                '<a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">' .
                '<pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:nvPicPr><pic:cNvPr id="1" name="logo.' . $ext . '"/><pic:cNvPicPr/></pic:nvPicPr>' .
                '<pic:blipFill><a:blip r:embed="rIdLogo"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>' .
                '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="' . $emu . '" cy="' . $cy . '"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>' .
                '</a:graphicData></a:graphic></wp:inline></w:drawing></w:r>';
        }
    }
    $folio = 'N.º ' . ($a['uidNumber'] ?? '') . '-' . date('ymd');

    // ---- encabezado: logo | institucion | folio
    $head = $table([2000, 5700, 2100], $row(
        $cell(2000, $par($logoRun, 'center', 0)) .
        $cell(5700, $p(mb_strtoupper(INSTITUCION, 'UTF-8'), ['b' => true, 'sz' => 32, 'color' => $navy], 'center', 40) .
            $p('SECRETARÍA GENERAL', ['b' => true, 'sz' => 20, 'color' => '8A6D1F'], 'center', 40) .
            $p('Servicios tecnológicos institucionales · mejoland.edu.ec', ['sz' => 16, 'color' => '555555'], 'center', 0)) .
        $cell(2100, $p($folio, ['b' => true, 'sz' => 16], 'right', 20) . $p(date('d/m/Y H:i'), ['sz' => 16], 'right', 0))
    ), false);
    // Regla verde con linea dorada (identidad institucional)
    $rule = '<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="18" w:space="1" w:color="14532A"/></w:pBdr><w:spacing w:before="0" w:after="30"/><w:rPr><w:sz w:val="4"/></w:rPr></w:pPr></w:p>' .
        '<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1" w:color="C9A227"/></w:pBdr><w:spacing w:before="0" w:after="140"/><w:rPr><w:sz w:val="4"/></w:rPr></w:pPr></w:p>';
    $titleP = $p(mb_strtoupper($reset ? $title : 'Ficha de entrega de cuenta institucional', 'UTF-8'), ['b' => true, 'sz' => 28, 'color' => $navy], 'center', 160);

    // ---- datos personales con recuadro de foto (5 filas fusionadas)
    $L = 2600; $V = 4900; $F = 2300;
    $lab = fn(string $t) => $p($t, ['b' => true, 'sz' => 17, 'color' => $navy]);
    $val = fn(string $t, array $o = []) => $p($t, $o + ['sz' => 19]);
    $datos = [['APELLIDOS', $last], ['NOMBRES', $first], ['CÉDULA / DOCUMENTO', $docTxt], ['TIPO DE CUENTA', (string)($a['type'] ?? '')], ['PERIODO LECTIVO', '2026 - 2027']];
    $rows = $row($cell($L + $V + $F, $p('DATOS DEL TITULAR', ['b' => true, 'sz' => 18, 'color' => 'FFFFFF']), ['span' => 3, 'fill' => $navy]));
    foreach ($datos as $i => [$k, $v]) {
        $rows .= $row($cell($L, $lab($k), ['fill' => $light]) . $cell($V, $val($v)) .
            $cell($F, $i === 0 ? $p('FOTO', ['b' => true, 'sz' => 18, 'color' => '777777'], 'center', 0) : '', ['vmerge' => $i === 0 ? 'restart' : 'continue']), 420);
    }
    $tDatos = $table([$L, $V, $F], $rows);

    // ---- datos de acceso
    $A = 2600; $B = 7200;
    $acc = $row($cell($A + $B, $p('DATOS DE ACCESO', ['b' => true, 'sz' => 18, 'color' => 'FFFFFF']), ['span' => 2, 'fill' => $navy])) .
        $row($cell($A, $lab('USUARIO'), ['fill' => $light]) . $cell($B, $val((string)$a['uid'], ['b' => true, 'sz' => 22])), 420) .
        $row($cell($A, $lab('CORREO INSTITUCIONAL'), ['fill' => $light]) . $cell($B, $val((string)$a['mail'], ['b' => true, 'sz' => 22])), 420) .
        $row($cell($A, $lab($reset ? 'CONTRASEÑA NUEVA' : 'CONTRASEÑA TEMPORAL'), ['fill' => $light]) .
            $cell($B, $val((string)$a['password'], ['b' => true, 'sz' => 30, 'mono' => true]) .
                $p('Incluye los guiones. Distingue mayúsculas y minúsculas.', ['sz' => 15, 'color' => '6B5A1E']), ['fill' => $gold]), 560);
    $tAcc = $table([$A, $B], $acc);

    // ---- servicios
    $S1 = 2300; $S2 = 3600; $S3 = 3900;
    $wifi = ($a['type'] ?? '') === 'Estudiante'
        ? 'Red ' . WIFI_SSID . ': WPA2-Enterprise, EAP-TTLS / PAP, identidad: su usuario.' . (RADIUS_CERT_SHA256 !== '' ? ' Huella del certificado: ' . RADIUS_CERT_SHA256 . '.' : ' Verifique el certificado con TI antes de conectarse.')
        : 'Red cableada de su área (autenticación con su cuenta).';
    $serv = [
        ['Correo web', WEBMAIL_URL, 'Usuario o correo completo y su contraseña.'],
        ['Plataforma EduNova', PLATAFORMA_URL, 'Misma cuenta. En «Mi perfil» cambie su contraseña.'],
        ['Correo en celular / PC', MAIL_SERVER, 'IMAP 993 SSL/TLS · SMTP 587 STARTTLS.'],
        ['Wi-Fi / red', ($a['type'] ?? '') === 'Estudiante' ? 'Red: ' . WIFI_SSID : 'Red cableada', $wifi],
    ];
    $srows = $row($cell($S1 + $S2 + $S3, $p('SERVICIOS DISPONIBLES CON ESTA CUENTA', ['b' => true, 'sz' => 18, 'color' => 'FFFFFF']), ['span' => 3, 'fill' => $navy])) .
        $row($cell($S1, $lab('SERVICIO'), ['fill' => $light]) . $cell($S2, $lab('DIRECCIÓN'), ['fill' => $light]) . $cell($S3, $lab('CÓMO INGRESAR'), ['fill' => $light]));
    foreach ($serv as [$s, $d, $c]) {
        $srows .= $row($cell($S1, $p($s, ['b' => true, 'sz' => 17])) . $cell($S2, $p($d, ['sz' => 16, 'mono' => true])) . $cell($S3, $p($c, ['sz' => 16])), 380);
    }
    $tServ = $table([$S1, $S2, $S3], $srows);

    // ---- recomendaciones
    $recs = [
        'En su primer ingreso cambie la contraseña temporal por una propia (EduNova → Mi perfil). El cambio aplica al correo, al Wi-Fi y a la plataforma.',
        'No comparta su contraseña. El personal de la institución nunca se la pedirá por correo, mensaje ni teléfono.',
        'Si la olvida, acuda a Secretaría con su cédula: se verifica su identidad y se emite una contraseña nueva.',
        'Este documento contiene información confidencial. Guárdelo en un lugar seguro o destrúyalo cuando ya no lo necesite.',
    ];
    $rec = $p('IMPORTANTE', ['b' => true, 'sz' => 19, 'color' => $navy], 'left', 40);
    foreach ($recs as $i => $r) $rec .= $p(($i + 1) . '. ' . $r, ['sz' => 17], 'both', 40);

    // ---- firmas
    $firmas = $table([4900, 4900], $row(
        $cell(4900, $p('', [], 'center', 500) . $p('______________________________', [], 'center', 20) .
            $p('ENTREGADO POR', ['b' => true, 'sz' => 16], 'center', 0) . $p('Secretaría · operador: ' . $issuer, ['sz' => 15], 'center', 0)) .
        $cell(4900, $p('', [], 'center', 500) . $p('______________________________', [], 'center', 20) .
            $p('RECIBIDO CONFORME', ['b' => true, 'sz' => 16], 'center', 0) . $p('Titular o representante · C.I. ____________', ['sz' => 15], 'center', 0))
    ), false);
    $pie = $p('Documento generado por el Panel de Secretaría de ' . INSTITUCION . ' el ' . date('d/m/Y') . ' a las ' . date('H:i') . '. La contraseña no queda registrada en el sistema.', ['sz' => 14, 'color' => '777777'], 'center', 0);

    $sp = $p('', [], 'left', 100);
    $body = $head . $rule . $titleP . $tDatos . $sp . $tAcc . $sp . $tServ . $sp . $rec . $firmas . $sp . $pie;
    $docXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' .
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" ' .
        'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"><w:body>' . $body .
        '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="850" w:right="1000" w:bottom="850" w:left="1000" w:header="500" w:footer="500" w:gutter="0"/></w:sectPr></w:body></w:document>';
    $styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">' .
        '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:cs="Arial" w:eastAsia="Arial"/><w:sz w:val="19"/><w:lang w:val="es-EC"/></w:rPr></w:rPrDefault>' .
        '<w:pPrDefault><w:pPr><w:spacing w:after="60" w:line="240" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults></w:styles>';
    $imgDefaults = '';
    foreach ($media as $path => $_) {
        $e = pathinfo($path, PATHINFO_EXTENSION);
        $imgDefaults .= '<Default Extension="' . $e . '" ContentType="image/' . $e . '"/>';
    }
    $types = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' .
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' .
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' .
        '<Default Extension="xml" ContentType="application/xml"/>' . $imgDefaults .
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>' .
        '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>';
    $rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' .
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' .
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>';
    $docRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' .
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' .
        '<Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>' .
        ($media ? '<Relationship Id="rIdLogo" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/' . basename(array_key_first($media)) . '"/>' : '') .
        '</Relationships>';
    return zipStore(['[Content_Types].xml' => $types, '_rels/.rels' => $rels, 'word/document.xml' => $docXml,
        'word/styles.xml' => $styles, 'word/_rels/document.xml.rels' => $docRels] + $media);
}

function ldapConnection(bool $service): LDAP\Connection {
    $conn = @ldap_connect(LDAP_URI);
    if (!$conn) {
        throw new RuntimeException('No se pudo abrir la conexión LDAP.');
    }
    ldap_set_option($conn, LDAP_OPT_PROTOCOL_VERSION, 3);
    ldap_set_option($conn, LDAP_OPT_REFERRALS, 0);
    ldap_set_option($conn, LDAP_OPT_NETWORK_TIMEOUT, 4);
    if ($service) {
        $password = @file_get_contents(SERVICE_PASSWORD_FILE);
        if ($password === false || trim($password) === '') {
            throw new RuntimeException('PHP-FPM no puede leer la credencial de servicio.');
        }
        // Credencial utilizada solamente en el LDAP local de SRV-BD.
        $ok = @ldap_bind($conn, SERVICE_DN, trim($password));
        unset($password);
    } else {
        $ok = @ldap_bind($conn);
    }
    if (!$ok) {
        throw new RuntimeException('No se pudo autenticar contra OpenLDAP.');
    }
    return $conn;
}
/** Consulta paginada RFC 2696, compatible con PHP 8.4 y OpenLDAP. */
function searchEntries(LDAP\Connection $ldap, string $base, string $filter, array $attrs): array {
    $all = ['count' => 0];
    $cookie = '';
    $pages = 0;
    do {
        if (++$pages > LDAP_MAX_PAGES) {
            throw new RuntimeException('El directorio supera el límite de lectura configurado.');
        }
        $controlsRequest = [[
            'oid' => LDAP_CONTROL_PAGEDRESULTS,
            'iscritical' => true,
            'value' => ['size' => LDAP_PAGE_SIZE, 'cookie' => $cookie],
        ]];
        $result = @ldap_search($ldap, $base, $filter, $attrs, 0, 0, 8, LDAP_DEREF_NEVER, $controlsRequest);
        if ($result === false) {
            throw new RuntimeException('No fue posible consultar el directorio LDAP.');
        }
        $rows = ldap_get_entries($ldap, $result);
        if ($rows === false) {
            throw new RuntimeException('LDAP devolvió una respuesta no legible.');
        }
        for ($i = 0; $i < $rows['count']; $i++) {
            $all[$all['count']++] = $rows[$i];
        }
        $responseControls = [];
        if (!@ldap_parse_result($ldap, $result, $err, $matched, $errmsg, $refs, $responseControls) || $err !== 0) {
            throw new RuntimeException('No se pudo verificar la paginación LDAP.');
        }
        $cookie = (string)($responseControls[LDAP_CONTROL_PAGEDRESULTS]['value']['cookie'] ?? '');
    } while ($cookie !== '');
    return $all;
}

function existsFilter(LDAP\Connection $ldap, string $filter): bool {
    $result = @ldap_search($ldap, LDAP_BASE, $filter, ['dn'], 0, 1, 5);
    if ($result === false) {
        throw new RuntimeException('Falló la comprobación de duplicados en LDAP.');
    }
    $count = ldap_count_entries($ldap, $result);
    if ($count === false) {
        throw new RuntimeException('No se pudo comprobar la disponibilidad del nombre de usuario.');
    }
    return $count > 0;
}
/** Comprobacion independiente de credenciales: no prueba Roundcube ni FreeRADIUS. */
function verifyLogin(string $dn, string $password): bool {
    $c = @ldap_connect(LDAP_URI);
    if (!$c) return false;
    ldap_set_option($c, LDAP_OPT_PROTOCOL_VERSION, 3);
    ldap_set_option($c, LDAP_OPT_REFERRALS, 0);
    ldap_set_option($c, LDAP_OPT_NETWORK_TIMEOUT, 4);
    return @ldap_bind($c, $dn, $password);
}
function verifyMembership(LDAP\Connection $ldap, string $groupDn, string $userDn): bool {
    $result = @ldap_read($ldap, $groupDn, '(objectClass=*)', ['member']);
    if ($result === false) return false;
    $entries = @ldap_get_entries($ldap, $result);
    if ($entries === false || ($entries['count'] ?? 0) !== 1) return false;
    foreach (($entries[0]['member'] ?? []) as $k => $member) {
        if (is_int($k) && strcasecmp((string)$member, $userDn) === 0) return true;
    }
    return false;
}

function auditEvent(string $event, string $identifier, string $details = ''): bool {
    $principal = operatorName() ?? 'NO_IDENTIFICADO';
    $ts = tailscaleIdentity();
    if ($ts !== '') $details = trim($details . ' [tailscale:' . $ts . ']');
    $details = str_replace(["\r", "\n", "\t"], ' ', $details);
    $line = gmdate('c') . "\t" . $principal . "\t" . $event . "\t" . $identifier . "\t" . $details . "\n";
    $saved = @file_put_contents(STATE_DIR . '/auditoria.tsv', $line, FILE_APPEND | LOCK_EX);
    if ($saved === false || $saved !== strlen($line)) {
        error_log('Panel Secretaria: error de escritura en auditoria, evento ' . $event);
        return false;
    }
    return true;
}


/** Cuenta de Tailscale que hizo la peticion (cabecera puesta por Tailscale Serve). Solo informativa. */
function tailscaleIdentity(): string {
    if (!in_array((string)($_SERVER['REMOTE_ADDR'] ?? ''), ['127.0.0.1', '::1'], true)) return '';
    $login = (string)($_SERVER['HTTP_TAILSCALE_USER_LOGIN'] ?? '');
    return preg_match('/^[A-Za-z0-9._@+-]{1,120}$/D', $login) ? $login : '';
}


/** Grupos LDAP que dan acceso al panel con la cuenta institucional. */
const LDAP_PANEL_ROLES = ['administracion' => 'administrador', 'secretaria' => 'registro'];
/**
 * Busca la cuenta institucional y su rol de panel (sin comprobar la contrasena).
 * Devuelve ['dn'=>..., 'role'=>...] o null. Cuentas suspendidas no tienen rol.
 */
function ldapPanelRole(string $uid): ?array {
    static $cache = [];
    if (array_key_exists($uid, $cache)) return $cache[$uid];
    $cache[$uid] = null;
    if (!preg_match('/^[a-z0-9._-]{1,64}$/D', $uid)) return null;
    try {
        $ldap = ldapConnection(true);
        $res = @ldap_search($ldap, LDAP_BASE, '(&(objectClass=inetOrgPerson)(uid=' . ldap_escape($uid, '', LDAP_ESCAPE_FILTER) . '))', ['dn', 'description'], 0, 2);
        $e = $res !== false ? @ldap_get_entries($ldap, $res) : false;
        if ($e === false || ($e['count'] ?? 0) !== 1) return null;
        $dn = (string)$e[0]['dn'];
        if (str_contains((string)($e[0]['description'][0] ?? ''), '[SUSPENDIDA-SECRETARIA]')) return null;
        foreach (LDAP_PANEL_ROLES as $group => $role) {
            if (verifyMembership($ldap, 'cn=' . $group . ',ou=grupos,' . LDAP_BASE, $dn)) return $cache[$uid] = ['dn' => $dn, 'role' => $role];
        }
    } catch (Throwable $e) {
        error_log('Panel Secretaria: rol LDAP no disponible: ' . $e->getMessage());
    }
    return null;
}

/** Lee las claves web verificadas por password_hash(). No son las claves LDAP. */
function webUsers(): array {
    if (!is_file(WEB_USERS_FILE) || !is_readable(WEB_USERS_FILE)) {
        throw new RuntimeException('Falta el archivo protegido de credenciales web.');
    }
    $perms = @fileperms(WEB_USERS_FILE);
    if ($perms === false || ($perms & 0007) !== 0) {
        throw new RuntimeException('Los permisos del archivo de usuarios web son inseguros.');
    }
    $raw = @file_get_contents(WEB_USERS_FILE);
    $data = is_string($raw) ? json_decode($raw, true) : null;
    if (!is_array($data) || !is_array($data['users'] ?? null)) {
        throw new RuntimeException('Archivo de credenciales web mal formado.');
    }
    return $data['users'];
}

/** Limite de intentos por cuenta. El contador persiste entre sesiones y navegadores. */
/** Devuelve ['ok'=>bool, 'wait'=>minutos de bloqueo, 'last'=>ultimo acceso correcto previo]. */
function checkWebPassword(string $username, string $password, array $users): array {
    $directory = STATE_DIR . '/login-rate';
    if (!is_dir($directory) || !is_writable($directory)) {
        throw new RuntimeException('No es posible proteger el inicio de sesión contra intentos repetidos.');
    }
    $path = $directory . '/' . hash('sha256', $username) . '.json';
    $fh = @fopen($path, 'c+');
    if (is_resource($fh)) @chmod($path, 0600);
    if (!$fh || !@flock($fh, LOCK_EX)) {
        if (is_resource($fh)) fclose($fh);
        throw new RuntimeException('No se puede consultar el limitador de intentos.');
    }
    try {
        rewind($fh);
        $state = json_decode((string)stream_get_contents($fh), true);
        $state = is_array($state) ? $state : [];
        $now = time();
        $first = (int)($state['first'] ?? $now);
        $failures = (int)($state['failures'] ?? 0);
        if ($now - $first >= LOGIN_FAILURE_WINDOW) {
            $first = $now;
            $failures = 0;
        }
        $lastOk = (int)($state['last_ok'] ?? 0);
        if ($failures >= LOGIN_MAX_FAILURES) {
            return ['ok'=>false, 'wait'=>(int)ceil((LOGIN_FAILURE_WINDOW - ($now - $first)) / 60), 'last'=>0];
        }
        $candidate = $users[$username] ?? null;
        // Mismo calculo para usuarios conocidos y desconocidos (reduce enumeracion).
        $dummy = '$2y$12$K2IQ7dbokJU5t/djVKVDV.QhyzsxhUqNgJ6NNUhUuT2ZLYFVAVsVO';
        $hash = is_array($candidate) && is_string($candidate['hash'] ?? null)
            ? $candidate['hash'] : $dummy;
        $verified = password_verify($password, $hash);
        $valid = $verified && is_array($candidate) && ($candidate['enabled'] ?? false) === true
            && operatorRole($username) !== null;
        $via = 'panel';
        if (!$valid) {
            // Cuenta institucional (LDAP): miembros de los grupos secretaria o administracion.
            $info = ldapPanelRole($username);
            if ($info !== null && verifyLogin($info['dn'], $password)) { $valid = true; $via = 'ldap'; }
        }
        $previous = $lastOk;
        if ($valid) {
            $failures = 0;
            $first = $now;
            $lastOk = $now;
        } else {
            $failures++;
        }
        rewind($fh);
        if (!ftruncate($fh, 0)) throw new RuntimeException('No se puede actualizar el limitador de intentos.');
        $encoded = json_encode(['first'=>$first, 'failures'=>$failures, 'last_ok'=>$lastOk]);
        if (!is_string($encoded) || fwrite($fh, $encoded) !== strlen($encoded)) {
            throw new RuntimeException('No se pudo registrar el intento de inicio de sesión.');
        }
        fflush($fh);
        $wait = (!$valid && $failures >= LOGIN_MAX_FAILURES) ? (int)ceil(LOGIN_FAILURE_WINDOW / 60) : 0;
        return ['ok'=>$valid, 'wait'=>$wait, 'last'=>$valid ? $previous : 0, 'via'=>$valid ? $via : ''];
    } finally {
        flock($fh, LOCK_UN);
        fclose($fh);
    }
}

function logoutWeb(): never {
    $_SESSION = [];
    $params = session_get_cookie_params();
    if (ini_get('session.use_cookies')) {
        setcookie(session_name(), '', [
            'expires' => time() - 3600, 'path' => $params['path'],
            'secure' => $params['secure'], 'httponly' => $params['httponly'],
            'samesite' => $params['samesite'] ?: 'Strict',
        ]);
    }
    session_destroy();
    header('Location: /secretaria/', true, 303);
    exit;
}

/** Logo institucional como data: URI (la CSP solo permite imagenes data:). */
function logoDataUri(): string {
    static $uri = null;
    if ($uri !== null) return $uri;
    $uri = '';
    if (is_file(LOGO_FILE) && is_readable(LOGO_FILE)) {
        $info = @getimagesize(LOGO_FILE);
        $mime = $info['mime'] ?? '';
        if (in_array($mime, ['image/jpeg', 'image/png'], true)) $uri = 'data:' . $mime . ';base64,' . base64_encode((string)file_get_contents(LOGO_FILE));
    }
    return $uri;
}
function logoImg(string $alt = 'Logo'): string {
    $u = logoDataUri();
    return $u !== '' ? '<img src="' . $u . '" alt="' . esc($alt) . '">' : '<span>' . esc(mb_substr(INSTITUCION, 0, 1, 'UTF-8')) . '</span>';
}
/** Tema institucional (igual a EduNova): verde #14532A, dorado #C9A227, crema #F7F4EC, titulos con serifa. */
const THEME_CSS = ':root{--verde:#14532A;--verde-osc:#0D3A1D;--verde-med:#1B6B37;--dorado:#C9A227;--dorado-cl:#E9D48A;--crema:#F7F4EC;--verde-claro:#E7F1EA;--negro:#1f2937}'
    . '.franja{height:4px;background:linear-gradient(90deg,var(--verde) 0 70%,var(--dorado) 70%)}'
    . '.logo{display:grid;place-items:center;background:#fff;border-radius:50%;border:3px solid var(--dorado);box-shadow:0 6px 18px rgba(13,58,29,.25);overflow:hidden;padding:3px}.logo img{width:100%;height:100%;object-fit:contain;border-radius:50%}.logo span{font:700 26px Georgia,serif;color:var(--verde)}'
    . '.serif{font-family:Georgia,"Times New Roman",serif}';

function loginView(string $error = '', string $notice = '', string $typed = ''): never {
    http_response_code(200);
    $csrf = esc((string)$_SESSION['csrf']);
    $errorHtml = $error !== '' ? '<div class="alert err" role="alert">'.esc($error).'</div>' : '';
    $noticeHtml = $notice !== '' ? '<div class="alert info" role="status">'.esc($notice).'</div>' : '';
    echo '<!doctype html><html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Iniciar sesión | Secretaría</title>';
    echo '<style>*{box-sizing:border-box}body{font:15px/1.5 system-ui,-apple-system,"Segoe UI",Arial,sans-serif;background:#eef3f9;margin:0;min-height:100vh;display:grid;place-items:center;color:#192d43;padding:20px}.card{width:min(100%,430px);background:#fff;border:1px solid #dae5f0;border-radius:15px;box-shadow:0 14px 40px #24364b15;padding:30px}.brand{color:#17385d;font-size:12px;font-weight:800;letter-spacing:.12em;text-transform:uppercase}.card h1{font-size:25px;margin:8px 0 4px}.sub{color:#5d6d7c;font-size:13px;margin-bottom:24px}label{display:block;font-size:13px;font-weight:700;margin:18px 0 6px}input{font:inherit;border-radius:8px;width:100%;height:44px;border:1px solid #b9cadc;padding:10px 12px}input:focus{outline:3px solid #dbeaff;border-color:#2764b4}button{border:0;width:100%;background:#205aab;color:#fff;border-radius:8px;padding:12px;font-weight:800;font-size:14px;margin-top:22px;cursor:pointer}.alert{padding:11px;border-radius:8px;font-size:13px;margin:15px 0}.err{background:#fff0f0;border:1px solid #e7b6b6;color:#8d2734}.info{background:#f0f6ff;border:1px solid #ccdff5;color:#27527b}.hint{color:#697a8c;font-size:12px;margin-top:18px}small{display:block}'
        . THEME_CSS
        . 'body{display:block;padding:0;color:#1f2937;background:linear-gradient(135deg,rgba(13,58,29,.96),rgba(27,107,55,.92)),var(--verde);min-height:100vh}.wrap{min-height:calc(100vh - 4px);display:grid;place-items:center;padding:24px}'
        . '.card{border:0;border-top:5px solid var(--dorado);border-radius:18px;box-shadow:0 24px 60px rgba(0,0,0,.35);padding:30px 30px 26px}.head{display:flex;flex-direction:column;align-items:center;text-align:center;gap:10px;margin-bottom:6px}.head .logo{width:96px;height:96px}'
        . '.inst{display:block;font:600 19px Georgia,serif;color:var(--verde)}.brand{color:#8a7a3a;font-size:11px;letter-spacing:.2em}.card h1{font:600 26px Georgia,serif;color:var(--verde);text-align:center;margin:14px 0 2px}.sub{text-align:center;color:#6b7280}'
        . 'label{color:#374151}input{border:1px solid #d9d3c3;background:var(--crema);border-radius:10px}input:focus{outline:3px solid rgba(20,83,42,.18);border-color:var(--verde)}'
        . 'button{background:var(--verde);border-radius:10px;font-weight:700;letter-spacing:.02em}button:hover{background:var(--verde-osc)}'
        . '.alert{border-radius:10px}.err{background:#fef2f2;border-color:#fecaca;color:#991b1b}.info{background:var(--verde-claro);border-color:#cfe3d5;color:var(--verde-osc)}.hint{color:#6b7280;text-align:center}'
        . '</style></head><body><div class="franja"></div><div class="wrap"><main class="card">';
    echo '<div class="head"><div class="logo">' . logoImg('Logo ' . INSTITUCION) . '</div><div><span class="inst">' . esc(INSTITUCION) . '</span><div class="brand">SECRETARÍA GENERAL · SRV-BD</div></div></div><h1>Panel de secretaría</h1><p class="sub">Acceso del personal autorizado · sesión individual</p>';
    echo $noticeHtml . $errorHtml;
    echo '<form action="/secretaria/" method="post" autocomplete="on"><input type="hidden" name="csrf" value="'.$csrf.'"><input type="hidden" name="auth_action" value="login"><label for="username">Usuario institucional</label><input id="username" name="username" maxlength="100" autocomplete="username" value="'.esc($typed).'" required'.($typed === '' ? ' autofocus' : '').'><label for="password">Contraseña</label><input id="password" name="password" type="password" maxlength="256" autocomplete="current-password" required'.($typed !== '' ? ' autofocus' : '').'><button type="submit">Iniciar sesión</button></form><p class="hint">Usa tu <b>cuenta institucional</b> (la misma del correo y de EduNova). Solo personal de Secretaría y Administración. Al terminar, pulsa Cerrar sesión.</p></main></div></body></html>';
    exit;
}

/** Comprueba la credencial habilitada y el rol despues de cada solicitud. */
try {
    $accounts = webUsers();
} catch (Throwable $e) {
    http_response_code(503);
    error_log('Secretaría: archivo de operadores web ausente o incorrecto');
    exit('Acceso temporalmente no disponible. Consulta al administrador del servidor.');
}

$authAction = $_POST['auth_action'] ?? null;
if ($authAction === 'logout') {
    if (operatorName() !== null && is_string($_POST['csrf'] ?? null)
        && hash_equals((string)($_SESSION['csrf'] ?? ''), $_POST['csrf'])) {
        auditEvent('LOGOUT', operatorName() ?? '-');
        logoutWeb();
    }
    http_response_code(403);
    exit('Solicitud de cierre de sesión no válida.');
}

$loginFailure = '';
$loginTyped = '';
if ($authAction === 'login') {
    try {
        if (count($_POST) > 4 || !is_string($_POST['csrf'] ?? null)
            || !hash_equals((string)$_SESSION['csrf'], $_POST['csrf'])) {
            throw new RuntimeException('Solicitud no válida o caducada.');
        }
        $username = strtolower(trim(postString('username')));
        $password = postString('password');
        if (!preg_match('/^[a-z0-9._@-]{1,100}$/D', $username) || strlen($password) > 256 || $password === '') {
            throw new RuntimeException('Credenciales incorrectas o acceso no autorizado.');
        }
        $loginTyped = $username;
        $check = checkWebPassword($username, $password, $accounts);
        if (!$check['ok']) {
            auditEvent('LOGIN_DENEGADO', $username);
            if ($check['wait'] > 0) {
                throw new RuntimeException('Demasiados intentos fallidos. Espera ' . $check['wait'] . ' minuto(s) o pide al administrador que desbloquee la cuenta.');
            }
            throw new RuntimeException('Usuario o contraseña incorrectos.');
        }
        // Regenerar ANTES de asignar los privilegios.
        $_SESSION = [];
        if (!session_regenerate_id(true)) throw new RuntimeException('No se pudo renovar la sesión.');
        $_SESSION['operator'] = $username;
        $_SESSION['auth'] = $check['via'];
        $_SESSION['credential_id'] = $check['via'] === 'ldap' ? 'ldap' : hash('sha256', (string)$accounts[$username]['hash']);
        $_SESSION['csrf'] = bin2hex(random_bytes(32));
        $_SESSION['logged_at'] = $_SESSION['last_seen'] = $_SESSION['renewed_at'] = time();
        $_SESSION['previous_login'] = (int)$check['last'];
        auditEvent('LOGIN', $username, $check['via'] === 'ldap' ? 'cuenta institucional' : 'usuario del panel');
        header('Location: /secretaria/', true, 303);
        exit;
    } catch (Throwable $e) {
        $loginFailure = $e->getMessage();
    }
}

$sessionUser = operatorName();
$entry = $sessionUser !== null ? ($accounts[$sessionUser] ?? null) : null;
$now = time();
$viaLdap = ($_SESSION['auth'] ?? '') === 'ldap';
$validSession = $sessionUser !== null
    && ($viaLdap
        ? ($_SESSION['credential_id'] ?? '') === 'ldap'
        : (is_array($entry) && ($entry['enabled'] ?? false) === true && is_string($entry['hash'] ?? null)
            && hash_equals(hash('sha256', $entry['hash']), (string)($_SESSION['credential_id'] ?? ''))))
    && operatorRole($sessionUser) !== null
    && $now - (int)($_SESSION['last_seen'] ?? 0) <= LOGIN_IDLE_SECONDS
    && $now - (int)($_SESSION['logged_at'] ?? 0) <= LOGIN_ABSOLUTE_SECONDS;
if (!$validSession) {
    // Si se borró un usuario o cambió su contraseña, la sesión anterior ya no vale.
    unset($_SESSION['operator'], $_SESSION['auth'], $_SESSION['credential_id'], $_SESSION['logged_at'], $_SESSION['last_seen'], $_SESSION['renewed_at']);
    $expired = $sessionUser !== null && $loginFailure === '';
    loginView($loginFailure, $expired ? 'Tu sesión terminó por inactividad. Vuelve a iniciar sesión.' : 'Inicia sesión para administrar cuentas institucionales.', $loginTyped);
}
$_SESSION['last_seen'] = $now;
if ($now - (int)($_SESSION['renewed_at'] ?? 0) > 900) {
    session_regenerate_id(true);
    $_SESSION['renewed_at'] = $now;
}

$notice = '';
$problem = '';
$issuedAccount = null;
$operator = operatorName();
$operatorRole = operatorRole($operator);
if ($operatorRole === null) {
    http_response_code(403);
    header('Content-Type: text/plain; charset=UTF-8');
    exit('Acceso no autorizado: la cuenta no pertenece a los grupos secretaria o administracion.');
}
$mayRegister = canWrite($operatorRole);
$mayAdminister = canAdmin($operatorRole);
// Secretaria (registro) y administracion pueden abrir la gestion; cada accion revisa su propio permiso.
$manageUid = $mayRegister ? getString('gestionar') : '';
$old = [];
$manage = null;
$roleFilter = getString('rol', 'todos');
if (!in_array($roleFilter, ['todos', 'estudiante', 'docente', 'general'], true)) $roleFilter = 'todos';

if (($_SERVER['REQUEST_METHOD'] ?? 'GET') === 'POST') {
    $lock = null;
    try {
        if (!ENABLE_REGISTRATION) throw new RuntimeException('Operaciones desactivadas hasta completar las pruebas de integración.');
        if (!is_array($_POST) || count($_POST) > 10) throw new RuntimeException('Formulario inválido.');
        $csrf = postString('csrf');
        if (!hash_equals((string)$_SESSION['csrf'], $csrf)) {
            throw new RuntimeException('La solicitud caducó. Actualiza la página e inténtalo otra vez.');
        }
        $action = postString('accion');
        if (!in_array($action, ['crear', 'clave', 'cedula', 'suspender', 'rehabilitar'], true)) {
            throw new RuntimeException('Operación desconocida.');
        }
        if ($action === 'crear' && !$mayRegister) throw new RuntimeException('Tu usuario no tiene permiso para registrar cuentas.');
        if (in_array($action, ['clave', 'cedula'], true) && !$mayRegister) throw new RuntimeException('Tu usuario no tiene permiso para gestionar cuentas.');
        if (in_array($action, ['suspender', 'rehabilitar'], true) && !$mayAdminister) throw new RuntimeException('Solo administración puede bloquear o rehabilitar cuentas.');
        if ($action === 'crear') {
            $old = ['nombre' => (string)($_POST['nombre'] ?? ''), 'apellido' => (string)($_POST['apellido'] ?? ''),
                    'tipo' => (string)($_POST['tipo'] ?? ''), 'doc_tipo' => (string)($_POST['doc_tipo'] ?? 'cedula'),
                    'cedula' => (string)($_POST['cedula'] ?? '')];
        }

        $lock = @fopen(STATE_DIR . '/alta.lock', 'c');
        if (!$lock || !flock($lock, LOCK_EX)) throw new RuntimeException('No se pudo bloquear el registro.');
        $ldap = ldapConnection(true);
        $requestId = bin2hex(random_bytes(8));

        if ($action !== 'crear') {
            $uid = postString('uid');
            if (!validUid($uid)) throw new RuntimeException('Usuario no válido.');
            $manageUid = $uid;
            $dn = 'uid=' . $uid . ',' . ALTAS_BASE;
            $read = @ldap_read($ldap, $dn, '(objectClass=posixAccount)', ['uid','cn','mail','uidnumber','gidnumber','description','createtimestamp','employeenumber','givenname','sn']);
            $entry = $read ? @ldap_get_entries($ldap, $read) : false;
            if (!$entry || ($entry['count'] ?? 0) !== 1) {
                throw new RuntimeException('Solo se gestionan las cuentas en ou=Altas.');
            }
            $e = $entry[0];
            $group = groupByGid((string)($e['gidnumber'][0] ?? ''));
            $desc = (string)($e['description'][0] ?? '');
            // Gestionable = estudiante o docente en ou=Altas, la cree quien la cree (secretaria, administracion o migrada).
            if ($group === null) {
                throw new RuntimeException('Solo se gestionan cuentas de estudiantes y docentes.');
            }
            // Defensa extra: nunca tocar cuentas del personal administrativo o de red.
            foreach (['cn=administracion,ou=grupos,' . LDAP_BASE, 'cn=admins-red,ou=grupos,' . LDAP_BASE, 'cn=secretaria,ou=grupos,' . LDAP_BASE] as $staffGroup) {
                if (verifyMembership($ldap, $staffGroup, $dn)) throw new RuntimeException('Las cuentas del personal administrativo no se gestionan desde este panel.');
            }
            if ($action === 'rehabilitar' && !isSuspended($desc)) {
                throw new RuntimeException('La cuenta no está suspendida.');
            }
            if ($action !== 'rehabilitar' && isSuspended($desc)) {
                throw new RuntimeException('La cuenta está suspendida. Usa «Rehabilitar cuenta» para devolverle el acceso.');
            }

            $docActual = (string)($e['employeenumber'][0] ?? '');

            if ($action === 'cedula') {
                // Registrar documento en una cuenta que no lo tiene (cuentas creadas sin documento).
                if ($docActual !== '') throw new RuntimeException('Esta cuenta ya tiene documento registrado; solo el administrador LDAP puede cambiarlo.');
                $doc = documentId(postString('doc_tipo'), postString('cedula'));
                $otra = findByDocument($ldap, $doc);
                if ($otra !== null) throw new RuntimeException('Ese documento ya pertenece a la cuenta «' . $otra['uid'] . '» (' . $otra['cn'] . '). Puede ser un duplicado: revisa antes de continuar.');
                if (!@ldap_mod_add($ldap, $dn, ['employeeNumber' => $doc])) {
                    throw new RuntimeException('No se pudo registrar el documento: ' . ldap_error($ldap));
                }
                auditEvent('DOCUMENTO_REGISTRADO', $uid, 'id=' . $requestId . ' doc=' . maskDoc($doc));
                $notice = 'Documento registrado para ' . $uid . '. Desde ahora se usa para verificar restablecimientos y evitar duplicados.';
            } elseif ($action === 'rehabilitar') {
                if (!auditEvent('INTENTO_REHABILITAR', $uid, 'id=' . $requestId)) {
                    throw new RuntimeException('No se pudo preparar el registro de auditoría.');
                }
                $password = generatePassword();
                $cleanDescription = trim((string)preg_replace('/\s*\[SUSPENDIDA-SECRETARIA\].*$/s', '', $desc));
                $changes = [
                    ['attrib'=>'userPassword','modtype'=>LDAP_MODIFY_BATCH_REPLACE,'values'=>[sshaHash($password)]],
                    ['attrib'=>'description','modtype'=>LDAP_MODIFY_BATCH_REPLACE,'values'=>[$cleanDescription]],
                ];
                if (!@ldap_modify_batch($ldap, $dn, $changes)) {
                    throw new RuntimeException('No se pudo rehabilitar la cuenta: ' . ldap_error($ldap));
                }
                $loginVerified = verifyLogin($dn, $password);
                $memberVerified = verifyMembership($ldap, $group['dn'], $dn);
                $auditSaved = auditEvent('REHABILITADA', $uid, 'id=' . $requestId . ' bind=' . ($loginVerified ? 'OK' : 'PENDIENTE'));
                $issuedAccount = [
                    'uid'=>$uid, 'mail'=>(string)($e['mail'][0] ?? ''), 'name'=>(string)($e['cn'][0] ?? ''),
                    'password'=>$password, 'type'=>$group['label'], 'gid'=>(string)$group['gid'],
                    'uidNumber'=>(string)($e['uidnumber'][0] ?? ''), 'group'=>$group['unix'],
                    'userVerified'=>true,'memberVerified'=>$memberVerified,'loginVerified'=>$loginVerified,
                    'auditSaved'=>$auditSaved,'reset'=>true,
                    'first'=>(string)($e['givenname'][0] ?? ''), 'last'=>(string)($e['sn'][0] ?? ''), 'doc'=>$docActual,
                ];
                $issuedAccount['docx'] = base64_encode(buildCredentialDocx($issuedAccount, $operator ?? 'NO_IDENTIFICADO', 'Restablecimiento de contraseña (cuenta rehabilitada)'));
                $notice = ($loginVerified ? 'Cuenta rehabilitada con una contraseña nueva, verificada en LDAP.' : 'Cuenta rehabilitada; la verificación en LDAP quedó pendiente.') .
                    (!$auditSaved ? ' AVISO: falló el registro final en la auditoría.' : '');
                unset($password);
            } elseif ($action === 'clave') {
                // Verificacion de identidad: quien atiende debe escribir el documento que presenta el titular.
                if ($docActual === '') {
                    if (!$mayAdminister) throw new RuntimeException('Primero registra la cédula de esta cuenta (más abajo) para poder verificar al titular.');
                } else {
                    $presentado = strtoupper(preg_replace('/[\s.\-]/', '', postString('verificar')) ?? '');
                    $esperado = str_starts_with($docActual, 'P-') ? substr($docActual, 2) : $docActual;
                    if (!hash_equals($esperado, $presentado)) {
                        auditEvent('CLAVE_VERIFICACION_FALLIDA', $uid, 'id=' . $requestId);
                        throw new RuntimeException('El documento no coincide con el registrado para ' . $uid . '. No se cambió la contraseña.');
                    }
                }
                if (!auditEvent('INTENTO_CLAVE', $uid, 'id=' . $requestId)) {
                    throw new RuntimeException('No se pudo preparar el registro de auditoría.');
                }
                $password = generatePassword();
                if (!@ldap_mod_replace($ldap, $dn, ['userPassword' => sshaHash($password)])) {
                    throw new RuntimeException('No se pudo restablecer la clave LDAP: ' . ldap_error($ldap));
                }
                $loginVerified = verifyLogin($dn, $password);
                $memberVerified = verifyMembership($ldap, $group['dn'], $dn);
                $auditSaved = auditEvent('CLAVE_RESTABLECIDA', $uid, 'id=' . $requestId . ' bind=' . ($loginVerified ? 'OK' : 'PENDIENTE'));
                $issuedAccount = [
                    'uid'=>$uid, 'mail'=>(string)($e['mail'][0] ?? ''), 'name'=>(string)($e['cn'][0] ?? ''),
                    'password'=>$password, 'type'=>$group['label'], 'gid'=>(string)$group['gid'],
                    'uidNumber'=>(string)($e['uidnumber'][0] ?? ''), 'group'=>$group['unix'],
                    'userVerified'=>true,'memberVerified'=>$memberVerified,'loginVerified'=>$loginVerified,
                    'auditSaved'=>$auditSaved,'reset'=>true,
                    'first'=>(string)($e['givenname'][0] ?? ''), 'last'=>(string)($e['sn'][0] ?? ''), 'doc'=>$docActual,
                ];
                $issuedAccount['docx'] = base64_encode(buildCredentialDocx($issuedAccount, $operator ?? 'NO_IDENTIFICADO', 'Restablecimiento de contraseña'));
                $notice = ($loginVerified ? 'Contraseña restablecida y verificada en LDAP. La anterior ya no funciona.' : 'Contraseña modificada; la verificación en LDAP quedó pendiente.') .
                    (!$auditSaved ? ' AVISO: falló el registro final en la auditoría.' : '');
                unset($password);
            } else {
                // SUSPENDER: NO borrar DN; puede conservar buzones, carpetas o referencias externas.
                $motivo = trim(str_replace(["\r", "\n", "\t"], ' ', postString('motivo')));
                if (mb_strlen($motivo, 'UTF-8') < 5 || mb_strlen($motivo, 'UTF-8') > 200) {
                    throw new RuntimeException('Indica un motivo entre 5 y 200 caracteres.');
                }
                if (postString('confirmar') !== $uid) {
                    throw new RuntimeException('Escribe el usuario exacto para confirmar el bloqueo.');
                }
                $created = ldapTime((string)($e['createtimestamp'][0] ?? ''));
                if ($created === null || time() - $created < 0 || time() - $created > SUSPENDER_HORAS * 3600) {
                    throw new RuntimeException('La suspensión desde este panel solo se permite durante las primeras ' . SUSPENDER_HORAS . ' horas.');
                }
                if (!auditEvent('INTENTO_SUSPENDER', $uid, 'id=' . $requestId . ' motivo=' . $motivo)) {
                    throw new RuntimeException('Falló el registro previo en la auditoría: operación cancelada.');
                }
                // Un solo ldap_modify_batch realiza ambas escrituras de esta entrada atomicas.
                // Contraseña aleatoria de 256 bits sin entregar a nadie: no se puede autenticar con ella.
                $impossiblePassword = bin2hex(random_bytes(32));
                $newDescription = $desc . ' [SUSPENDIDA-SECRETARIA] ' . gmdate('Y-m-d\\TH:i:s\\Z');
                $changes = [
                    ['attrib'=>'userPassword','modtype'=>LDAP_MODIFY_BATCH_REPLACE,'values'=>[sshaHash($impossiblePassword)]],
                    ['attrib'=>'description','modtype'=>LDAP_MODIFY_BATCH_REPLACE,'values'=>[$newDescription]],
                ];
                if (!@ldap_modify_batch($ldap, $dn, $changes)) {
                    throw new RuntimeException('No se pudo bloquear la cuenta LDAP: ' . ldap_error($ldap));
                }
                unset($impossiblePassword);
                $auditSaved = auditEvent('SUSPENDIDA', $uid, 'id=' . $requestId . ' motivo=' . $motivo);
                $notice = 'Se bloqueó el acceso de ' . $uid . '; la cuenta y su buzón se conservan. ' .
                    'Las sesiones ya abiertas pueden seguir activas hasta que se cierren.' .
                    (!$auditSaved ? ' AVISO: no se pudo escribir el registro final de la auditoría.' : '');
                $manageUid = '';
            }
        } else {
            $first = cleanName(postString('nombre'), 'Nombre');
            $last = cleanName(postString('apellido'), 'Apellido');
            $role = postString('tipo');
            if (!array_key_exists($role, GROUPS)) throw new RuntimeException('Selecciona Estudiante o Docente.');
            $group = GROUPS[$role];
            $firstSlug = normalizeUsernamePart(preg_split('/[\\s\\-]+/u', $first)[0] ?? '');
            [$surname1, $surname2] = splitSurnames($last);
            if ($firstSlug === '' || strlen($surname1) < 2) throw new RuntimeException('No se puede generar un usuario válido con ese nombre.');
            $doc = documentId(postString('doc_tipo'), postString('cedula'));
            $existente = findByDocument($ldap, $doc);
            if ($existente !== null) {
                $manageUid = $existente['uid'];
                $old = [];
                throw new RuntimeException('Esta persona ya tiene cuenta: «' . $existente['uid'] . '» (' . $existente['cn'] . '). No se creó un duplicado. Si olvidó su contraseña, restablécela abajo en «Gestionar cuenta».');
            }
            $homonimos = searchEntries($ldap, PERSONAS_BASE, '(&(objectClass=inetOrgPerson)(cn=' . ldap_escape($first . ' ' . $last, '', LDAP_ESCAPE_FILTER) . '))', ['uid']);
            if ($homonimos['count'] > 0 && postString('otra_persona') !== '1') {
                $lista = [];
                for ($h = 0; $h < $homonimos['count']; $h++) $lista[] = (string)($homonimos[$h]['uid'][0] ?? '');
                throw new RuntimeException('Ya existe(n) cuenta(s) con el nombre «' . $first . ' ' . $last . '»: ' . implode(', ', $lista) . '. Si de verdad es otra persona (otra cédula), marca la casilla «Es otra persona» y vuelve a enviar.');
            }
            $baseUid = substr($firstSlug,0,1) . substr($surname1,0,24);
            if (!validUid($baseUid)) throw new RuntimeException('No se pudo generar un usuario válido.');
            if (!auditEvent('INTENTO', '-', 'id=' . $requestId . ' rol=' . $role)) {
                throw new RuntimeException('La auditoría no está disponible; registro cancelado.');
            }
            $historical = reservedUids();
            $candidates = [$baseUid];
            if ($surname2 !== '') $candidates[] = substr($baseUid . substr($surname2,0,1), 0,30);
            for ($suffix=2; $suffix<=999; $suffix++) $candidates[] = substr($baseUid,0,30-strlen((string)$suffix)) . $suffix;
            $uid = '';
            foreach ($candidates as $candidate) {
                if (!validUid($candidate) || isset($historical[$candidate])) continue;
                $mailCandidate = $candidate . '@' . MAIL_DOMAIN;
                $filter = '(|(uid=' . ldap_escape($candidate,'',LDAP_ESCAPE_FILTER) . ')(mail=' . ldap_escape($mailCandidate,'',LDAP_ESCAPE_FILTER) . '))';
                if (!existsFilter($ldap, $filter)) { $uid = $candidate; break; }
            }
            if ($uid === '') throw new RuntimeException('No quedan variantes de nombre de usuario disponibles.');
            $mail = $uid . '@' . MAIL_DOMAIN;
            $usedNumbers = [];
            $taken = searchEntries($ldap, LDAP_BASE, '(uidNumber=*)', ['uidnumber']);
            for ($i=0; $i<$taken['count']; $i++) $usedNumbers[(int)($taken[$i]['uidnumber'][0] ?? 0)] = true;
            $uidNumber = 0;
            for ($n=UID_MIN; $n<=UID_MAX; $n++) {
                if (!isset($usedNumbers[$n])) { $uidNumber=$n; break; }
            }
            if ($uidNumber === 0) throw new RuntimeException('No quedan UID numéricos libres en el rango configurado.');
            $password=generatePassword();
            $dn='uid=' . $uid . ',' . ALTAS_BASE;
            $record=[
                'objectClass'=>['top','person','organizationalPerson','inetOrgPerson','posixAccount'],
                'uid'=>$uid, 'cn'=>$first . ' ' . $last, 'givenName'=>$first, 'sn'=>$last,
                'mail'=>$mail, 'uidNumber'=>(string)$uidNumber, 'gidNumber'=>(string)$group['gid'],
                'homeDirectory'=>'/home/'.$uid, 'loginShell'=>'/bin/false',
                'description'=>$group['label'].' - alta desde secretaria',
                'employeeNumber'=>$doc,
                'userPassword'=>sshaHash($password),
            ];
            if (!@ldap_add($ldap, $dn, $record)) {
                throw new RuntimeException('No se pudo crear el usuario LDAP: ' . ldap_error($ldap));
            }
            $memberDn = strtolower($dn);
            $addedMember = @ldap_mod_add($ldap, $group['dn'], ['member'=>$memberDn]);
            $memberError = $addedMember ? 0 : ldap_errno($ldap);
            $memberVerified = verifyMembership($ldap, $group['dn'], $dn);
            if ((!$addedMember && $memberError !== 20) || !$memberVerified) {
                $err = ldap_error($ldap);
                // Si el miembro fue añadido por este proceso, intentar limpiar primero.
                $clean = !$addedMember || @ldap_mod_del($ldap, $group['dn'], ['member'=>$memberDn]);
                $rolledBack = @ldap_delete($ldap, $dn);
                auditEvent(($clean && $rolledBack) ? 'ROLLBACK' : 'REVISAR_ALTA_PARCIAL', $uid,
                    'id=' . $requestId . ' member=' . ($clean?'OK':'FALLO') . ' delete=' . ($rolledBack?'OK':'FALLO'));
                throw new RuntimeException(($clean && $rolledBack)
                    ? 'No se verifico el grupo institucional; la cuenta fue revertida.'
                    : 'ALERTA: registro parcial. Contacta al administrador y proporciona el UID ' . $uid);
            }
            $userExists = existsFilter($ldap,'(uid=' . ldap_escape($uid,'',LDAP_ESCAPE_FILTER) . ')');
            $loginVerified = verifyLogin($dn,$password);
            $old = [];
            $auditSaved = auditEvent('CREADO',$uid,'id='.$requestId.' '.$role.' '.$uidNumber.' '.$mail.' doc='.maskDoc($doc).
                ' usuario='.($userExists?'OK':'PENDIENTE').' grupo=OK bind='.($loginVerified?'OK':'PENDIENTE'));
            $issuedAccount=[
                'uid'=>$uid,'mail'=>$mail,'name'=>$first.' '.$last,'password'=>$password,
                'type'=>$group['label'],'gid'=>(string)$group['gid'],'uidNumber'=>(string)$uidNumber,
                'group'=>$group['unix'],'userVerified'=>$userExists,'memberVerified'=>true,
                'loginVerified'=>$loginVerified,'auditSaved'=>$auditSaved,
                'first'=>$first,'last'=>$last,'doc'=>$doc,
            ];
            $issuedAccount['docx']=base64_encode(buildCredentialDocx($issuedAccount,$operator ?? 'NO_IDENTIFICADO'));
            $notice=($userExists && $loginVerified ? 'Cuenta creada y verificada en LDAP.' : 'Cuenta creada; alguna verificación quedó pendiente.').
                (!$auditSaved ? ' AVISO: falló el registro final de la auditoría.' : '');
            unset($password);
        }
        // Token distinto para impedir repetir altas/resets por POST de navegador.
        $_SESSION['csrf'] = bin2hex(random_bytes(32));
    } catch (Throwable $e) {
        $problem = $e->getMessage();
        auditEvent('ERROR', '-', $problem);
    } finally {
        if (is_resource($lock)) { flock($lock, LOCK_UN); fclose($lock); }
    }
}

$ldapStatus = 'Sin conexion';
$people = [];
$total = null;
$query = trim(getString('q'));
$query = mb_substr($query, 0, 60, 'UTF-8');
$shown = 0;
try {
    // Lectura con la cuenta de servicio: funciona aunque se bloquee la lectura anonima.
    $reader = ldapConnection(true);
    $rows = searchEntries($reader, PERSONAS_BASE, '(objectClass=inetOrgPerson)', ['uid', 'cn', 'mail', 'gidNumber', 'description', 'employeeNumber']);
    $total = $rows['count'];
    for ($i = 0; $i < $total; $i++) {
        $row = $rows[$i];
        $people[] = [
            'uid' => (string)($row['uid'][0] ?? ''),
            'cn' => (string)($row['cn'][0] ?? ''),
            'mail' => (string)($row['mail'][0] ?? ''),
            'doc' => (string)($row['employeenumber'][0] ?? ''),
            'suspended' => isSuspended((string)($row['description'][0] ?? '')),
            'altas' => $mayRegister && str_ends_with(strtolower((string)($row['dn'] ?? '')), strtolower(ALTAS_BASE)),
            'role' => match((string)($row['gidnumber'][0] ?? '')) {
                '12000', '10201' => 'Estudiante',
                '12001', '10101' => 'Docente',
                default => 'General',
            },
        ];
    }
    if ($query !== '') {
        $needle = mb_strtolower($query, 'UTF-8');
        $people = array_values(array_filter($people, fn($p) =>
            str_contains(mb_strtolower($p['uid'] . ' ' . $p['cn'] . ' ' . $p['mail'], 'UTF-8'), $needle)
            || ($p['doc'] !== '' && strlen($needle) >= 6 && str_contains(strtolower($p['doc']), preg_replace('/[\s.\-]/', '', $needle) ?? ''))));
    }
    if ($roleFilter !== 'todos') {
        $people = array_values(array_filter($people, fn($p) => mb_strtolower($p['role'], 'UTF-8') === $roleFilter));
    }
    usort($people, fn($a, $b) => strcmp($a['uid'], $b['uid']));
    $shown = count($people);
    $people = array_slice($people, 0, MAX_USERS_IN_TABLE);
    $ldapStatus = 'Conectado';
} catch (Throwable $e) {
    $ldapStatus = 'No disponible';
    if ($problem === '') {
        $problem = 'No se pudo consultar OpenLDAP. Verifica el servicio slapd.';
    }
}
if ($manageUid !== '' && validUid($manageUid) && $ldapStatus === 'Conectado') {
    try {
        $r = @ldap_read($reader, 'uid=' . $manageUid . ',' . ALTAS_BASE, '(objectClass=posixAccount)', ['uid', 'cn', 'mail', 'gidnumber', 'createtimestamp', 'description', 'employeenumber']);
        $m = $r ? ldap_get_entries($reader, $r) : false;
        if ($m && ($m['count'] ?? 0) === 1) {
            $created = ldapTime((string)($m[0]['createtimestamp'][0] ?? ''));
            $g = groupByGid((string)($m[0]['gidnumber'][0] ?? ''));
            $manage = [
                'uid' => $manageUid,
                'cn' => (string)($m[0]['cn'][0] ?? ''),
                'mail' => (string)($m[0]['mail'][0] ?? ''),
                'type' => $g['label'] ?? 'General',
                'created' => $created ? date('d/m/Y H:i', $created) : '—',
                'suspended' => isSuspended((string)($m[0]['description'][0] ?? '')),
                'doc' => (string)($m[0]['employeenumber'][0] ?? ''),
                'canSuspend' => $mayAdminister && $created !== null && time() - $created >= 0 && time() - $created <= SUSPENDER_HORAS * 3600 &&
                    str_contains((string)($m[0]['description'][0] ?? ''), 'alta desde secretaria') &&
                    !isSuspended((string)($m[0]['description'][0] ?? '')),
            ];
        } elseif ($problem === '') {
            $problem = 'Solo se gestionan desde aquí las cuentas creadas por el panel (ou=Altas).';
        }
    } catch (Throwable $e) {
        // sin gestion si falla la lectura
    }
}
$recent = recentRegistrations(8);
?><!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light">
<title>Secretaría | <?= esc(INSTITUCION) ?></title>
<style>
:root{--navy:#102743;--navy2:#1e4169;--accent:#2463bb;--accent-dark:#194d95;--ink:#182c43;--muted:#63758a;--bg:#f3f6fb;--panel:#fff;--line:#e0e7ef;--green:#177c56;--red:#9a2b3a;--amber:#8b5d12}
*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.55 system-ui,-apple-system,"Segoe UI",Roboto,Arial,sans-serif}
a{color:var(--accent)}.topbar{background:linear-gradient(115deg,var(--navy),var(--navy2));color:#fff;padding:27px clamp(18px,6vw,85px) 31px}.head-inner{max-width:1240px;margin:auto;display:flex;align-items:center;justify-content:space-between;gap:18px;flex-wrap:wrap}.eyebrow{color:#c0d3e8;font-size:11px;letter-spacing:.15em;text-transform:uppercase;font-weight:800}.brand{display:flex;align-items:center;gap:14px}.mark{width:48px;height:48px;border:1px solid #6d94c1;background:#ffffff13;border-radius:14px;display:grid;place-items:center;font-size:23px;font-weight:850}.brand h1{margin:0;font-size:25px;line-height:1.25;letter-spacing:-.02em}.brand p{margin:5px 0 0;color:#d2deed;font-size:13px}.secure-tag{font-size:12px;border:1px solid #7794b8;border-radius:99px;padding:9px 13px;color:#edf5ff;max-width:100%;overflow-wrap:anywhere}
main{max-width:1240px;margin:28px auto 54px;padding:0 22px}.section-lead{display:flex;justify-content:space-between;gap:14px;align-items:end;margin-bottom:17px;flex-wrap:wrap}.section-lead h2{font-size:23px;letter-spacing:-.025em;margin:0}.section-lead p{margin:2px 0 0;color:var(--muted);font-size:13px}.version{font-size:12px;color:var(--muted)}
.stats{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:15px;margin-bottom:23px}.stat,.panel{background:var(--panel);border:1px solid var(--line);border-radius:13px;box-shadow:0 5px 18px #16345309}.stat{padding:19px 22px}.stat span{display:block;font-size:12px;font-weight:700;color:var(--muted);margin-bottom:10px}.stat strong{font-size:24px;letter-spacing:-.02em;line-height:1.1}.green{color:var(--green)}.orange{color:var(--amber)}.stat small{display:block;margin-top:7px;color:var(--muted);font-size:11px}
.layout{display:grid;grid-template-columns:minmax(320px,0.95fr) minmax(390px,1.35fr);gap:20px;align-items:start}.panel{padding:24px}.panel-header{display:flex;align-items:flex-start;gap:11px;margin-bottom:22px}.step-icon{width:35px;height:35px;background:#edf4ff;border:1px solid #d9e8fc;border-radius:9px;display:grid;place-items:center;color:var(--accent);font-weight:800;flex:0 0 35px}.panel h3{margin:0;font-size:19px;letter-spacing:-.015em}.panel-header p{font-size:12px;color:var(--muted);margin:4px 0 0}.field{margin:0 0 16px}.field label{display:block;font-weight:750;font-size:13px;margin:0 0 6px}.field input,.field select,.search input,.search select{display:block;width:100%;min-height:43px;border:1px solid #cbd7e5;background:#fff;border-radius:8px;padding:9px 12px;color:var(--ink);font-size:14px;font-family:inherit}.field input:focus,.field select:focus,.search input:focus,.search select:focus{outline:3px solid #d5e7ff;border-color:var(--accent)}.required{color:var(--red)}.hint{display:block;color:var(--muted);font-size:11px;margin-top:5px}.form-legend{font-size:12px;letter-spacing:.06em;text-transform:uppercase;font-weight:800;color:var(--muted);margin:4px 0 14px}.btn{border:0;border-radius:9px;background:var(--accent);color:white;padding:12px 16px;font-weight:750;cursor:pointer;font-size:14px;text-decoration:none;display:inline-block;text-align:center}.btn:hover{background:var(--accent-dark)}.btn:focus-visible{outline:3px solid #9dc8ff}.btn-full{width:100%}.btn:disabled{background:#94a3b8;cursor:not-allowed}.notice{border-radius:9px;padding:13px 14px;margin:0 0 18px;font-size:13px}.error{background:#fff0f2;border:1px solid #f0c4cc;color:#842636}.success{background:#effaf3;border:1px solid #bfe2c9;color:#18603d}.warn{background:#fff9e9;border:1px solid #f0ddb2;color:#815a16}.info{background:#f0f6fd;border:1px solid #d4e4f7;color:#365b82}.separator{height:1px;background:var(--line);margin:22px 0}.result{border:1px solid #b6dfc9;background:#f4fbf6;border-radius:11px;padding:18px;margin-bottom:20px}.result h4{margin:0 0 10px;font-size:17px}.result-grid{display:grid;grid-template-columns:1fr 1fr;gap:10px}.item small{display:block;color:#687c7c;font-size:11px}.item strong{font-size:13px;overflow-wrap:anywhere}.item-wide{grid-column:1/-1}.password{font-family:Consolas,monospace;letter-spacing:.07em;font-size:18px!important}.check-row{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-top:10px}.chip{font-size:11px;padding:4px 8px;border-radius:99px;background:#eaf1fb;color:#385b7f}.chip.ok{background:#def3e7;color:#16633b}.chip.wait{background:#fff1d0;color:#876110}.download{margin-top:15px;display:block;background:var(--green);color:white;text-decoration:none;text-align:center;border-radius:8px;padding:11px;font-size:13px;font-weight:800}.download:hover{background:#0c6340}.fine{font-size:12px;color:var(--muted);margin-top:12px}.status-line{display:flex;align-items:center;gap:8px;color:var(--muted);font-size:12px;margin-top:12px}.dot{display:inline-block;width:7px;height:7px;border-radius:50%;background:var(--green)}
.session-controls{display:flex;align-items:center;gap:12px;flex-wrap:wrap}.logout-form{margin:0}.logout-btn{font:inherit;font-size:12px;font-weight:800;color:white;background:#ffffff1a;border:1px solid #b4cee9;border-radius:99px;padding:9px 14px;cursor:pointer}.logout-btn:hover{background:#ffffff35}.logout-btn:focus-visible{outline:3px solid #b2d5ff}.search{display:grid;grid-template-columns:1fr 145px auto;gap:8px;margin-bottom:12px}.search .btn{white-space:nowrap}.table-wrap{overflow-x:auto;border:1px solid var(--line);border-radius:9px}table{border-collapse:collapse;width:100%;white-space:nowrap}thead{background:#f8fafc}th{text-transform:uppercase;letter-spacing:.05em;font-weight:800;font-size:10px;color:#62748b;text-align:left;padding:11px 12px;border-bottom:1px solid var(--line)}td{padding:11px 12px;border-bottom:1px solid #edf1f5;font-size:12px}tr:last-child td{border-bottom:0}tbody tr:nth-child(even){background:#fafcff}td small{font-size:11px;color:var(--muted)}.mail{color:#225b9a}.tag{display:inline-block;padding:4px 8px;border-radius:8px;background:#eff4fb;color:#3d5f81;font-size:11px;font-weight:700}.empty{text-align:center;color:var(--muted);padding:25px}.recent-title{font-size:15px!important;margin:0 0 11px!important}.foot{margin-top:25px;font-size:12px;color:var(--muted);border-top:1px solid #dce4ef;padding-top:13px;line-height:1.75}.print-only{display:none}
@media(max-width:960px){.layout{grid-template-columns:1fr}.stats{grid-template-columns:repeat(3,1fr)}}@media(max-width:620px){main{padding:0 13px}.topbar{padding:22px 17px}.brand h1{font-size:20px}.stats{grid-template-columns:1fr}.stat{padding:15px}.stat strong{font-size:22px}.panel{padding:17px}.search{grid-template-columns:1fr 1fr}.search input{grid-column:1/-1}.search .btn{grid-column:auto}}
<?= THEME_CSS ?>
:root{--navy:#0D3A1D;--navy2:#1B6B37;--accent:#14532A;--accent-dark:#0D3A1D;--ink:#1f2937;--muted:#6b7280;--bg:#F7F4EC;--line:#e7e2d5;--green:#1B6B37;--red:#b91c1c;--amber:#92400e}
a{color:var(--verde)}
.topbar{background:linear-gradient(135deg,var(--verde-osc) 0%,var(--verde) 60%,var(--verde-med) 100%);padding:24px clamp(18px,6vw,85px) 28px;box-shadow:inset 0 -3px 0 var(--dorado)}
.eyebrow{color:var(--dorado-cl);letter-spacing:.2em}.mark{width:64px;height:64px;padding:3px}.brand h1{font:600 27px/1.2 Georgia,"Times New Roman",serif;letter-spacing:0}.brand p{color:rgba(255,255,255,.82)}
.secure-tag{border:1px solid rgba(233,212,138,.45);background:rgba(255,255,255,.06);color:#f3f4f6}
.logout-btn{border:1px solid var(--dorado);background:transparent;color:#fff}.logout-btn:hover{background:var(--dorado);color:var(--verde-osc)}
.section-lead h2,.panel h3{font-family:Georgia,"Times New Roman",serif;font-weight:600;color:var(--verde);letter-spacing:0}.section-lead h2{font-size:26px}
.stat,.panel{border:1px solid var(--line);border-radius:16px;box-shadow:0 6px 22px rgba(13,58,29,.07)}.stat span{color:#6b7280;letter-spacing:.06em;font-weight:700}
.step-icon{background:var(--verde-claro);border:1px solid #cfe3d5;color:var(--verde);border-radius:10px;font-family:Georgia,serif}
.form-legend{color:#8a7a3a;letter-spacing:.14em}.field label{color:#374151}
.field input,.field select,.search input,.search select{border:1px solid #d9d3c3;background:#fffdf8;border-radius:10px}.field input:focus,.field select:focus,.search input:focus,.search select:focus{outline:3px solid rgba(20,83,42,.16);border-color:var(--verde)}
.btn{background:var(--verde);border-radius:10px;font-weight:700}.btn:hover{background:var(--verde-osc)}.btn:focus-visible{outline:3px solid var(--dorado-cl)}
.notice{border-radius:12px}.success{background:var(--verde-claro);border-color:#cfe3d5;color:var(--verde-osc)}.info{background:#fbf7e8;border-color:#efe2b0;color:#5b4a12}
.result{border:1px solid #cfe3d5;border-top:4px solid var(--dorado);background:#fff;border-radius:14px;box-shadow:0 8px 24px rgba(13,58,29,.08)}.result h4{font-family:Georgia,serif;color:var(--verde)}
.password{background:#fbf7e8;border:1px dashed var(--dorado);border-radius:8px;padding:4px 10px;display:inline-block;color:#1f2937}
.chip{background:var(--verde-claro);color:var(--verde)}.chip.ok{background:#dcfce7;color:#166534}.chip.wait{background:#fef3c7;color:#92400e}.tag{background:var(--verde-claro);color:var(--verde)}
.download{background:var(--verde);border-radius:10px}.download:hover{background:var(--verde-osc)}
.table-wrap{border-radius:12px}thead{background:#f3efe4}th{color:#6b5f3a}tbody tr:nth-child(even){background:#fcfaf4}.mail{color:var(--verde-med)}
.green{color:var(--verde-med)}.version{color:#8a7a3a;font-weight:600}.foot{border-top:1px solid var(--line)}
@media print{*{print-color-adjust:exact}.topbar,.stats,.search,form,.foot,.list-panel,.notice,.hide-on-print{display:none!important}body{background:#fff}main{margin:0;padding:0}.layout{display:block}.panel{border:0;box-shadow:none;padding:0}.result{border:1px solid #777;background:#fff}.print-only{display:block}.result-grid{grid-template-columns:1fr 1fr}}
</style>
</head>
<body>
<div class="franja"></div>
<header class="topbar"><div class="head-inner"><div class="brand"><span class="mark logo"><?= logoImg('Logo ' . INSTITUCION) ?></span><div><span class="eyebrow"><?= esc(INSTITUCION) ?></span><h1>Panel de secretaría</h1><p>Secretaría General · Administración de identidades · OpenLDAP</p></div></div><div class="session-controls"><span class="secure-tag">Acceso privado · SRV-BD · <?= esc($operator ?? 'Operador no identificado') ?> · <?= esc($operatorRole ?? '') ?><?php $pl = (int)($_SESSION['previous_login'] ?? 0); ?> · <?= $pl > 0 ? esc('Último acceso: ' . date('d/m/Y H:i', $pl)) : 'Primer acceso' ?></span><form method="post" action="/secretaria/" class="logout-form"><input type="hidden" name="auth_action" value="logout"><input type="hidden" name="csrf" value="<?= esc((string)$_SESSION['csrf']) ?>"><button type="submit" class="logout-btn" aria-label="Cerrar sesión actual">Cerrar sesión</button></form></div></div></header>
<main>
  <div class="section-lead"><div><h2>Resumen del directorio</h2><p>Consulta de cuentas y alta de estudiantes y docentes.</p></div><span class="version">Panel de Secretaría · <?= esc(date('d/m/Y H:i')) ?></span></div>
  <div class="stats">
    <div class="stat"><span>ESTADO DE OPENLDAP</span><strong class="<?= $ldapStatus === 'Conectado' ? 'green' : 'orange' ?>"><?= esc($ldapStatus) ?></strong><small>Servidor LDAP: SRV-BD</small></div>
    <div class="stat"><span>CUENTAS EN EL DIRECTORIO</span><strong><?= $total === null ? '—' : (int)$total ?></strong><small>Personas y subunidades</small></div>
    <div class="stat"><span>REGISTRO DE CUENTAS</span><strong class="<?= ENABLE_REGISTRATION ? 'green' : 'orange' ?>"><?= ENABLE_REGISTRATION ? 'Según permisos' : 'Pruebas' ?></strong><small><?= ENABLE_REGISTRATION ? esc('Tu rol: ' . ($operatorRole ?? 'sin rol')) : 'Escritura desactivada por seguridad' ?></small></div>
  </div>
  <?php if ($problem !== ''): ?><div class="notice error" role="alert"><?= esc($problem) ?></div><?php endif; ?>
  <div class="layout">
    <section class="panel" aria-labelledby="reg-heading">
      <div class="panel-header"><span class="step-icon" aria-hidden="true">01</span><div><h3 id="reg-heading">Registrar una cuenta</h3><p>Generación automática de nombre de usuario, UID, correo y pertenencia a grupos.</p></div></div>
      <?php if (!ENABLE_REGISTRATION): ?><div class="notice warn">Modo de revisión: las altas están desactivadas. Verifica las credenciales web, los permisos del operador y las políticas de Tailscale antes de activar <code>ENABLE_REGISTRATION</code>.</div><?php endif; ?>
      <?php if ($notice !== ''): ?><div class="notice <?= $issuedAccount !== null && !$issuedAccount['auditSaved'] ? 'warn' : 'success' ?>" role="status"><?= esc($notice) ?></div><?php endif; ?>
      <?php if ($issuedAccount !== null): ?>
        <div class="result" role="status">
          <div class="print-only"><strong><?= esc(INSTITUCION) ?></strong><p>Ficha de entrega de credenciales</p></div>
          <h4><?= !empty($issuedAccount['reset']) ? 'Nueva contraseña generada' : 'Credenciales generadas' ?></h4>
          <div class="result-grid">
            <div class="item item-wide"><small>Nombre completo</small><strong><?= esc($issuedAccount['name']) ?></strong></div>
            <div class="item"><small>Usuario</small><strong><?= esc($issuedAccount['uid']) ?></strong></div>
            <div class="item"><small>Tipo</small><strong><?= esc($issuedAccount['type']) ?></strong></div>
            <div class="item item-wide"><small>Correo institucional</small><strong><?= esc($issuedAccount['mail']) ?></strong></div>
            <div class="item"><small>UID</small><strong><?= esc($issuedAccount['uidNumber']) ?></strong></div>
            <div class="item"><small>GID</small><strong><?= esc($issuedAccount['gid']) ?></strong></div>
            <div class="item item-wide"><small>Contraseña generada (incluye los guiones)</small><strong class="password"><?= esc($issuedAccount['password']) ?></strong></div>
          </div>
          <div class="check-row"><span class="chip <?= $issuedAccount['userVerified'] ? 'ok' : 'wait' ?>">Cuenta <?= $issuedAccount['userVerified'] ? 'verificada' : 'por revisar' ?></span><span class="chip <?= $issuedAccount['memberVerified'] ? 'ok' : 'wait' ?>">Grupo <?= $issuedAccount['memberVerified'] ? 'verificado' : 'por revisar' ?></span><span class="chip <?= $issuedAccount['loginVerified'] ? 'ok' : 'wait' ?>">LDAP <?= $issuedAccount['loginVerified'] ? 'autenticado' : 'por revisar' ?></span></div>
          <a class="download hide-on-print" download="cuenta-<?= esc($issuedAccount['uid']) ?><?= !empty($issuedAccount['reset']) ? '-nueva-clave' : '' ?>.docx" href="data:application/vnd.openxmlformats-officedocument.wordprocessingml.document;base64,<?= $issuedAccount['docx'] ?>">Descargar ficha en Word (.docx)</a>
          <p class="fine">La ficha contiene una contraseña en texto legible. Entrégala por un canal seguro y elimina las copias innecesarias. No se escribe la contraseña en la auditoría; la ficha descargada sí contiene la clave. Si se pierde, solicita un restablecimiento a un administrador.</p>
        </div>
      <?php endif; ?>
      <?php if ($manage !== null): ?>
        <div class="result hide-on-print" style="background:#f7f9fd;border-color:#d4e1f2">
          <h4>Gestionar cuenta: <?= esc($manage['uid']) ?></h4>
          <p class="fine" style="margin-top:0"><?= esc($manage['cn']) ?> · <?= esc($manage['mail']) ?> · <?= esc($manage['type']) ?> · creada el <?= esc($manage['created']) ?> · Documento: <strong><?= $manage['doc'] !== '' ? esc(maskDoc($manage['doc'])) : 'sin registrar' ?></strong></p>
          <?php if ($manage['doc'] === '' && !$manage['suspended']): ?><form method="post" action="" autocomplete="off" style="margin-bottom:14px">
            <input type="hidden" name="csrf" value="<?= esc((string)$_SESSION['csrf']) ?>">
            <input type="hidden" name="accion" value="cedula"><input type="hidden" name="uid" value="<?= esc($manage['uid']) ?>">
            <div class="notice warn" style="margin:0 0 10px">Esta cuenta no tiene cédula registrada. Regístrala con el documento físico del titular para evitar duplicados y poder verificar restablecimientos.</div>
            <div class="field"><label for="doc_tipo_m">Tipo de documento</label><select id="doc_tipo_m" name="doc_tipo"><option value="cedula">Cédula ecuatoriana</option><option value="pasaporte">Pasaporte (extranjeros)</option></select></div>
            <div class="field"><label for="cedula_m">Número</label><input id="cedula_m" name="cedula" maxlength="20" required inputmode="numeric" autocomplete="off" placeholder="10 dígitos"></div>
            <button class="btn btn-full" type="submit">Registrar documento</button>
          </form><?php endif; ?>
          <?php if (!$manage['suspended']): ?><form method="post" action="" autocomplete="off">
            <input type="hidden" name="csrf" value="<?= esc((string)$_SESSION['csrf']) ?>">
            <input type="hidden" name="accion" value="clave"><input type="hidden" name="uid" value="<?= esc($manage['uid']) ?>">
            <?php if ($manage['doc'] !== ''): ?><div class="field"><label for="verificar">Documento que presenta el titular <span class="required">*</span></label><input id="verificar" name="verificar" maxlength="20" required autocomplete="off" placeholder="Pide la cédula y escríbela"><small class="hint">Debe coincidir con la registrada (termina en <?= esc(substr($manage['doc'], -4)) ?>). Así se evita entregar claves a otra persona.</small></div><?php endif; ?>
            <button class="btn btn-full" type="submit" <?= (!$mayRegister || ($manage['doc'] === '' && !$mayAdminister)) ? 'disabled' : '' ?>>Generar nueva contraseña y ficha</button>
            <small class="hint">La contraseña anterior deja de funcionar. Úsalo si el usuario la olvidó o perdió su ficha.</small>
          </form>
          <?php else: ?><div class="notice warn">Cuenta suspendida: no puede iniciar sesión. Su buzón y sus datos se conservan.<?= !$mayAdminister ? ' Solo administración puede rehabilitarla.' : '' ?></div>
          <?php if ($mayAdminister): ?><form method="post" action="" autocomplete="off">
            <input type="hidden" name="csrf" value="<?= esc((string)$_SESSION['csrf']) ?>">
            <input type="hidden" name="accion" value="rehabilitar"><input type="hidden" name="uid" value="<?= esc($manage['uid']) ?>">
            <button class="btn btn-full" style="background:var(--green)" type="submit" <?= !$mayAdminister ? 'disabled' : '' ?>>Rehabilitar cuenta con una contraseña nueva</button>
            <small class="hint">Devuelve el acceso y genera una ficha nueva. La contraseña anterior no se recupera.</small>
          </form><?php endif; ?><?php endif; ?>
          <div class="separator"></div>
          <?php if ($manage['canSuspend']): ?>
          <form method="post" action="" autocomplete="off">
            <input type="hidden" name="csrf" value="<?= esc((string)$_SESSION['csrf']) ?>">
            <input type="hidden" name="accion" value="suspender"><input type="hidden" name="uid" value="<?= esc($manage['uid']) ?>">
            <div class="field"><label for="motivo">Motivo del bloqueo <span class="required">*</span></label><input id="motivo" name="motivo" maxlength="200" required placeholder="Ej.: nombre mal escrito, rol equivocado"></div>
            <div class="field"><label for="confirmar">Escribe <strong><?= esc($manage['uid']) ?></strong> para confirmar <span class="required">*</span></label><input id="confirmar" name="confirmar" maxlength="30" required autocomplete="off"></div>
            <button class="btn btn-full" style="background:var(--red)" type="submit" <?= !$mayAdminister ? 'disabled' : '' ?>>Bloquear autenticación LDAP (reversible por administración)</button>
            <small class="hint">No elimina la cuenta ni buzones. Impide nuevas autenticaciones LDAP por contraseña y requiere revisión de los servicios vinculados. Máximo <?= SUSPENDER_HORAS ?> horas desde el alta.</small>
          </form>
          <?php else: ?>
          <?php if (!$manage['suspended']): ?><div class="notice info" style="margin:0"><?= $mayAdminister ? 'El bloqueo desde el panel solo es posible durante las primeras ' . SUSPENDER_HORAS . ' horas tras el alta. Para esta cuenta, contacta al administrador LDAP.' : 'Si esta cuenta es un duplicado o tiene datos errados, pide a administración que la bloquee (posible durante las primeras ' . SUSPENDER_HORAS . ' horas).' ?></div><?php endif; ?>
          <?php endif; ?>
          <p class="fine"><a href="?">Cerrar gestión</a></p>
        </div>
      <?php endif; ?>
      <form method="post" action="" autocomplete="off">
        <input type="hidden" name="csrf" value="<?= esc((string)$_SESSION['csrf']) ?>">
        <input type="hidden" name="accion" value="crear">
        <div class="form-legend">Datos de la persona</div>
        <div class="field"><label for="doc_tipo">Documento de identidad <span class="required">*</span></label><select id="doc_tipo" name="doc_tipo" <?= !$mayRegister ? 'disabled' : '' ?>><option value="cedula">Cédula ecuatoriana</option><option value="pasaporte" <?= ($old['doc_tipo'] ?? '') === 'pasaporte' ? 'selected' : '' ?>>Pasaporte (extranjeros)</option></select></div>
        <div class="field"><label for="cedula">Número de documento <span class="required">*</span></label><input id="cedula" name="cedula" maxlength="20" inputmode="numeric" autocomplete="off" required placeholder="10 dígitos" value="<?= esc($old['cedula'] ?? '') ?>" <?= !$mayRegister ? 'disabled' : '' ?>><small class="hint">Es el identificador único: si la persona ya tiene cuenta, el panel la muestra en vez de crear otra.</small></div>
        <div class="field"><label for="nombre">Nombre(s) <span class="required">*</span></label><input id="nombre" name="nombre" maxlength="60" autocomplete="off" required placeholder="Ej.: María Fernanda" value="<?= esc($old['nombre'] ?? '') ?>" <?= !$mayRegister ? 'disabled' : '' ?>><small class="hint">Admite tildes, apellidos compuestos y varios nombres.</small></div>
        <div class="field"><label for="apellido">Apellido(s) <span class="required">*</span></label><input id="apellido" name="apellido" maxlength="60" autocomplete="off" required placeholder="Ej.: López de la Torre" value="<?= esc($old['apellido'] ?? '') ?>" <?= !$mayRegister ? 'disabled' : '' ?>></div>
        <div class="field"><label for="tipo">Rol institucional <span class="required">*</span></label><select id="tipo" name="tipo" required <?= !$mayRegister ? 'disabled' : '' ?>><option value="estudiante">Estudiante</option><option value="docente" <?= ($old['tipo'] ?? '') === 'docente' ? 'selected' : '' ?>>Docente</option></select><small class="hint">Se asignarán el GID Unix y la membresía LDAP del rol.</small></div>
        <?php if (!empty($old) && str_contains($problem, 'Es otra persona')): ?><label style="display:flex;gap:8px;align-items:flex-start;font-size:13px;margin:4px 0 14px"><input type="checkbox" name="otra_persona" value="1" style="width:auto;height:auto;margin-top:3px"> <span><strong>Es otra persona</strong> (tiene otra cédula). Crear la cuenta de todos modos.</span></label><?php endif; ?>
        <button class="btn btn-full" type="submit" <?= !$mayRegister ? 'disabled' : '' ?>>Crear cuenta institucional</button>
      </form>
      <p class="fine">El registro crea cuentas bajo <code>ou=Altas</code>. Los bloqueos conservan el usuario y sus datos; no revocan sesiones ni detienen automáticamente el correo. Las operaciones registran su identificador de auditoría.</p>
    </section>
    <section class="panel list-panel" aria-labelledby="list-heading">
      <div class="panel-header"><span class="step-icon" aria-hidden="true">02</span><div><h3 id="list-heading">Directorio de usuarios</h3><p>Busca por usuario, nombre, correo o cédula. Secretaría restablece contraseñas verificando la cédula del titular; bloquear o rehabilitar cuentas es solo de administración.</p></div></div>
      <form class="search" method="get" action=""><input name="q" value="<?= esc($query) ?>" maxlength="60" placeholder="Usuario, nombre, correo o cédula" aria-label="Buscar usuarios"><select name="rol" aria-label="Filtrar por rol"><option value="todos" <?= $roleFilter==='todos'?'selected':'' ?>>Todos los roles</option><option value="estudiante" <?= $roleFilter==='estudiante'?'selected':'' ?>>Estudiantes</option><option value="docente" <?= $roleFilter==='docente'?'selected':'' ?>>Docentes</option><option value="general" <?= $roleFilter==='general'?'selected':'' ?>>Otros</option></select><button class="btn" type="submit">Buscar</button></form>
      <p class="fine"><?= (int)$shown ?> resultado(s) con los filtros seleccionados.</p>
      <div class="table-wrap"><table><thead><tr><th>Usuario</th><th>Nombre</th><th>Cédula</th><th>Correo</th><th>Tipo</th><th></th></tr></thead><tbody>
      <?php foreach ($people as $person): ?><tr><td><strong><?= esc($person['uid']) ?></strong></td><td><?= esc($person['cn']) ?></td><td><?= $person['doc'] !== '' ? esc(maskDoc($person['doc'])) : '<span style="color:#9a6b12">sin registrar</span>' ?></td><td class="mail"><?= esc($person['mail']) ?></td><td><span class="tag"><?= esc($person['role']) ?></span><?php if ($person['suspended']): ?> <span class="tag" style="background:#fdecee;color:#9a2b3a">Suspendida</span><?php endif; ?></td><td><?php if ($person['altas']): ?><a href="?gestionar=<?= esc(rawurlencode($person['uid'])) ?>">Gestionar</a><?php endif; ?></td></tr><?php endforeach; ?>
      <?php if (!$people): ?><tr><td colspan="6" class="empty">No se encontraron usuarios para esta búsqueda.</td></tr><?php endif; ?>
      </tbody></table></div>
      <?php if ($shown > MAX_USERS_IN_TABLE): ?><p class="fine">Se muestran <?= MAX_USERS_IN_TABLE ?> de <?= (int)$shown ?> coincidencias. Ajusta la búsqueda.</p><?php endif; ?>
      <div class="separator"></div><h3 class="recent-title">Últimos movimientos del panel</h3>
      <?php if ($recent): ?><div class="table-wrap"><table><thead><tr><th>Fecha</th><th>Usuario</th><th>Evento</th><th>Rol</th><th>Operador</th></tr></thead><tbody>
      <?php foreach ($recent as $r): ?><tr><td><?= esc($r['when']) ?></td><td><strong><?= esc($r['uid']) ?></strong></td><td><?= esc($r['event']) ?></td><td><?= esc($r['type']) ?></td><td><?= esc($r['by']) ?></td></tr><?php endforeach; ?></tbody></table></div><?php else: ?><p class="fine">Todavía no existen altas registradas en esta aplicación.</p><?php endif; ?>
      <div class="notice info" style="margin-top:20px">Seguridad: usa cuentas individuales con contraseñas web protegidas y roles asignados con secretaria_usuarios_v9.php (o /etc/secretaria/operadores.ini). Tailscale Serve también requiere políticas de acceso restringidas a operadores autorizados. El botón de cierre de sesión invalida la sesión PHP.</div>
    </section>
  </div>
  <footer class="foot">SRV-BD · Correo <code>@mejoland.edu.ec</code> · PHP 8.4 · Acceso por sesión PHP individual y Tailscale Serve.<br>Las contraseñas se muestran una sola vez y no se guardan. Una cuenta LDAP verificada no garantiza por si sola el acceso a Roundcube ni Wi-Fi; ambos servicios requieren pruebas de integración.</footer>
</main>
</body>
</html>
