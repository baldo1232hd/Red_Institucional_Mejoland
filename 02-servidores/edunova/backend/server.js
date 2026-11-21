/*
 * EduNova - servidor web y API de la plataforma educativa (Centro Educativo Mejoland)
 *
 * Identidad: OpenLDAP (cuentas creadas en el Panel de Secretaria). Roles por grupo LDAP:
 *   admin     = grupo administracion
 *   secretary = grupo secretaria: servicios, matricula, consulta del directorio, impresion
 *   teacher   = grupo docentes      (o gidNumber 12001)
 *   student   = grupo estudiantes   (o gidNumber 12000)
 * Datos academicos: MariaDB, base institucion, tablas lms_*.
 *
 * Permisos (siempre comprobados en el servidor, nunca en el navegador):
 *   admin   -> gestion administrativa: crea/edita/archiva cursos, asigna docente,
 *              matricula estudiantes y revisa la auditoria. Supervisa en solo lectura el
 *              contenido academico (anuncios, actividades, entregas, notas): no publica,
 *              no crea actividades ni califica (separacion de funciones).
 *   teacher -> solo sus cursos: anuncios, actividades, revision de entregas y calificacion,
 *              con ponderacion por tipo de actividad (promedio final sobre 10).
 *   student -> solo cursos donde esta matriculado: anuncios, actividades, entregas
 *              antes de la fecha limite y sus propias notas.
 *
 * Modulos:
 *   - Portal de servicios institucionales (correo, nube, GLPI, impresion...) con permisos por rol
 *     y por grupo LDAP, definidos en /etc/edunova/servicios.json.
 *   - Impresion: envio de PDF/JPG/PNG con cupo diario de paginas y color segun el rol; grupo de
 *     impresoras (elige la libre, con papel y menos cola); alta y baja de impresoras desde la
 *     plataforma. Usa la API de impresion local (127.0.0.1:8000, clave en .env).
 *   - Impresion diferida: si la API de impresion no responde (por ejemplo, la plataforma la atiende
 *     el servidor de respaldo), el documento se guarda en la base y se imprime al volver el servicio.
 *   - Copia de cada documento impreso (PRINT_RETENCION_DIAS), visible solo para administracion
 *     y registrada en la auditoria.
 *   - Biblioteca institucional: libros digitales y recursos de estudio con permisos jerarquicos
 *     (administracion > secretaria > docentes > estudiantes); archivos guardados en MariaDB.
 *   - Cambio de contrasena propia (LDAP: correo, Wi-Fi y plataforma) desde "Mi perfil".
 *
 * Alta disponibilidad y publicacion:
 *   - LDAP_URL admite varias direcciones (SRV-BD y la replica de damian); si la principal no
 *     responde se usa la replica. El cambio de clave siempre va a la principal.
 *   - El proxy inverso de la DMZ (PROXY_DMZ) marca con 'X-Mejoland-Internet: 1' las peticiones
 *     que llegan desde Internet: el portal muestra solo los servicios publicados ('url_publica').
 *
 * Seguridad: sesion en el servidor (cookie HttpOnly, SameSite=Strict, Secure detras del proxy),
 * filtros LDAP escapados, limite de intentos de inicio de sesion y errores genericos.
 * Dependencias: express, ldapjs, mysql2, dotenv.
 */
'use strict';
const express = require('express');
const ldap = require('ldapjs');
const mysql = require('mysql2/promise');
const crypto = require('crypto');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '.env'), quiet: true });

const CFG = {
  host: process.env.HOST || '127.0.0.1',
  port: Number(process.env.PORT || 3001),
  ldapUrl: process.env.LDAP_URL || 'ldap://127.0.0.1:389',
  baseDn: process.env.LDAP_BASE_DN || 'dc=proyecto,dc=local',
  bindDn: process.env.LDAP_BIND_DN || '',
  bindPw: process.env.LDAP_BIND_PASSWORD || '',
  frontend: process.env.FRONTEND_DIR || '/var/www/lms-frontend',
};
CFG.peopleDn = process.env.LDAP_PEOPLE_DN || `ou=personas,${CFG.baseDn}`;
CFG.groupsDn = process.env.LDAP_GROUPS_DN || `ou=grupos,${CFG.baseDn}`;
if (!CFG.bindDn || !CFG.bindPw) {
  console.error('Falta LDAP_BIND_DN / LDAP_BIND_PASSWORD en .env (cuenta cn=lector).');
  process.exit(1);
}

const ROLE_GROUPS = [
  // Solo 'administracion': admins-red es para equipos de red (y contiene cuentas de servicio como oxidized).
  { role: 'admin', groups: ['administracion'] },
  { role: 'secretary', groups: ['secretaria'] },
  { role: 'teacher', groups: ['docentes'] },
  { role: 'student', groups: ['estudiantes'] },
];
// Secretaria puede matricular / retirar estudiantes (SECRETARIA_MATRICULA=0 lo deja solo en consulta).
const SECRETARIA_MATRICULA = process.env.SECRETARIA_MATRICULA !== '0';
const ROLES_MATRICULA = SECRETARIA_MATRICULA ? ['admin', 'secretary'] : ['admin'];
const ROLE_BY_GID = { '12001': 'teacher', '12000': 'student' };
const SUSPENDED = '[SUSPENDIDA-SECRETARIA]';
const SESSION_IDLE_MS = 30 * 60 * 1000;
const SESSION_MAX_MS = 8 * 60 * 60 * 1000;
const MAX_FAILS = 5, FAIL_WINDOW_MS = 15 * 60 * 1000;
const COOKIE = 'edunova_sid';
const TIPOS = ['tarea', 'leccion', 'proyecto', 'examen', 'final'];
// Ponderacion inicial de cada curso (el docente la cambia; siempre suma 100 %).
const PESOS_DEFECTO = { tarea: 20, leccion: 15, proyecto: 15, examen: 20, final: 30 };

const db = mysql.createPool({
  host: process.env.DB_HOST, user: process.env.DB_USER, password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME, waitForConnections: true, connectionLimit: 8, queueLimit: 0,
  dateStrings: true, charset: 'utf8mb4',
});

/* ======================= LDAP ======================= */
// LDAP_URL="ldap://127.0.0.1:389 ldap://100.93.52.67:389": la primera es la principal (escrituras).
CFG.ldapUrls = String(CFG.ldapUrl).split(/[\s,]+/).filter(Boolean);
const ldapCaido = new Map(); // url -> hasta cuando se considera caido (evita esperar en cada consulta)
function conectar(url) {
  return new Promise((ok, fail) => {
    const c = ldap.createClient({ url: [url], timeout: 5000, connectTimeout: 2500, reconnect: false });
    let listo = false;
    const fin = (err) => { if (listo) return; listo = true; if (err) { try { c.destroy(); } catch { /* */ } fail(err); } else ok(c); };
    c.on('error', e => fin(e));
    c.once('connect', () => fin());
    c.once('connectError', e => fin(e || new Error('connectError')));
    c.once('connectTimeout', () => fin(new Error('connectTimeout')));
  });
}
/** Cliente LDAP conectado: prueba la principal y, si no responde, la replica. */
async function newClient({ principal = false } = {}) {
  const urls = principal ? CFG.ldapUrls.slice(0, 1) : CFG.ldapUrls;
  const ahora = Date.now();
  const orden = [...urls.filter(u => !(ldapCaido.get(u) > ahora)), ...urls.filter(u => ldapCaido.get(u) > ahora)];
  let ultimo;
  for (const url of orden) {
    try {
      const c = await conectar(url);
      if (ldapCaido.has(url)) { ldapCaido.delete(url); log('LDAP', url, 'responde de nuevo'); }
      return c;
    } catch (e) {
      ultimo = e;
      if (!(ldapCaido.get(url) > ahora)) log('LDAP', url, 'no responde:', e.code || e.message, urls.length > 1 ? '(se usa el respaldo)' : '');
      ldapCaido.set(url, ahora + 30000);
    }
  }
  throw ultimo || new Error('LDAP no disponible');
}
const bind = (c, dn, pw) => new Promise((ok, fail) => c.bind(dn, pw, e => (e ? fail(e) : ok())));
function search(c, base, filter, attributes, sizeLimit = 2000) {
  return new Promise((ok, fail) => {
    c.search(base, { scope: 'sub', filter, attributes, sizeLimit }, (err, res) => {
      if (err) return fail(err);
      const out = [];
      res.on('searchEntry', e => {
        const o = { dn: e.pojo.objectName };
        for (const a of e.pojo.attributes) o[a.type.toLowerCase()] = a.values;
        out.push(o);
      });
      res.on('error', fail);
      res.on('end', () => ok(out));
    });
  });
}
function close(c) { try { c.unbind(); } catch { /* */ } c.destroy?.(); }
const eq = (attribute, value) => new ldap.EqualityFilter({ attribute, value });
const first = v => (Array.isArray(v) ? v[0] : v) || '';
const normDn = dn => String(dn).toLowerCase().replace(/\s*,\s*/g, ',').replace(/\s*=\s*/g, '=');

function roleFrom(groupNames, gid) {
  for (const r of ROLE_GROUPS) if (r.groups.some(n => groupNames.includes(n))) return r.role;
  return ROLE_BY_GID[gid] || null;
}

/** Directorio completo (personas + rol), en cache 60 s. Lo usa el administrador. */
let dirCache = { at: 0, data: null };
async function directory(force = false) {
  if (!force && dirCache.data && Date.now() - dirCache.at < 60000) return dirCache.data;
  const c = await newClient();
  try {
    await bind(c, CFG.bindDn, CFG.bindPw);
    const people = await search(c, CFG.peopleDn, eq('objectClass', 'inetOrgPerson'),
      ['uid', 'cn', 'mail', 'gidNumber', 'description']);
    const groups = await search(c, CFG.groupsDn, eq('objectClass', 'groupOfNames'), ['cn', 'member']);
    const memberOf = new Map();
    for (const g of groups) {
      const name = first(g.cn).toLowerCase();
      for (const m of g.member || []) {
        const k = normDn(m);
        if (!memberOf.has(k)) memberOf.set(k, []);
        memberOf.get(k).push(name);
      }
    }
    const byUid = new Map();
    for (const p of people) {
      const uid = first(p.uid);
      if (!uid) continue;
      byUid.set(uid, {
        uid, nombre: first(p.cn) || uid, email: first(p.mail),
        role: roleFrom(memberOf.get(normDn(p.dn)) || [], first(p.gidnumber)),
        suspendida: first(p.description).includes(SUSPENDED),
      });
    }
    dirCache = { at: Date.now(), data: byUid };
    return byUid;
  } finally { close(c); }
}
async function nameOf(uid) {
  if (!uid) return '';
  try { return (await directory()).get(uid)?.nombre || uid; } catch { return uid; }
}

/** login = usuario (acabezas) o correo completo (acabezas@mejoland.edu.ec): la misma clave del correo. */
async function authenticate(username, password) {
  const attr = username.includes('@') ? 'mail' : 'uid';
  const svc = await newClient();
  let user, groups = [];
  try {
    await bind(svc, CFG.bindDn, CFG.bindPw);
    const found = await search(svc, CFG.peopleDn,
      new ldap.AndFilter({ filters: [eq('objectClass', 'inetOrgPerson'), eq(attr, username)] }),
      ['uid', 'cn', 'mail', 'gidNumber', 'description'], 5);
    if (found.length !== 1) return null;
    user = found[0];
    const g = await search(svc, CFG.groupsDn,
      new ldap.AndFilter({ filters: [eq('objectClass', 'groupOfNames'), eq('member', user.dn)] }), ['cn'], 50);
    groups = g.map(x => first(x.cn).toLowerCase());
  } finally { close(svc); }
  const cli = await newClient();
  try { await bind(cli, user.dn, password); } catch { return null; } finally { close(cli); }
  if (first(user.description).includes(SUSPENDED)) return { suspended: true };
  const role = roleFrom(groups, first(user.gidnumber));
  if (!role) return { norole: true };
  return { uid: first(user.uid), nombre: first(user.cn) || first(user.uid), email: first(user.mail), role, grupos: groups };
}

/* ======================= Sesiones ======================= */
const sessions = new Map();
const fails = new Map();
function cookies(req) {
  const out = {};
  for (const part of (req.headers.cookie || '').split(';')) {
    const i = part.indexOf('=');
    if (i > 0) out[part.slice(0, i).trim()] = decodeURIComponent(part.slice(i + 1).trim());
  }
  return out;
}
function viaLoopback(req) {
  const a = req.socket.remoteAddress || '';
  return a === '127.0.0.1' || a === '::1' || a === '::ffff:127.0.0.1';
}
function setCookie(req, res, value, maxAgeSec) {
  const p = [`${COOKIE}=${value}`, 'Path=/', 'HttpOnly', 'SameSite=Strict', `Max-Age=${maxAgeSec}`];
  if (viaLoopback(req) || (viaProxyDmz(req) && req.get('x-forwarded-proto') === 'https')) p.push('Secure');
  res.setHeader('Set-Cookie', p.join('; '));
}
function currentSession(req) {
  const id = cookies(req)[COOKIE];
  if (!id) return null;
  const s = sessions.get(id), now = Date.now();
  if (!s || now - s.seen > SESSION_IDLE_MS || now - s.created > SESSION_MAX_MS) { sessions.delete(id); return null; }
  s.seen = now;
  return { id, ...s };
}
setInterval(() => {
  const now = Date.now();
  for (const [id, s] of sessions) if (now - s.seen > SESSION_IDLE_MS || now - s.created > SESSION_MAX_MS) sessions.delete(id);
  for (const [k, f] of fails) if (now - f.first > FAIL_WINDOW_MS) fails.delete(k);
}, 60000).unref();

const log = (...a) => console.log(new Date().toISOString(), ...a);
class HttpError extends Error { constructor(status, msg) { super(msg); this.status = status; } }
const bad = msg => new HttpError(400, msg);
const forbidden = () => new HttpError(403, 'No tienes permiso para esta acción.');
const notFound = () => new HttpError(404, 'No encontrado.');

async function audit(uid, accion, detalle = '') {
  log(accion, uid, detalle);
  try { await db.query('INSERT INTO lms_auditoria (uid, accion, detalle) VALUES (?,?,?)', [uid, accion, String(detalle).slice(0, 500)]); }
  catch (e) { log('ERROR_AUDITORIA', e.message); }
}

/* ======================= Validacion ======================= */
function text(v, field, max, { required = true, min = 1 } = {}) {
  const s = String(v ?? '').trim();
  if (!s && !required) return '';
  if (s.length < min || s.length > max) throw bad(`${field}: entre ${min} y ${max} caracteres.`);
  return s;
}
function int(v, field, min, max) {
  const n = Number(v);
  if (!Number.isInteger(n) || n < min || n > max) throw bad(`${field}: número entero entre ${min} y ${max}.`);
  return n;
}
function decimal(v, field, min, max) {
  const n = Number(v);
  if (!Number.isFinite(n) || n < min || n > max) throw bad(`${field}: valor entre ${min} y ${max}.`);
  return Math.round(n * 100) / 100;
}
function datetime(v, field) {
  const s = String(v ?? '').trim();
  const m = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})/.exec(s);
  if (!m) throw bad(`${field}: fecha y hora no válidas.`);
  return `${m[1]}-${m[2]}-${m[3]} ${m[4]}:${m[5]}:00`;
}
const idParam = v => int(v, 'id', 1, 4294967295);
const uidOk = u => typeof u === 'string' && /^[a-z0-9._-]{1,64}$/.test(u);

/* ======================= Permisos sobre cursos ======================= */
async function loadCourse(id) {
  const [[c]] = await db.query('SELECT * FROM lms_cursos WHERE id=?', [id]);
  if (!c) throw notFound();
  return c;
}
async function isEnrolled(cursoId, uid) {
  const [[r]] = await db.query('SELECT 1 AS ok FROM lms_matriculas WHERE curso_id=? AND estudiante_uid=?', [cursoId, uid]);
  return !!r;
}
/** Devuelve el curso y el tipo de acceso: 'admin' | 'teacher' | 'student'. */
async function courseAccess(user, cursoId) {
  const c = await loadCourse(cursoId);
  if (user.role === 'admin') return { c, as: 'admin' };
  if (user.role === 'secretary') return { c, as: 'secretary' }; // solo datos del curso y estudiantes
  if (!c.activo) throw notFound();
  if (user.role === 'teacher' && c.docente_uid === user.uid) return { c, as: 'teacher' };
  if (user.role === 'student' && await isEnrolled(c.id, user.uid)) return { c, as: 'student' };
  throw notFound(); // no revelar cursos ajenos
}
/** Ver contenido de docente (entregas, libreta): docente del curso o admin (solo lectura). */
async function teachAccess(user, cursoId) {
  const a = await courseAccess(user, cursoId);
  if (a.as === 'student' || a.as === 'secretary') throw forbidden();
  return a;
}
/** Crear o modificar contenido academico: SOLO el docente asignado al curso. */
async function ownTeacher(user, cursoId) {
  const a = await courseAccess(user, cursoId);
  if (a.as !== 'teacher') throw new HttpError(403, 'Solo el docente asignado al curso puede hacer esto.');
  return a;
}
async function activityAccess(user, actId) {
  const [[a]] = await db.query('SELECT * FROM lms_actividades WHERE id=?', [actId]);
  if (!a) throw notFound();
  const acc = await courseAccess(user, a.curso_id);
  return { a, ...acc };
}

/* ======================= Ponderacion ======================= */
async function pesosCurso(cursoId) {
  const [rows] = await db.query('SELECT tipo, peso FROM lms_ponderaciones WHERE curso_id=?', [cursoId]);
  if (!rows.length) return { pesos: { ...PESOS_DEFECTO }, porDefecto: true };
  const pesos = Object.fromEntries(TIPOS.map(t => [t, 0]));
  for (const r of rows) if (TIPOS.includes(r.tipo)) pesos[r.tipo] = Number(r.peso);
  return { pesos, porDefecto: false };
}
const r2 = n => Math.round(n * 100) / 100;
/**
 * items: [{ tipo, nota|null, puntaje_max }]
 * Cada tipo se promedia sobre 10 (suma de notas / suma de puntajes) y se multiplica por su peso.
 *  - final:     promedio ponderado con lo YA evaluado (se reajusta a los pesos con notas).
 *  - acumulado: puntos ganados de 10 posibles en todo el periodo.
 *  - evaluado:  % del periodo que ya tiene notas.
 */
function calcular(items, pesos) {
  const acc = Object.fromEntries(TIPOS.map(t => [t, { s: 0, t: 0, n: 0 }]));
  for (const i of items) {
    if (!acc[i.tipo]) continue;
    acc[i.tipo].n++;
    if (i.nota !== null && i.nota !== undefined) { acc[i.tipo].s += Number(i.nota); acc[i.tipo].t += Number(i.puntaje_max); }
  }
  let suma = 0, evaluado = 0;
  const categorias = TIPOS.map(t => {
    const peso = Number(pesos[t] || 0);
    const promedio = acc[t].t ? r2((acc[t].s / acc[t].t) * 10) : null;
    const aporte = promedio !== null && peso ? r2(promedio * peso / 100) : null;
    if (aporte !== null) { suma += promedio * peso; evaluado += peso; }
    return { tipo: t, peso, actividades: acc[t].n, promedio, aporte };
  });
  return { categorias, final: evaluado ? r2(suma / evaluado) : null, acumulado: r2(suma / 100), evaluado: r2(evaluado) };
}

/* ======================= Contrasenas ======================= */
function ssha(password) {
  const salt = crypto.randomBytes(16);
  const h = crypto.createHash('sha1').update(Buffer.concat([Buffer.from(password, 'utf8'), salt])).digest();
  return '{SSHA}' + Buffer.concat([h, salt]).toString('base64');
}
function politicaClave(nueva, uid) {
  if (nueva.length < 10 || nueva.length > 72) return 'La nueva contraseña debe tener entre 10 y 72 caracteres.';
  if (!/[a-z]/.test(nueva) || !/[A-Z]/.test(nueva) || !/[0-9]/.test(nueva)) return 'Usa al menos una minúscula, una mayúscula y un número.';
  if (nueva.toLowerCase().includes(uid.toLowerCase())) return 'La contraseña no puede contener tu usuario.';
  if (/^(.)\1+$/.test(nueva) || /(0123|1234|2345|3456|4567|5678|6789|abcd|qwer)/i.test(nueva)) return 'Contraseña demasiado predecible.';
  return null;
}
const modify = (c, dn, change) => new Promise((ok, fail) => c.modify(dn, change, e => (e ? fail(e) : ok())));

/* ======================= Aplicacion ======================= */
const app = express();
app.disable('x-powered-by');
app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'no-referrer');
  next();
});
app.use(express.json({ limit: '64kb' }));

const api = express.Router();
api.use((req, res, next) => {
  res.setHeader('Cache-Control', 'no-store');
  // Toda escritura debe ser JSON: junto con SameSite=Strict bloquea formularios de otros sitios.
  // Excepcion: el archivo a imprimir llega como binario (PDF/JPG/PNG). Esos tipos tampoco
  // los puede enviar un formulario de otro sitio, asi que la proteccion CSRF se mantiene.
  const subida = req.method === 'POST' && ((req.path === '/imprimir' && req.is(TIPOS_IMPRESION))
    || (req.path === '/biblioteca' && req.is(Object.keys(TIPOS_BIBLIO))));
  if (['POST', 'PUT', 'PATCH'].includes(req.method) && !subida && !req.is('application/json')) {
    return res.status(415).json({ error: 'Formato no válido.' });
  }
  next();
});
const TIPOS_IMPRESION = ['application/pdf', 'image/jpeg', 'image/png'];
/* Tipos de archivo de la biblioteca (nunca HTML/SVG/JS: se descargan, no se ejecutan en el navegador). */
const TIPOS_BIBLIO = {
  'application/pdf': 'pdf', 'image/jpeg': 'jpg', 'image/png': 'png',
  'application/msword': 'doc', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document': 'docx',
  'application/vnd.ms-excel': 'xls', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'xlsx',
  'application/vnd.ms-powerpoint': 'ppt', 'application/vnd.openxmlformats-officedocument.presentationml.presentation': 'pptx',
  'application/vnd.oasis.opendocument.text': 'odt', 'application/vnd.oasis.opendocument.spreadsheet': 'ods',
  'application/vnd.oasis.opendocument.presentation': 'odp', 'application/zip': 'zip',
};
const wrap = fn => (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);
function auth(...roles) {
  return (req, res, next) => {
    const s = currentSession(req);
    if (!s) return res.status(401).json({ error: 'Sesión no iniciada o expirada.' });
    if (roles.length && !roles.includes(s.user.role)) return res.status(403).json({ error: 'No tienes permiso para esta acción.' });
    req.user = s.user;
    next();
  };
}

/* ---------- Sesion ---------- */
api.post('/login', wrap(async (req, res) => {
  const username = String(req.body?.username ?? '').trim().toLowerCase();
  const password = String(req.body?.password ?? '');
  const loginOk = uidOk(username) || /^[a-z0-9._-]{1,64}@[a-z0-9.-]{1,100}$/.test(username);
  if (!loginOk || !password || password.length > 256) {
    return res.status(400).json({ error: 'Usuario o contraseña incorrectos.' });
  }
  const f = fails.get(username);
  if (f && f.count >= MAX_FAILS && Date.now() - f.first < FAIL_WINDOW_MS) {
    log('LOGIN_BLOQUEADO', username);
    return res.status(429).json({ error: 'Demasiados intentos fallidos. Espera 15 minutos.' });
  }
  let r;
  try { r = await authenticate(username, password); }
  catch (e) { log('ERROR_LDAP', e.message); return res.status(503).json({ error: 'El directorio no está disponible. Intenta más tarde.' }); }
  if (!r || r.suspended || r.norole) {
    const g = fails.get(username) || { count: 0, first: Date.now() };
    if (Date.now() - g.first >= FAIL_WINDOW_MS) { g.count = 0; g.first = Date.now(); }
    g.count++; fails.set(username, g);
    log('LOGIN_DENEGADO', username, r?.suspended ? '(suspendida)' : r?.norole ? '(sin grupo)' : '');
    if (r?.suspended) return res.status(403).json({ error: 'Cuenta suspendida. Acude a secretaría.' });
    if (r?.norole) return res.status(403).json({ error: 'Tu cuenta no tiene acceso a la plataforma.' });
    return res.status(401).json({ error: 'Usuario o contraseña incorrectos.' });
  }
  fails.delete(username);
  const old = cookies(req)[COOKIE];
  if (old) sessions.delete(old);
  const id = crypto.randomBytes(32).toString('hex');
  sessions.set(id, { user: r, created: Date.now(), seen: Date.now() });
  setCookie(req, res, id, SESSION_MAX_MS / 1000);
  await audit(r.uid, 'LOGIN', { admin: 'como administración', secretary: 'como secretaría', teacher: 'como docente', student: 'como estudiante' }[r.role]);
  res.json({ user: r });
}));
api.post('/logout', wrap(async (req, res) => {
  const s = currentSession(req);
  if (s) { sessions.delete(s.id); await audit(s.user.uid, 'LOGOUT'); }
  setCookie(req, res, '', 0);
  res.json({ ok: true });
}));
api.get('/me', auth(), (req, res) => res.json({ user: req.user }));

/* ---------- Resumen del panel principal ---------- */
api.get('/resumen', auth(), wrap(async (req, res) => {
  const u = req.user;
  if (u.role === 'admin' || u.role === 'secretary') {
    const [[c]] = await db.query('SELECT COUNT(*) n, SUM(docente_uid IS NULL) sin_docente FROM lms_cursos WHERE activo=1');
    const [[m]] = await db.query('SELECT COUNT(*) n FROM lms_matriculas m JOIN lms_cursos c ON c.id=m.curso_id AND c.activo=1');
    let docentes = 0, estudiantes = 0;
    try { for (const p of (await directory()).values()) { if (p.suspendida) continue; if (p.role === 'teacher') docentes++; if (p.role === 'student') estudiantes++; } } catch { /* LDAP caido */ }
    const [ult] = u.role === 'admin'
      ? await db.query('SELECT cuando, uid, accion, detalle FROM lms_auditoria WHERE accion NOT IN ("LOGIN","LOGOUT") ORDER BY id DESC LIMIT 8')
      : await db.query('SELECT cuando, uid, accion, detalle FROM lms_auditoria WHERE accion IN ("MATRICULA","MATRICULA_RETIRADA") ORDER BY id DESC LIMIT 8');
    return res.json({ cursos: Number(c.n), sinDocente: Number(c.sin_docente || 0), matriculas: Number(m.n), docentes, estudiantes, movimientos: ult });
  }
  if (u.role === 'teacher') {
    const [[c]] = await db.query('SELECT COUNT(*) n FROM lms_cursos WHERE activo=1 AND docente_uid=?', [u.uid]);
    const [[e]] = await db.query(`SELECT COUNT(DISTINCT m.estudiante_uid) n FROM lms_matriculas m
      JOIN lms_cursos c ON c.id=m.curso_id WHERE c.activo=1 AND c.docente_uid=?`, [u.uid]);
    const [pend] = await db.query(`SELECT a.id, a.titulo, c.nombre curso, c.id curso_id, COUNT(*) pendientes
      FROM lms_entregas en JOIN lms_actividades a ON a.id=en.actividad_id JOIN lms_cursos c ON c.id=a.curso_id
      WHERE c.activo=1 AND c.docente_uid=? AND en.entregado_en IS NOT NULL AND en.nota IS NULL
      GROUP BY a.id ORDER BY a.fecha_limite LIMIT 8`, [u.uid]);
    return res.json({ cursos: Number(c.n), estudiantes: Number(e.n), porCalificar: pend.reduce((s, x) => s + Number(x.pendientes), 0), pendientes: pend });
  }
  const [[c]] = await db.query(`SELECT COUNT(*) n FROM lms_matriculas m JOIN lms_cursos c ON c.id=m.curso_id
    WHERE c.activo=1 AND m.estudiante_uid=?`, [u.uid]);
  const [prox] = await db.query(`SELECT a.id, a.titulo, a.tipo, a.fecha_limite, c.nombre curso, c.id curso_id
    FROM lms_actividades a JOIN lms_cursos c ON c.id=a.curso_id AND c.activo=1
    JOIN lms_matriculas m ON m.curso_id=c.id AND m.estudiante_uid=?
    LEFT JOIN lms_entregas e ON e.actividad_id=a.id AND e.estudiante_uid=m.estudiante_uid
    WHERE a.fecha_limite >= NOW() AND e.entregado_en IS NULL AND e.nota IS NULL ORDER BY a.fecha_limite LIMIT 8`, [u.uid]);
  const finales = (await notasEstudiante(u.uid)).map(k => k.final).filter(f => f !== null);
  res.json({ cursos: Number(c.n), pendientes: prox, promedio: finales.length ? r2(finales.reduce((a, b) => a + b, 0) / finales.length) : null });
}));

/* ---------- Cursos ---------- */
api.get('/cursos', auth(), wrap(async (req, res) => {
  const u = req.user;
  const base = `SELECT c.*, (SELECT COUNT(*) FROM lms_matriculas m WHERE m.curso_id=c.id) inscritos,
    (SELECT COUNT(*) FROM lms_actividades a WHERE a.curso_id=c.id) actividades FROM lms_cursos c`;
  const order = ` ORDER BY c.activo DESC,
    CASE WHEN c.nivel LIKE '%8vo%' THEN 1 WHEN c.nivel LIKE '%9no%' THEN 2 WHEN c.nivel LIKE '%10mo%' THEN 3
         WHEN c.nivel LIKE '%1ro%' THEN 4 WHEN c.nivel LIKE '%2do%' THEN 5 WHEN c.nivel LIKE '%3ro%' THEN 6 ELSE 7 END,
    c.nivel, c.paralelo, c.nombre`;
  let rows;
  if (u.role === 'admin' || u.role === 'secretary') [rows] = await db.query(base + order);
  else if (u.role === 'teacher') [rows] = await db.query(base + ' WHERE c.activo=1 AND c.docente_uid=?' + order, [u.uid]);
  else [rows] = await db.query(base + ' JOIN lms_matriculas mm ON mm.curso_id=c.id AND mm.estudiante_uid=? WHERE c.activo=1' + order, [u.uid]);
  for (const r of rows) r.docente_nombre = r.docente_uid ? await nameOf(r.docente_uid) : '';
  res.json(rows);
}));

async function courseFields(body, dir) {
  const f = {
    codigo: text(body.codigo, 'Código', 30, { min: 2 }).toUpperCase(),
    nombre: text(body.nombre, 'Nombre', 120),
    asignatura: text(body.asignatura, 'Asignatura', 120),
    nivel: text(body.nivel, 'Nivel', 40),
    paralelo: text(body.paralelo, 'Paralelo', 10, { required: false }).toUpperCase(),
    periodo: text(body.periodo, 'Periodo', 20),
    capacidad: int(body.capacidad, 'Cupo', 1, 200),
    docente_uid: body.docente_uid ? String(body.docente_uid) : null,
  };
  if (!/^[A-Z0-9-]{2,30}$/.test(f.codigo)) throw bad('Código: solo letras, números y guiones (ej. MAT-8A).');
  if (f.docente_uid) {
    const d = dir.get(f.docente_uid);
    if (!d || d.role !== 'teacher' || d.suspendida) throw bad('El docente elegido no es un docente activo del directorio.');
  }
  return f;
}
api.post('/cursos', auth('admin'), wrap(async (req, res) => {
  const f = await courseFields(req.body || {}, await directory(true));
  try {
    const [r] = await db.query(`INSERT INTO lms_cursos (codigo,nombre,asignatura,nivel,paralelo,periodo,capacidad,docente_uid)
      VALUES (?,?,?,?,?,?,?,?)`, [f.codigo, f.nombre, f.asignatura, f.nivel, f.paralelo, f.periodo, f.capacidad, f.docente_uid]);
    await audit(req.user.uid, 'CURSO_CREADO', `${f.codigo} «${f.nombre}» · docente asignado: ${f.docente_uid ? `${await nameOf(f.docente_uid)} (${f.docente_uid})` : 'ninguno'}`);
    res.status(201).json({ id: r.insertId });
  } catch (e) {
    if (e.code === 'ER_DUP_ENTRY') throw bad('Ya existe un curso con ese código.');
    throw e;
  }
}));
api.put('/cursos/:id', auth('admin'), wrap(async (req, res) => {
  const c = await loadCourse(idParam(req.params.id));
  const f = await courseFields(req.body || {}, await directory(true));
  const [[n]] = await db.query('SELECT COUNT(*) n FROM lms_matriculas WHERE curso_id=?', [c.id]);
  if (f.capacidad < Number(n.n)) throw bad(`El cupo no puede ser menor que los ${n.n} estudiantes matriculados.`);
  try {
    await db.query(`UPDATE lms_cursos SET codigo=?,nombre=?,asignatura=?,nivel=?,paralelo=?,periodo=?,capacidad=?,docente_uid=? WHERE id=?`,
      [f.codigo, f.nombre, f.asignatura, f.nivel, f.paralelo, f.periodo, f.capacidad, f.docente_uid, c.id]);
  } catch (e) { if (e.code === 'ER_DUP_ENTRY') throw bad('Ya existe un curso con ese código.'); throw e; }
  await audit(req.user.uid, 'CURSO_EDITADO', `${f.codigo} «${f.nombre}» · docente asignado: ${f.docente_uid ? `${await nameOf(f.docente_uid)} (${f.docente_uid})` : 'ninguno'}`);
  res.json({ ok: true });
}));
api.post('/cursos/:id/estado', auth('admin'), wrap(async (req, res) => {
  const c = await loadCourse(idParam(req.params.id));
  const activo = req.body?.activo === true ? 1 : 0;
  await db.query('UPDATE lms_cursos SET activo=? WHERE id=?', [activo, c.id]);
  await audit(req.user.uid, activo ? 'CURSO_REACTIVADO' : 'CURSO_ARCHIVADO', c.codigo);
  res.json({ ok: true });
}));

/** Detalle del curso segun el rol. */
api.get('/cursos/:id', auth(), wrap(async (req, res) => {
  const { c, as } = await courseAccess(req.user, idParam(req.params.id));
  c.docente_nombre = await nameOf(c.docente_uid);
  const [anuncios] = await db.query('SELECT id, autor_uid, titulo, cuerpo, creado_en FROM lms_anuncios WHERE curso_id=? ORDER BY id DESC LIMIT 50', [c.id]);
  for (const a of anuncios) a.autor = await nameOf(a.autor_uid);
  const out = { curso: c, acceso: as, anuncios, ...(await pesosCurso(c.id)) };
  if (as === 'secretary') { out.anuncios = []; out.puedeMatricular = SECRETARIA_MATRICULA; }
  if (as === 'student') {
    const [acts] = await db.query(`SELECT a.id, a.titulo, a.descripcion, a.tipo, a.fecha_limite, a.puntaje_max,
        a.fecha_limite < NOW() vencida, e.contenido, e.entregado_en, e.nota, e.comentario
      FROM lms_actividades a LEFT JOIN lms_entregas e ON e.actividad_id=a.id AND e.estudiante_uid=?
      WHERE a.curso_id=? ORDER BY a.fecha_limite`, [req.user.uid, c.id]);
    out.actividades = acts;
  } else {
    if (as === 'secretary') out.actividades = []; // Secretaria no ve contenido academico
    else {
    const [acts] = await db.query(`SELECT a.id, a.titulo, a.descripcion, a.tipo, a.fecha_limite, a.puntaje_max,
        a.fecha_limite < NOW() vencida,
        (SELECT COUNT(*) FROM lms_entregas e WHERE e.actividad_id=a.id AND e.entregado_en IS NOT NULL) entregas,
        (SELECT COUNT(*) FROM lms_entregas e WHERE e.actividad_id=a.id AND e.nota IS NOT NULL) calificadas
      FROM lms_actividades a WHERE a.curso_id=? ORDER BY a.fecha_limite`, [c.id]);
    out.actividades = acts;
    }
    const [est] = await db.query('SELECT estudiante_uid uid, creado_en FROM lms_matriculas WHERE curso_id=? ORDER BY estudiante_uid', [c.id]);
    let dir = new Map();
    try { dir = await directory(); } catch { /* */ }
    out.estudiantes = est.map(e => ({ uid: e.uid, nombre: dir.get(e.uid)?.nombre || e.uid, email: dir.get(e.uid)?.email || '', suspendida: !!dir.get(e.uid)?.suspendida }))
      .sort((a, b) => a.nombre.localeCompare(b.nombre, 'es'));
  }
  res.json(out);
}));

/* ---------- Matricula (solo admin) ---------- */
api.get('/usuarios', auth('admin', 'secretary'), wrap(async (req, res) => {
  const rol = String(req.query.rol || '');
  const list = [...(await directory(req.query.refrescar === '1')).values()]
    .filter(p => !rol || p.role === rol).sort((a, b) => a.nombre.localeCompare(b.nombre, 'es'));
  res.json(list);
}));
api.post('/cursos/:id/matriculas', auth(...ROLES_MATRICULA), wrap(async (req, res) => {
  const c = await loadCourse(idParam(req.params.id));
  if (!c.activo) throw bad('El curso está archivado.');
  const uids = Array.isArray(req.body?.uids) ? [...new Set(req.body.uids)] : [];
  if (!uids.length || uids.length > 100 || !uids.every(uidOk)) throw bad('Selecciona entre 1 y 100 estudiantes.');
  const dir = await directory(true);
  const malos = uids.filter(u => dir.get(u)?.role !== 'student' || dir.get(u)?.suspendida);
  if (malos.length) throw bad(`No son estudiantes activos: ${malos.join(', ')}`);
  const conn = await db.getConnection();
  try {
    await conn.beginTransaction();
    const [[cc]] = await conn.query('SELECT capacidad FROM lms_cursos WHERE id=? FOR UPDATE', [c.id]);
    const [ya] = await conn.query('SELECT estudiante_uid FROM lms_matriculas WHERE curso_id=?', [c.id]);
    const set = new Set(ya.map(r => r.estudiante_uid));
    const nuevos = uids.filter(u => !set.has(u));
    if (set.size + nuevos.length > cc.capacidad) throw bad(`Cupo insuficiente: quedan ${cc.capacidad - set.size} lugares.`);
    for (const u of nuevos) await conn.query('INSERT INTO lms_matriculas (curso_id, estudiante_uid) VALUES (?,?)', [c.id, u]);
    await conn.commit();
    await audit(req.user.uid, 'MATRICULA', `${c.codigo} · estudiantes: ${nuevos.join(', ') || '(ya estaban)'}`);
    res.json({ agregados: nuevos.length });
  } catch (e) { await conn.rollback(); throw e; } finally { conn.release(); }
}));
api.delete('/cursos/:id/matriculas/:uid', auth(...ROLES_MATRICULA), wrap(async (req, res) => {
  const c = await loadCourse(idParam(req.params.id));
  const uid = String(req.params.uid);
  if (!uidOk(uid)) throw bad('Usuario no válido.');
  const [r] = await db.query('DELETE FROM lms_matriculas WHERE curso_id=? AND estudiante_uid=?', [c.id, uid]);
  if (!r.affectedRows) throw notFound();
  // Las entregas y notas se conservan como historial (no se borran).
  await audit(req.user.uid, 'MATRICULA_RETIRADA', `${c.codigo}: ${uid}`);
  res.json({ ok: true });
}));

/* ---------- Anuncios (docente del curso o admin) ---------- */
api.post('/cursos/:id/anuncios', auth('teacher'), wrap(async (req, res) => {
  const { c } = await ownTeacher(req.user, idParam(req.params.id));
  const titulo = text(req.body?.titulo, 'Título', 150);
  const cuerpo = text(req.body?.cuerpo, 'Mensaje', 4000);
  await db.query('INSERT INTO lms_anuncios (curso_id, autor_uid, titulo, cuerpo) VALUES (?,?,?,?)', [c.id, req.user.uid, titulo, cuerpo]);
  await audit(req.user.uid, 'ANUNCIO', `${c.codigo}: ${titulo}`);
  res.status(201).json({ ok: true });
}));
api.delete('/anuncios/:id', auth('teacher'), wrap(async (req, res) => {
  const [[a]] = await db.query('SELECT * FROM lms_anuncios WHERE id=?', [idParam(req.params.id)]);
  if (!a) throw notFound();
  const { c } = await ownTeacher(req.user, a.curso_id);
  await db.query('DELETE FROM lms_anuncios WHERE id=?', [a.id]);
  await audit(req.user.uid, 'ANUNCIO_BORRADO', `${c.codigo}: ${a.titulo}`);
  res.json({ ok: true });
}));

/* ---------- Actividades ---------- */
function activityFields(body) {
  const tipo = String(body.tipo || 'tarea');
  if (!TIPOS.includes(tipo)) throw bad('Tipo de actividad no válido.');
  return {
    titulo: text(body.titulo, 'Título', 150),
    descripcion: text(body.descripcion, 'Instrucciones', 5000),
    tipo,
    fecha_limite: datetime(body.fecha_limite, 'Fecha límite'),
    puntaje_max: decimal(body.puntaje_max, 'Puntaje', 1, 100),
  };
}
api.post('/cursos/:id/actividades', auth('teacher'), wrap(async (req, res) => {
  const { c } = await ownTeacher(req.user, idParam(req.params.id));
  const f = activityFields(req.body || {});
  const [r] = await db.query(`INSERT INTO lms_actividades (curso_id,titulo,descripcion,tipo,fecha_limite,puntaje_max,creado_por)
    VALUES (?,?,?,?,?,?,?)`, [c.id, f.titulo, f.descripcion, f.tipo, f.fecha_limite, f.puntaje_max, req.user.uid]);
  await audit(req.user.uid, 'ACTIVIDAD_CREADA', `${c.codigo}: ${f.titulo}`);
  res.status(201).json({ id: r.insertId });
}));
api.put('/actividades/:id', auth('teacher'), wrap(async (req, res) => {
  const { a, as, c } = await activityAccess(req.user, idParam(req.params.id));
  if (as !== 'teacher') throw forbidden();
  const f = activityFields(req.body || {});
  const [[mx]] = await db.query('SELECT MAX(nota) m FROM lms_entregas WHERE actividad_id=?', [a.id]);
  if (mx.m !== null && Number(mx.m) > f.puntaje_max) throw bad('Hay notas mayores que el nuevo puntaje máximo.');
  await db.query('UPDATE lms_actividades SET titulo=?,descripcion=?,tipo=?,fecha_limite=?,puntaje_max=? WHERE id=?',
    [f.titulo, f.descripcion, f.tipo, f.fecha_limite, f.puntaje_max, a.id]);
  await audit(req.user.uid, 'ACTIVIDAD_EDITADA', `${c.codigo}: ${f.titulo}`);
  res.json({ ok: true });
}));
api.delete('/actividades/:id', auth('teacher'), wrap(async (req, res) => {
  const { a, as, c } = await activityAccess(req.user, idParam(req.params.id));
  if (as !== 'teacher') throw forbidden();
  const [[n]] = await db.query('SELECT COUNT(*) n FROM lms_entregas WHERE actividad_id=? AND (entregado_en IS NOT NULL OR nota IS NOT NULL)', [a.id]);
  // Las notas son registro academico: una actividad con entregas o notas no se borra.
  if (Number(n.n) > 0) throw bad('Ya tiene entregas o notas registradas: no se puede borrar (puedes editarla).');
  await db.query('DELETE FROM lms_actividades WHERE id=?', [a.id]);
  await audit(req.user.uid, 'ACTIVIDAD_BORRADA', `${c.codigo}: ${a.titulo} (${n.n} entregas)`);
  res.json({ ok: true });
}));

/** Entrega del estudiante (texto o enlace). Se puede corregir hasta la fecha limite y si aun no tiene nota. */
api.post('/actividades/:id/entrega', auth('student'), wrap(async (req, res) => {
  const { a, as } = await activityAccess(req.user, idParam(req.params.id));
  if (as !== 'student') throw forbidden();
  const contenido = text(req.body?.contenido, 'Entrega', 8000);
  const [[v]] = await db.query('SELECT fecha_limite < NOW() vencida FROM lms_actividades WHERE id=?', [a.id]);
  if (Number(v.vencida)) throw bad('La fecha límite ya pasó.');
  const [[e]] = await db.query('SELECT nota FROM lms_entregas WHERE actividad_id=? AND estudiante_uid=?', [a.id, req.user.uid]);
  if (e && e.nota !== null) throw bad('Esta actividad ya fue calificada.');
  await db.query(`INSERT INTO lms_entregas (actividad_id, estudiante_uid, contenido, entregado_en) VALUES (?,?,?,NOW())
    ON DUPLICATE KEY UPDATE contenido=VALUES(contenido), entregado_en=NOW()`, [a.id, req.user.uid, contenido]);
  await audit(req.user.uid, 'ENTREGA', `actividad ${a.id}`);
  res.json({ ok: true });
}));

/** Lista de estudiantes con su entrega y nota (docente/admin). */
api.get('/actividades/:id/entregas', auth('admin', 'teacher'), wrap(async (req, res) => {
  const { a, as } = await activityAccess(req.user, idParam(req.params.id));
  if (as === 'student') throw forbidden();
  const [rows] = await db.query(`SELECT m.estudiante_uid uid, e.contenido, e.entregado_en, e.nota, e.comentario,
      e.entregado_en > a.fecha_limite tardia
    FROM lms_matriculas m JOIN lms_actividades a ON a.id=?
    LEFT JOIN lms_entregas e ON e.actividad_id=a.id AND e.estudiante_uid=m.estudiante_uid
    WHERE m.curso_id=a.curso_id`, [a.id]);
  for (const r of rows) r.nombre = await nameOf(r.uid);
  rows.sort((x, y) => x.nombre.localeCompare(y.nombre, 'es'));
  res.json({ actividad: a, entregas: rows });
}));
api.put('/actividades/:id/notas/:uid', auth('teacher'), wrap(async (req, res) => {
  const { a, as, c } = await activityAccess(req.user, idParam(req.params.id));
  if (as !== 'teacher') throw forbidden();
  const uid = String(req.params.uid);
  if (!uidOk(uid) || !(await isEnrolled(a.curso_id, uid))) throw bad('El estudiante no está matriculado en este curso.');
  const vacia = req.body?.nota === null || req.body?.nota === '';
  const nota = vacia ? null : decimal(req.body?.nota, 'Nota', 0, Number(a.puntaje_max));
  const comentario = text(req.body?.comentario, 'Comentario', 500, { required: false }) || null;
  await db.query(`INSERT INTO lms_entregas (actividad_id, estudiante_uid, nota, comentario, calificado_por, calificado_en)
    VALUES (?,?,?,?,?,NOW()) ON DUPLICATE KEY UPDATE nota=VALUES(nota), comentario=VALUES(comentario),
    calificado_por=VALUES(calificado_por), calificado_en=NOW()`, [a.id, uid, nota, comentario, req.user.uid]);
  await audit(req.user.uid, 'NOTA', `${c.codigo} act ${a.id} ${uid}=${nota ?? 'sin nota'}`);
  res.json({ ok: true });
}));

/** Libreta de calificaciones del curso (docente/admin). */
api.get('/cursos/:id/calificaciones', auth('admin', 'teacher'), wrap(async (req, res) => {
  const { c } = await teachAccess(req.user, idParam(req.params.id));
  const [acts] = await db.query('SELECT id, titulo, tipo, puntaje_max FROM lms_actividades WHERE curso_id=? ORDER BY fecha_limite', [c.id]);
  const [est] = await db.query('SELECT estudiante_uid uid FROM lms_matriculas WHERE curso_id=?', [c.id]);
  const [notas] = await db.query(`SELECT e.actividad_id, e.estudiante_uid uid, e.nota FROM lms_entregas e
    JOIN lms_actividades a ON a.id=e.actividad_id WHERE a.curso_id=? AND e.nota IS NOT NULL`, [c.id]);
  const map = new Map(notas.map(n => [`${n.uid}|${n.actividad_id}`, Number(n.nota)]));
  const { pesos, porDefecto } = await pesosCurso(c.id);
  const filas = [];
  for (const e of est) {
    const celdas = acts.map(a => map.get(`${e.uid}|${a.id}`) ?? null);
    const calc = calcular(acts.map((a, i) => ({ tipo: a.tipo, puntaje_max: a.puntaje_max, nota: celdas[i] })), pesos);
    filas.push({ uid: e.uid, nombre: await nameOf(e.uid), notas: celdas, ...calc, promedio: calc.final });
  }
  filas.sort((x, y) => x.nombre.localeCompare(y.nombre, 'es'));
  res.json({ curso: c, actividades: acts, filas, pesos, porDefecto });
}));

/** Notas propias del estudiante en todos sus cursos, con la ponderacion de cada curso. */
async function notasEstudiante(uid) {
  const [rows] = await db.query(`SELECT c.id curso_id, c.nombre curso, c.codigo, a.id, a.titulo, a.tipo, a.puntaje_max,
      a.fecha_limite, e.nota, e.comentario, e.entregado_en
    FROM lms_matriculas m JOIN lms_cursos c ON c.id=m.curso_id AND c.activo=1
    JOIN lms_actividades a ON a.curso_id=c.id
    LEFT JOIN lms_entregas e ON e.actividad_id=a.id AND e.estudiante_uid=m.estudiante_uid
    WHERE m.estudiante_uid=? ORDER BY c.nombre, a.fecha_limite`, [uid]);
  const cursos = new Map();
  for (const r of rows) {
    if (!cursos.has(r.curso_id)) cursos.set(r.curso_id, { curso_id: r.curso_id, curso: r.curso, codigo: r.codigo, items: [] });
    cursos.get(r.curso_id).items.push({ titulo: r.titulo, tipo: r.tipo, puntaje_max: r.puntaje_max, nota: r.nota, comentario: r.comentario, entregado_en: r.entregado_en });
  }
  const out = [];
  for (const k of cursos.values()) {
    const { pesos } = await pesosCurso(k.curso_id);
    const calc = calcular(k.items, pesos);
    out.push({ ...k, ...calc, promedio: calc.final });
  }
  return out;
}
api.get('/mis-notas', auth('student'), wrap(async (req, res) => res.json(await notasEstudiante(req.user.uid))));

/** Ponderacion del curso: la ve cualquiera con acceso; solo el docente del curso la cambia. */
api.get('/cursos/:id/ponderacion', auth(), wrap(async (req, res) => {
  const { c } = await courseAccess(req.user, idParam(req.params.id));
  res.json(await pesosCurso(c.id));
}));
api.put('/cursos/:id/ponderacion', auth('teacher'), wrap(async (req, res) => {
  const { c } = await ownTeacher(req.user, idParam(req.params.id));
  const body = req.body?.pesos || {};
  const pesos = {};
  for (const t of TIPOS) pesos[t] = decimal(body[t] ?? 0, `Peso de ${t}`, 0, 100);
  const total = r2(Object.values(pesos).reduce((a, b) => a + b, 0));
  if (Math.abs(total - 100) > 0.01) throw bad(`Los porcentajes deben sumar 100 % (ahora suman ${total} %).`);
  const conn = await db.getConnection();
  try {
    await conn.beginTransaction();
    await conn.query('DELETE FROM lms_ponderaciones WHERE curso_id=?', [c.id]);
    for (const t of TIPOS) await conn.query('INSERT INTO lms_ponderaciones (curso_id, tipo, peso) VALUES (?,?,?)', [c.id, t, pesos[t]]);
    await conn.commit();
  } catch (e) { await conn.rollback(); throw e; } finally { conn.release(); }
  await audit(req.user.uid, 'PONDERACION', `${c.codigo}: ` + TIPOS.map(t => `${t} ${pesos[t]}%`).join(', '));
  res.json({ ok: true });
}));

/** Cambio de contrasena propia: es la clave LDAP (correo, Wi-Fi y esta plataforma). */
api.post('/cambiar-clave', auth(), wrap(async (req, res) => {
  const uid = req.user.uid;
  const actual = String(req.body?.actual ?? ''), nueva = String(req.body?.nueva ?? '');
  const key = 'clave:' + uid;
  const f = fails.get(key);
  if (f && f.count >= MAX_FAILS && Date.now() - f.first < FAIL_WINDOW_MS) throw new HttpError(429, 'Demasiados intentos. Espera 15 minutos.');
  const regla = politicaClave(nueva, uid);
  if (regla) throw bad(regla);
  if (nueva === actual) throw bad('La nueva contraseña debe ser distinta de la actual.');
  // DN del usuario (con la cuenta de lectura)
  const svc = await newClient();
  let dn;
  try {
    await bind(svc, CFG.bindDn, CFG.bindPw);
    const found = await search(svc, CFG.peopleDn, new ldap.AndFilter({ filters: [eq('objectClass', 'inetOrgPerson'), eq('uid', uid)] }), ['uid'], 2);
    if (found.length !== 1) throw notFound();
    dn = found[0].dn;
  } finally { close(svc); }
  // Se cambia CON LA PROPIA SESION LDAP del usuario (ACL "self write"): la plataforma no tiene permisos de escritura.
  const cli = await newClient({ principal: true }).catch(() => { throw new HttpError(503, 'El directorio principal no está disponible en este momento; intenta más tarde.'); });
  try {
    try { await bind(cli, dn, actual); } catch {
      const g = fails.get(key) || { count: 0, first: Date.now() }; g.count++; fails.set(key, g);
      await audit(uid, 'CLAVE_ACTUAL_ERRADA');
      throw bad('La contraseña actual no es correcta.');
    }
    try {
      await modify(cli, dn, new ldap.Change({ operation: 'replace', modification: new ldap.Attribute({ type: 'userPassword', values: [ssha(nueva)] }) }));
    } catch (e) {
      log('ERROR_CAMBIO_CLAVE', uid, e.message);
      throw new HttpError(503, 'El directorio no permitió el cambio. Acude a secretaría para restablecerla.');
    }
  } finally { close(cli); }
  const ver = await newClient({ principal: true }).catch(() => null);
  if (!ver) throw new HttpError(503, 'No se pudo verificar el cambio; intenta iniciar sesión con la nueva contraseña.');
  let ok = true;
  try { await bind(ver, dn, nueva); } catch { ok = false; } finally { close(ver); }
  fails.delete(key);
  // Cierra las demas sesiones abiertas de este usuario en la plataforma.
  const actualSid = cookies(req)[COOKIE];
  for (const [id, s] of sessions) if (s.user.uid === uid && id !== actualSid) sessions.delete(id);
  await audit(uid, 'CLAVE_CAMBIADA', ok ? 'verificada' : 'sin verificar');
  res.json({ ok: true, verificada: ok });
}));

/* ---------- Portal de servicios institucionales ----------
 * Cada servicio se muestra solo si el usuario tiene uno de sus "roles"
 * (admin | teacher | student) o pertenece a uno de sus "grupos" LDAP.
 * Esto decide QUE SE MUESTRA; cada servicio sigue pidiendo su propio inicio de sesion
 * y aplicando sus propios permisos.
 */
const SERVICIOS_FILE = process.env.SERVICIOS_FILE || '/etc/edunova/servicios.json';
const SERVICIOS_DEFECTO = [
  { id: 'correo', nombre: 'Correo institucional', descripcion: 'Bandeja de entrada @mejoland.edu.ec.', icono: 'correo', url: '', roles: ['admin', 'teacher', 'student'], grupos: [] },
];
const ICONOS = ['correo', 'bd', 'impresora', 'secretaria', 'ldap', 'monitoreo', 'enlace', 'archivos', 'wifi', 'biblioteca'];
let serviciosCache = { mtime: -1, list: SERVICIOS_DEFECTO };
const fs = require('fs');
function cargarServicios() {
  try {
    const st = fs.statSync(SERVICIOS_FILE);
    if (st.mtimeMs === serviciosCache.mtime) return serviciosCache.list;
    const raw = JSON.parse(fs.readFileSync(SERVICIOS_FILE, 'utf8'));
    const list = (Array.isArray(raw) ? raw : raw.servicios || []).slice(0, 40).map(x => ({
      id: String(x.id || '').slice(0, 40).replace(/[^a-z0-9_-]/gi, ''),
      nombre: String(x.nombre || '').slice(0, 60),
      descripcion: String(x.descripcion || '').slice(0, 160),
      icono: ICONOS.includes(x.icono) ? x.icono : 'enlace',
      url: /^https?:\/\/[^\s"'<>]+$/i.test(String(x.url || '')) || /^app:[a-z]{2,20}$/.test(String(x.url || '')) ? String(x.url) : '',
      url_publica: /^https:\/\/[^\s"'<>]+$/i.test(String(x.url_publica || '')) || /^\/[a-z0-9][a-z0-9_\/.-]*$/i.test(String(x.url_publica || '')) ? String(x.url_publica) : '',
      roles: (Array.isArray(x.roles) ? x.roles : []).map(String),
      grupos: (Array.isArray(x.grupos) ? x.grupos : []).map(g => String(g).toLowerCase()),
    })).filter(x => x.id && x.nombre);
    serviciosCache = { mtime: st.mtimeMs, list };
    log('SERVICIOS', `${list.length} servicio(s) cargados de ${SERVICIOS_FILE}`);
  } catch (e) {
    if (serviciosCache.mtime !== -2) log('SERVICIOS', `no se pudo leer ${SERVICIOS_FILE}: ${e.message}`);
    serviciosCache = { mtime: -2, list: SERVICIOS_DEFECTO };
  }
  return serviciosCache.list;
}
/** La peticion llego desde Internet por Tailscale Funnel (y no desde la red privada). */
const PROXY_DMZ = String(process.env.PROXY_DMZ || '192.168.60.10,100.65.119.48').split(/[\s,]+/).filter(Boolean);
const viaProxyDmz = req => PROXY_DMZ.includes(String(req.socket.remoteAddress || '').replace(/^::ffff:/, ''));
const desdeInternet = req => !!req.get('tailscale-funnel-request') || /:8443$/.test(String(req.get('x-forwarded-host') || req.get('host') || ''))
  || (viaProxyDmz(req) && req.get('x-mejoland-internet') === '1');
const puedeVer = (u, sv) => sv.roles.includes(u.role) || sv.grupos.some(g => (u.grupos || []).includes(g));
api.get('/servicios', auth(), (req, res) => {
  const u = req.user, pub = desdeInternet(req);
  const out = cargarServicios().filter(sv => puedeVer(u, sv))
    // Desde Internet: solo las secciones de EduNova (app:) y los servicios publicados (url_publica).
    .map(sv => pub ? { ...sv, url: /^app:/.test(sv.url) ? sv.url : sv.url_publica } : sv)
    .filter(sv => pub ? !!sv.url : (sv.url || u.role === 'admin'))
    // Un servicio sin direccion solo lo ve administracion, como "pendiente de configurar".
    .map(sv => ({ id: sv.id, nombre: sv.nombre, descripcion: sv.descripcion, icono: sv.icono, url: sv.url, pendiente: !sv.url }));
  res.json(out);
});
api.post('/servicios/:id/abrir', auth(), wrap(async (req, res) => {
  const sv = cargarServicios().find(x => x.id === String(req.params.id));
  if (!sv || !sv.url || !puedeVer(req.user, sv)) throw forbidden();
  await audit(req.user.uid, 'SERVICIO', sv.nombre);
  res.json({ ok: true });
}));

/* ---------- Impresion: fachada segura de la API de impresion ----------
 * El navegador nunca habla con la API: solo EduNova, desde el mismo servidor.
 * Solo administracion o el grupo LDAP admins-red. Acciones en lista cerrada,
 * impresoras validadas contra CUPS y cada accion queda en la auditoria con el nombre real.
 */
const PRINT = {
  url: (process.env.PRINT_API_URL || 'http://127.0.0.1:8000').replace(/\/+$/, ''),
  auth: 'Basic ' + Buffer.from(`${process.env.PRINT_API_USER || ''}:${process.env.PRINT_API_PASSWORD || ''}`).toString('base64'),
  activa: !!(process.env.PRINT_API_USER && process.env.PRINT_API_PASSWORD),
};
const puedeImprimir = u => u.role === 'admin' || (u.grupos || []).includes('admins-red');
async function printApi(method, ruta, cuerpo, tipo, espera) {
  if (!PRINT.activa) throw new HttpError(503, 'La impresión no está configurada en el servidor.');
  let r;
  try {
    const headers = { Authorization: PRINT.auth };
    if (cuerpo) headers['Content-Type'] = tipo;
    r = await fetch(PRINT.url + ruta, { method, headers, body: cuerpo, signal: AbortSignal.timeout(espera || (cuerpo ? 60000 : 6000)) });
  } catch (e) {
    log('IMPRESION', 'sin conexion con la API:', e.cause?.code || e.name);
    throw new HttpError(503, 'El servicio de impresión no está disponible.');
  }
  const data = await r.json().catch(() => ({}));
  if (!r.ok) {
    log('IMPRESION', method, ruta, '->', r.status, String(data.detail || '').slice(0, 200));
    if (r.status === 404) throw new HttpError(404, 'Impresora no encontrada.');
    if (r.status === 502 && typeof data.detail === 'string' && /CUPS no pudo|impresora/i.test(data.detail)) throw new HttpError(502, data.detail.slice(0, 200));
    // Mensajes de validacion propios de la API (rango, cupo, tipo de archivo): se muestran tal cual.
    if ([400, 409, 413, 415, 422].includes(r.status) && typeof data.detail === 'string') throw new HttpError(r.status === 413 || r.status === 415 ? 400 : r.status, String(data.detail).slice(0, 200));
    throw new HttpError(r.status === 401 ? 503 : 502, r.status === 401 ? 'EduNova no tiene acceso a la API de impresión (revisa la clave).' : 'La impresora no pudo completar la acción.');
  }
  return data;
}
/** Traduce printer-state-reasons de CUPS/IPP a avisos para las personas. */
const MOTIVOS = [
  [/^media-(empty|needed)/, 'error', 'Sin papel', 'La bandeja está vacía. Avisa a TI o a secretaría para que la carguen.'],
  [/^media-jam/, 'error', 'Papel atascado', 'Hay una hoja atascada. Avisa a TI.'],
  [/^(marker-supply|toner)-empty/, 'error', 'Sin tinta', 'Uno de los tanques de tinta está vacío.'],
  [/^(cover|door|interlock)-open/, 'error', 'Tapa abierta', 'La impresora tiene una tapa abierta.'],
  [/^(offline|shutdown|connecting-to-device|timed-out|printer-not-responding)/, 'error', 'Apagada o desconectada', 'La impresora no responde. Puede estar apagada o sin red.'],
  [/^(other-error|output-area-full|input-tray-missing)/, 'error', 'Necesita revisión', 'La impresora reporta un problema.'],
  [/^(marker-supply|toner)-low/, 'aviso', 'Tinta baja', 'La tinta está por terminarse.'],
  [/^media-low/, 'aviso', 'Poco papel', 'Queda poco papel en la bandeja.'],
];
function diagnostico(a) {
  const razones = [].concat(a['printer-state-reasons'] || []).map(String).filter(r => r && r !== 'none');
  const avisos = [];
  for (const r of razones) {
    const m = MOTIVOS.find(([re]) => re.test(r));
    if (m && !avisos.some(x => x.titulo === m[2])) avisos.push({ nivel: r.endsWith('-warning') && m[1] === 'error' ? 'aviso' : m[1], titulo: m[2], detalle: m[3] });
  }
  const arr = v => [].concat(v ?? []);
  const nombres = arr(a['marker-names']), niveles = arr(a['marker-levels']), colores = arr(a['marker-colors']);
  const es = n => String(n).replace(/black/i, 'Negro').replace(/cyan/i, 'Cian').replace(/magenta/i, 'Magenta').replace(/yellow/i, 'Amarillo').replace(/\s*(ink|toner|cartridge)\b/i, '').trim();
  const tintas = nombres.map((n, i) => ({ nombre: es(n).slice(0, 40), nivel: Number(niveles[i]), color: /^#[0-9a-f]{6}/i.test(colores[i] || '') ? String(colores[i]).slice(0, 7) : '#64748b' }))
    .filter(t => Number.isFinite(t.nivel) && t.nivel >= 0 && t.nivel <= 100);
  return { avisos, tintas, enCola: Number(a['queued-job-count']) || 0 };
}
/** Estado de una impresora en palabras: libre / ocupada / pausada / problema. */
function estadoParaUsuarios(p) {
  if (!p) return { clase: 'desconocido', titulo: 'Impresora no disponible', detalle: 'No se encontró la impresora configurada. Avisa a TI.' };
  const err = p.avisos.find(a => a.nivel === 'error');
  if (err) return { clase: 'problema', titulo: err.titulo, detalle: `${err.detalle} Puedes enviar tu documento: quedará en cola y saldrá cuando se solucione.` };
  if (p.detenida) return { clase: 'pausada', titulo: 'Pausada por TI', detalle: 'Tu documento quedará en cola y saldrá cuando la reanuden.' };
  if (p.estado === 'Imprimiendo' || p.enCola > 0) return { clase: 'ocupada', titulo: 'En uso', detalle: `Está imprimiendo. ${p.enCola > 0 ? `Hay ${p.enCola} trabajo(s) en cola antes del tuyo.` : 'Tu documento saldrá al terminar.'}` };
  return { clase: 'libre', titulo: 'Libre', detalle: 'Puedes enviar tu documento ahora.' };
}
/* ---------- Grupo de impresion ---------- */
// Impresoras que usan estudiantes y docentes. Si la tabla esta vacia se usa PRINT_IMPRESORA.
async function grupo() {
  let rows = [];
  try { [rows] = await db.query('SELECT nombre, color, activa FROM lms_impresoras_pool ORDER BY nombre'); } catch { /* tabla aun no creada */ }
  if (!rows.length) return [{ nombre: IMPRESORA, color: true, activa: true, porDefecto: true }];
  return rows.map(r => ({ nombre: r.nombre, color: !!r.color, activa: !!r.activa }));
}
const sana = p => p && !p.detenida && p.aceptaTrabajos && !p.avisos.some(a => a.nivel === 'error');
/** Elige la impresora para un trabajo: sana, con menos cola, libre primero; a color solo si se pide color. */
async function elegirImpresora(color) {
  const [g, lista] = await Promise.all([grupo(), printApi('GET', '/impresoras').then(impresoras)]);
  const cand = g.filter(x => x.activa && (!color || x.color)).map(x => ({ ...lista.find(p => p.nombre === x.nombre), color: x.color })).filter(p => p.nombre);
  if (!cand.length) throw new HttpError(409, color ? 'No hay impresoras a color disponibles. Envíalo en blanco y negro.' : 'No hay impresoras disponibles. Avisa a TI.');
  const orden = (a, b) => (a.enCola - b.enCola) || ((a.estado === 'Disponible' ? 0 : 1) - (b.estado === 'Disponible' ? 0 : 1)) || (Number(a.color) - Number(b.color)) || a.nombre.localeCompare(b.nombre);
  const buenas = cand.filter(sana).sort(orden);
  // Si ninguna esta bien (sin papel, pausada...), el trabajo queda en cola en la que tenga menos trabajos.
  return { impresora: buenas[0] || cand.sort(orden)[0], enEspera: !buenas.length };
}
async function estadoImpresora() {
  try {
    const [g, lista] = await Promise.all([grupo(), printApi('GET', '/impresoras').then(impresoras)]);
    const items = g.filter(x => x.activa).map(x => {
      const p = lista.find(i => i.nombre === x.nombre);
      return { nombre: x.nombre, descripcion: p?.descripcion || x.nombre, ubicacion: p?.ubicacion || '', color: x.color,
        ...estadoParaUsuarios(p), avisos: (p?.avisos || []).filter(a => a.nivel === 'aviso'), tintas: p?.tintas || [], enCola: p?.enCola || 0 };
    });
    if (!items.length) return { clase: 'problema', titulo: 'Sin impresoras', detalle: 'No hay impresoras habilitadas para imprimir. Avisa a TI.', impresoras: [], avisos: [], tintas: [], enCola: 0 };
    if (items.length === 1) return { ...items[0], impresoras: items, revisado: new Date().toISOString() };
    const libres = items.filter(i => i.clase === 'libre').length, usables = items.filter(i => ['libre', 'ocupada'].includes(i.clase)).length;
    const clase = libres ? 'libre' : usables ? 'ocupada' : items.some(i => i.clase === 'pausada') && !items.some(i => i.clase === 'problema') ? 'pausada' : 'problema';
    const titulo = libres ? `${libres} de ${items.length} libres` : usables ? 'Todas en uso' : 'Ninguna disponible';
    const detalle = libres ? 'Tu documento irá a la impresora libre que tenga menos cola.' : usables ? 'Tu documento irá a la que tenga menos trabajos en cola.' : 'Tu documento quedará en cola hasta que se solucione.';
    return { clase, titulo, detalle, impresoras: items, avisos: [], tintas: [], enCola: items.reduce((s, i) => s + i.enCola, 0), revisado: new Date().toISOString() };
  } catch (e) {
    if (sinServidorImpresion(e)) return { clase: 'diferida', titulo: 'Impresión diferida', detalle: 'El servidor de impresión está en mantenimiento. Puedes enviar tu documento igual: se guarda y se imprime solo en cuanto vuelva. Puedes cancelarlo antes desde "Mis impresiones".', impresoras: [], avisos: [], tintas: [], enCola: 0 };
    return { clase: 'desconocido', titulo: 'Estado no disponible', detalle: 'No se pudo consultar las impresoras en este momento.', impresoras: [], avisos: [], tintas: [], enCola: 0 };
  }
}
const ESTADO_IMPRESORA = { 3: 'Disponible', 4: 'Imprimiendo', 5: 'Detenida' };
function impresoras(raw) {
  return Object.entries(raw?.impresoras || {}).map(([nombre, a]) => ({
    nombre,
    estado: ESTADO_IMPRESORA[a['printer-state']] || 'Desconocido',
    detenida: a['printer-state'] === 5,
    mensaje: String(a['printer-state-message'] || '').slice(0, 200),
    descripcion: String(a['printer-info'] || '').slice(0, 120),
    ubicacion: String(a['printer-location'] || '').slice(0, 120),
    modelo: String(a['printer-make-and-model'] || '').slice(0, 120),
    aceptaTrabajos: a['printer-is-accepting-jobs'] !== false,
    ...diagnostico(a),
  })).sort((x, y) => x.nombre.localeCompare(y.nombre));
}
api.get('/impresion', auth(), wrap(async (req, res) => {
  if (!puedeImprimir(req.user)) throw forbidden();
  let imp = {}, trab = {}, aviso = '';
  try { [imp, trab] = await Promise.all([printApi('GET', '/impresoras'), printApi('GET', '/trabajos')]); }
  catch (e) {
    if (!sinServidorImpresion(e)) throw e;
    aviso = 'El servidor de impresión (SRV-BD) no responde. Los documentos que se envíen quedan "En espera" y se imprimirán solos cuando vuelva.';
  }
  const trabajos = (trab.trabajos || []).slice(0, 100).map(t => ({
    id: Number(t.id), impresora: String(t.impresora || ''), usuario: String(t.usuario || ''), documento: String(t.documento || ''),
    origen: String(t.ip || ''), paginas: Number(t.paginas) || 0, kb: Number(t.tamano_kb) || 0, estado: String(t.estado || ''),
    fecha: Number(t.fecha) || 0,
  }));
  const [cons] = await db.query(`SELECT uid, SUM(CASE WHEN creado_en >= CURDATE() THEN paginas ELSE 0 END) AS hoy,
      SUM(paginas) AS mes, COUNT(*) AS envios FROM lms_impresiones WHERE cancelado=0 AND creado_en >= DATE_FORMAT(CURDATE(), '%Y-%m-01')
      GROUP BY uid ORDER BY mes DESC LIMIT 50`);
  let dir = new Map(); try { dir = await directory(); } catch { /* LDAP caido */ }
  const consumo = cons.map(c => ({ uid: c.uid, nombre: dir.get(c.uid)?.nombre || c.uid, rol: dir.get(c.uid)?.role || '', hoy: Number(c.hoy), mes: Number(c.mes), envios: Number(c.envios) }));
  const g = await grupo();
  const lista = impresoras(imp).map(p => { const x = g.find(y => y.nombre === p.nombre); return { ...p, enGrupo: !!x, activa: !!x?.activa, color: !!x?.color }; });
  const [rec] = await db.query(`SELECT i.id, i.uid, i.documento, i.impresora, i.paginas, i.copias, i.color, i.cancelado, i.diferido, i.creado_en,
      (i.archivo IS NOT NULL OR p.id IS NOT NULL) AS copia
      FROM lms_impresiones i LEFT JOIN lms_impresion_pendiente p ON p.id = i.id ORDER BY i.id DESC LIMIT 100`).catch(() => [[]]);
  const recientes = rec.map(r => ({ ...r, nombre: dir.get(r.uid)?.nombre || r.uid, color: !!r.color, cancelado: !!r.cancelado, diferido: !!r.diferido, copia: !!r.copia }));
  res.json({ impresoras: lista, trabajos, consumo, cupos: CUPOS, grupoPorDefecto: !!g[0]?.porDefecto,
    recientes, verContenido: req.user.role === 'admin', retencionDias: RETENCION_DIAS, aviso });
}));
const ACCIONES_IMPRESION = { pausar: 'pausó', reanudar: 'reanudó', limpiar: 'vació la cola de' };
api.post('/impresion/control', auth(), wrap(async (req, res) => {
  if (!puedeImprimir(req.user)) throw forbidden();
  const accion = String(req.body?.accion || '');
  const nombre = String(req.body?.impresora || '');
  if (!Object.hasOwn(ACCIONES_IMPRESION, accion)) throw bad('Acción no válida.');
  const lista = impresoras(await printApi('GET', '/impresoras'));
  if (!lista.some(p => p.nombre === nombre)) throw bad('Impresora no válida.');
  await printApi('POST', `/control/${accion}?impresora=${encodeURIComponent(nombre)}`);
  await audit(req.user.uid, 'IMPRESION', `${ACCIONES_IMPRESION[accion]} ${nombre}`);
  res.json({ ok: true });
}));

/* ---------- Agregar / configurar / quitar impresoras (administracion y TI) ---------- */
const NOMBRE_IMP = /^[A-Za-z0-9_-]{2,40}$/;
async function guardarEnGrupo(nombre, cambios) {
  const g = await grupo();
  if (g[0]?.porDefecto) { // primera vez: se pasa la impresora del .env a la tabla para no perderla
    await db.query('INSERT IGNORE INTO lms_impresoras_pool (nombre, color, activa) VALUES (?,1,1)', [IMPRESORA]);
  }
  const [[ya]] = await db.query('SELECT color, activa FROM lms_impresoras_pool WHERE nombre=?', [nombre]);
  const color = cambios.color ?? (ya ? !!ya.color : false), activa = cambios.activa ?? (ya ? !!ya.activa : true);
  await db.query('INSERT INTO lms_impresoras_pool (nombre, color, activa) VALUES (?,?,?) ON DUPLICATE KEY UPDATE color=VALUES(color), activa=VALUES(activa)',
    [nombre, color ? 1 : 0, activa ? 1 : 0]);
}
api.get('/impresion/descubrir', auth(), wrap(async (req, res) => {
  if (!puedeImprimir(req.user)) throw forbidden();
  const d = await printApi('GET', '/descubrir', undefined, undefined, 30000);
  res.json((d.dispositivos || []).slice(0, 60).map(x => ({ uri: String(x.uri), tipo: String(x.tipo || ''), nombre: String(x.nombre || '').slice(0, 120), modelo: String(x.modelo || '').slice(0, 120), ubicacion: String(x.ubicacion || '').slice(0, 120) })));
}));
api.post('/impresion/impresoras', auth(), wrap(async (req, res) => {
  if (!puedeImprimir(req.user)) throw forbidden();
  const b = req.body || {};
  const nombre = String(b.nombre || '').trim();
  let uri = String(b.uri || '').trim();
  if (!NOMBRE_IMP.test(nombre)) throw bad('Nombre: solo letras, números, guion y guion bajo (2 a 40), sin espacios. Ejemplo: Biblioteca');
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(uri)) uri = `ipp://${uri}/ipp/print`; // escribieron solo la IP
  if (!/^(ipp|ipps|dnssd|usb|socket|lpd):\/\/[^\s"'<>`$;|&]{1,250}$/.test(uri)) throw bad('Elige una impresora de la lista o escribe su dirección IP.');
  const cuerpo = JSON.stringify({ nombre, uri, descripcion: String(b.descripcion || '').slice(0, 120), ubicacion: String(b.ubicacion || '').slice(0, 120), modelo: String(b.modelo || '').slice(0, 200) });
  const r = await printApi('POST', '/impresoras', cuerpo, 'application/json', 90000);
  await guardarEnGrupo(nombre, { color: b.color === true, activa: b.activa !== false });
  await audit(req.user.uid, 'IMPRESORA_AGREGADA', `${nombre} (${String(b.ubicacion || '').slice(0, 60)})`);
  res.json({ ok: true, controlador: r.controlador });
}));
api.patch('/impresion/impresoras/:nombre', auth(), wrap(async (req, res) => {
  if (!puedeImprimir(req.user)) throw forbidden();
  const nombre = String(req.params.nombre);
  const lista = impresoras(await printApi('GET', '/impresoras'));
  if (!lista.some(p => p.nombre === nombre)) throw notFound();
  const b = req.body || {}, cambios = {};
  if (typeof b.activa === 'boolean') cambios.activa = b.activa;
  if (typeof b.color === 'boolean') cambios.color = b.color;
  if (Object.keys(cambios).length) await guardarEnGrupo(nombre, cambios);
  if (typeof b.descripcion === 'string' || typeof b.ubicacion === 'string') {
    await printApi('PATCH', `/impresoras/${encodeURIComponent(nombre)}`, JSON.stringify({
      ...(typeof b.descripcion === 'string' ? { descripcion: b.descripcion.slice(0, 120) } : {}),
      ...(typeof b.ubicacion === 'string' ? { ubicacion: b.ubicacion.slice(0, 120) } : {}) }), 'application/json');
  }
  const txt = [cambios.activa === true && 'habilitó', cambios.activa === false && 'deshabilitó', cambios.color === true && 'marcó a color', cambios.color === false && 'marcó solo B/N', (b.descripcion || b.ubicacion) && 'editó'].filter(Boolean).join(', ');
  await audit(req.user.uid, 'IMPRESORA_CONFIG', `${txt} ${nombre}`);
  res.json({ ok: true });
}));
api.delete('/impresion/impresoras/:nombre', auth(), wrap(async (req, res) => {
  if (!puedeImprimir(req.user)) throw forbidden();
  const nombre = String(req.params.nombre);
  if (!NOMBRE_IMP.test(nombre)) throw bad('Nombre no válido.');
  await printApi('DELETE', `/impresoras/${encodeURIComponent(nombre)}`);
  await db.query('DELETE FROM lms_impresoras_pool WHERE nombre=?', [nombre]);
  await audit(req.user.uid, 'IMPRESORA_QUITADA', nombre);
  res.json({ ok: true });
}));


/* ---------- Imprimir desde la plataforma ---------- */
const envInt = (k, d) => { const n = parseInt(process.env[k] ?? '', 10); return Number.isFinite(n) && n >= 0 ? n : d; };
const CUPOS = {
  student: { limite: envInt('PRINT_CUPO_ESTUDIANTE', 20), color: envInt('PRINT_COLOR_ESTUDIANTE', 0) === 1 },
  teacher: { limite: envInt('PRINT_CUPO_DOCENTE', 100), color: envInt('PRINT_COLOR_DOCENTE', 1) === 1 },
  admin: { limite: envInt('PRINT_CUPO_ADMIN', 0), color: envInt('PRINT_COLOR_ADMIN', 1) === 1 },
  secretary: { limite: envInt('PRINT_CUPO_SECRETARIA', 100), color: envInt('PRINT_COLOR_SECRETARIA', 1) === 1 },
}; // limite 0 = sin limite
const IMPRESORA = process.env.PRINT_IMPRESORA || 'impresora-principal';
/* Copia de lo impreso (control institucional): carpeta privada, se borra sola tras N dias. */
const ARCHIVO_DIR = process.env.PRINT_ARCHIVO_DIR || '/var/lib/edunova/impresiones';
const RETENCION_DIAS = envInt('PRINT_RETENCION_DIAS', 7); // 0 = no guardar copias
const EXT_IMPRESION = { 'application/pdf': '.pdf', 'image/jpeg': '.jpg', 'image/png': '.png' };
const ARCHIVO_RE = /^\d{1,10}-[0-9a-f]{16}\.(pdf|jpg|png)$/;
async function guardarCopia(id, cuerpo, tipo) {
  if (!RETENCION_DIAS) return;
  const nombre = `${id}-${crypto.randomBytes(8).toString('hex')}${EXT_IMPRESION[tipo] || '.pdf'}`;
  try {
    await fs.promises.mkdir(ARCHIVO_DIR, { recursive: true, mode: 0o750 });
    await fs.promises.writeFile(path.join(ARCHIVO_DIR, nombre), cuerpo, { mode: 0o640, flag: 'wx' });
    await db.query('UPDATE lms_impresiones SET archivo=? WHERE id=?', [nombre, id]);
  } catch (e) { log('IMPRESION', 'no se pudo guardar la copia:', e.code || e.message); }
}
async function limpiarCopias() {
  if (!RETENCION_DIAS) return;
  try {
    const [viejas] = await db.query('SELECT id, archivo FROM lms_impresiones WHERE archivo IS NOT NULL AND creado_en < NOW() - INTERVAL ? DAY', [RETENCION_DIAS]);
    for (const v of viejas) {
      if (ARCHIVO_RE.test(v.archivo)) await fs.promises.unlink(path.join(ARCHIVO_DIR, v.archivo)).catch(() => {});
      await db.query('UPDATE lms_impresiones SET archivo=NULL WHERE id=?', [v.id]);
    }
    if (viejas.length) log('IMPRESION', `${viejas.length} copia(s) borradas por antigüedad`);
  } catch (e) { if (e.code !== 'ER_BAD_FIELD_ERROR') log('IMPRESION', 'limpieza:', e.code || e.message); }
}
setTimeout(limpiarCopias, 15000).unref();
setInterval(limpiarCopias, 3600 * 1000).unref();
/* ---------- Impresion diferida ---------- */
const DIFERIDO = envInt('PRINT_DIFERIDO', 1) === 1;
const DIFERIDO_MAX = 8 * 1024 * 1024; // en base64 ocupa ~11 MB: cabe en el max_allowed_packet de MariaDB
const zlib = require('zlib');
/** La API de impresion no responde (servidor caido o en mantenimiento): se puede diferir. */
function sinServidorImpresion(e) { return DIFERIDO && PRINT.activa && e instanceof HttpError && e.status === 503; }
/** Cuenta paginas de un PDF sin la API (tambien dentro de flujos comprimidos). Imagen = 1. */
function contarPaginas(buf, tipo) {
  if (tipo !== 'application/pdf') return 1;
  const re = /\/Type\s*\/Page(?![a-zA-Z])/g;
  let n = (buf.toString('latin1').match(re) || []).length;
  if (n) return n;
  const txt = buf.toString('latin1'); let i = 0;
  while ((i = txt.indexOf('stream', i)) !== -1 && n < 5000) {
    let ini = i + 6; if (txt[ini] === '\r') ini++; if (txt[ini] === '\n') ini++;
    const fin = txt.indexOf('endstream', ini); if (fin === -1) break;
    try { n += (zlib.inflateSync(buf.subarray(ini, fin), { finishFlush: zlib.constants.Z_SYNC_FLUSH }).toString('latin1').match(re) || []).length; } catch { /* no comprimido */ }
    i = fin + 9;
  }
  return n || 1;
}
/** Paginas que salen segun el rango ("1-3,5") sobre un documento de `total` paginas. */
function paginasRango(rango, total) {
  if (!rango) return total;
  const sel = new Set();
  for (const parte of rango.split(',')) {
    const [a, b] = parte.split('-').map(Number);
    for (let k = a; k <= (b || a) && k <= total; k++) if (k >= 1) sel.add(k);
  }
  return sel.size || total;
}
/** Envia a la impresora los trabajos que quedaron en espera (corre en el EduNova que tenga la API). */
let despachando = false;
async function despacharDiferidos() {
  if (!DIFERIDO || !PRINT.activa || despachando) return;
  despachando = true;
  try {
    // Registros "En espera" sin documento guardado (fallaron al guardarse): se anulan y se devuelve el cupo.
    const [h] = await db.query(`UPDATE lms_impresiones i LEFT JOIN lms_impresion_pendiente p ON p.id = i.id
        SET i.cancelado = 1, i.diferido = 0 WHERE i.diferido = 1 AND p.id IS NULL AND i.creado_en < NOW() - INTERVAL 5 MINUTE`);
    if (h.affectedRows) log('IMPRESION', `${h.affectedRows} registro(s) en espera sin documento anulados`);
    const [pend] = await db.query(`SELECT i.id, i.uid, i.documento, i.copias, i.color, p.tipo, p.rango
        FROM lms_impresiones i JOIN lms_impresion_pendiente p ON p.id = i.id WHERE i.diferido = 1 AND i.cancelado = 0 ORDER BY i.id LIMIT 10`);
    for (const t of pend) {
      const [tomado] = await db.query('UPDATE lms_impresiones SET diferido = 2 WHERE id = ? AND diferido = 1', [t.id]);
      if (!tomado.affectedRows) continue;
      try {
        const [[c]] = await db.query('SELECT contenido FROM lms_impresion_pendiente WHERE id = ?', [t.id]);
        const cuerpo = Buffer.from(c.contenido, 'base64');
        const { impresora: dest } = await elegirImpresora(!!t.color);
        const q = new URLSearchParams({ usuario: t.uid, titulo: t.documento, copias: String(t.copias), paginas: t.rango || '', color: t.color ? 'true' : 'false', max_paginas: '-1', impresora: dest.nombre });
        const r = await printApi('POST', `/imprimir?${q}`, cuerpo, t.tipo);
        await db.query('UPDATE lms_impresiones SET trabajo = ?, impresora = ?, paginas = ?, paginas_doc = ?, diferido = 0 WHERE id = ?',
          [Number(r.trabajo), dest.nombre, Number(r.paginas), Number(r.paginas_documento), t.id]);
        await db.query('DELETE FROM lms_impresion_pendiente WHERE id = ?', [t.id]);
        await guardarCopia(t.id, cuerpo, t.tipo);
        await audit(t.uid, 'IMPRESION_ENVIADA', `${t.documento} · ${r.paginas} pág. (estaba en espera) → ${dest.nombre}`);
        log('IMPRESION', `trabajo en espera #${t.id} de ${t.uid} enviado a ${dest.nombre}`);
      } catch (e) {
        await db.query('UPDATE lms_impresiones SET diferido = 1 WHERE id = ?', [t.id]);
        if (sinServidorImpresion(e)) break; // sigue sin servidor de impresion: se reintenta luego
        log('IMPRESION', `trabajo en espera #${t.id} no se pudo enviar:`, e.message);
      }
    }
  } catch (e) { if (!['ER_NO_SUCH_TABLE', 'ER_BAD_FIELD_ERROR', 'ER_OPTION_PREVENTS_STATEMENT'].includes(e.code)) log('IMPRESION', 'despacho:', e.code || e.message); }
  finally { despachando = false; }
}
setTimeout(despacharDiferidos, 20000).unref();
setInterval(despacharDiferidos, 30000).unref();

async function usadoHoy(uid) {
  const [[r]] = await db.query('SELECT COALESCE(SUM(paginas),0) AS n FROM lms_impresiones WHERE uid=? AND cancelado=0 AND creado_en >= CURDATE()', [uid]);
  return Number(r.n);
}
const colaUsuario = new Map(); // un envio a la vez por usuario (el cupo no se puede saltar con envios simultaneos)
function enSerie(uid, fn) {
  const prev = colaUsuario.get(uid) || Promise.resolve();
  const p = prev.catch(() => {}).then(fn);
  colaUsuario.set(uid, p);
  p.finally(() => { if (colaUsuario.get(uid) === p) colaUsuario.delete(uid); }).catch(() => {});
  return p;
}
api.get('/imprimir', auth(), wrap(async (req, res) => {
  const u = req.user, cfg = CUPOS[u.role];
  const [rows] = await db.query('SELECT id, trabajo, impresora, documento, paginas, paginas_doc, copias, color, cancelado, diferido, creado_en FROM lms_impresiones WHERE uid=? ORDER BY id DESC LIMIT 25', [u.uid]);
  let estados = new Map();
  try { estados = new Map(((await printApi('GET', '/trabajos')).trabajos || []).map(t => [Number(t.id), String(t.estado)])); } catch { /* API caida: se muestra sin estado */ }
  res.json({
    estado: await estadoImpresora(),
    retencionDias: RETENCION_DIAS,
    cupo: { limite: cfg.limite, usado: await usadoHoy(u.uid), color: cfg.color },
    trabajos: rows.map(r => ({ ...r, color: !!r.color, cancelado: !!r.cancelado, estado: r.cancelado ? 'Cancelado' : r.diferido ? 'En espera' : (estados.get(Number(r.trabajo)) || '—') })),
  });
}));
api.get('/imprimir/estado', auth(), wrap(async (req, res) => res.json(await estadoImpresora())));
api.post('/imprimir', auth(), express.raw({ type: TIPOS_IMPRESION, limit: '10mb' }), wrap(async (req, res) => {
  const u = req.user, cfg = CUPOS[u.role];
  if (!Buffer.isBuffer(req.body) || !req.body.length) throw bad('Selecciona un archivo PDF, JPG o PNG.');
  const copias = int(req.query.copias ?? 1, 'copias', 1, 20);
  const paginas = String(req.query.paginas || '').replace(/\s+/g, '');
  if (paginas && !/^\d{1,4}(-\d{1,4})?(,\d{1,4}(-\d{1,4})?){0,19}$/.test(paginas)) throw bad('Rango de páginas no válido (ejemplo: 1-3,5).');
  const color = req.query.color === '1';
  if (color && !cfg.color) throw bad('Tu tipo de cuenta solo puede imprimir en blanco y negro.');
  const documento = String(req.query.titulo || 'documento').replace(/[^\p{L}\p{N} ._,()-]/gu, '_').slice(0, 100) || 'documento';
  const out = await enSerie(u.uid, async () => {
    const usado = await usadoHoy(u.uid);
    const disponible = cfg.limite ? cfg.limite - usado : -1;
    if (cfg.limite && disponible <= 0) throw new HttpError(409, `Ya usaste tus ${cfg.limite} páginas de hoy. Mañana se renueva tu cupo.`);
    let elegida;
    try { elegida = await elegirImpresora(color); } catch (e) {
      if (!sinServidorImpresion(e)) throw e;
      return diferir(u, cfg, req, { documento, copias, paginas, color, usado, disponible });
    }
    const { impresora: dest, enEspera } = elegida;
    const q = new URLSearchParams({ usuario: u.uid, titulo: documento, copias: String(copias), paginas, color: color ? 'true' : 'false', max_paginas: String(disponible), impresora: dest.nombre });
    const r = await printApi('POST', `/imprimir?${q}`, req.body, req.get('content-type').split(';')[0]);
    const [ins] = await db.query('INSERT INTO lms_impresiones (uid, trabajo, impresora, documento, paginas, paginas_doc, copias, color) VALUES (?,?,?,?,?,?,?,?)',
      [u.uid, Number(r.trabajo), dest.nombre, documento, Number(r.paginas), Number(r.paginas_documento), copias, color ? 1 : 0]);
    await guardarCopia(ins.insertId, req.body, req.get('content-type').split(';')[0]);
    await audit(u.uid, 'IMPRESION_ENVIADA', `${documento} · ${r.paginas} pág.${color ? ' color' : ''} → ${dest.nombre}`);
    return { trabajo: Number(r.trabajo), paginas: Number(r.paginas), usado: usado + Number(r.paginas), limite: cfg.limite,
      impresora: dest.nombre, descripcion: dest.descripcion || dest.nombre, ubicacion: dest.ubicacion || '', enEspera };
  });
  res.json(out);
}));
/** Guarda el trabajo en la base de datos para imprimirlo cuando vuelva el servidor de impresion. */
async function diferir(u, cfg, req, o) {
  const tipo = req.get('content-type').split(';')[0];
  if (req.body.length > DIFERIDO_MAX) throw new HttpError(413, 'Mientras el servidor de impresión está en mantenimiento solo se aceptan archivos de hasta 8 MB.');
  const total = contarPaginas(req.body, tipo);
  const hojas = paginasRango(o.paginas, total) * o.copias;
  if (cfg.limite && hojas > o.disponible) throw new HttpError(409, `Este documento usa ${hojas} página(s) y te quedan ${o.disponible} hoy.`);
  const [ins] = await db.query(`INSERT INTO lms_impresiones (uid, trabajo, impresora, documento, paginas, paginas_doc, copias, color, diferido)
      VALUES (?,0,'(en espera)',?,?,?,?,?,1)`, [u.uid, o.documento, hojas, total, o.copias, o.color ? 1 : 0]);
  try {
    await db.query('INSERT INTO lms_impresion_pendiente (id, tipo, rango, contenido) VALUES (?,?,?,?)', [ins.insertId, tipo, o.paginas || null, req.body.toString('base64')]);
  } catch (e) { // sin la copia no se puede imprimir luego: se deshace el registro (no queda "En espera" vacio)
    await db.query('DELETE FROM lms_impresiones WHERE id=?', [ins.insertId]).catch(() => {});
    log('IMPRESION', 'no se pudo guardar el documento en espera:', e.code || e.message);
    throw new HttpError(503, 'No se pudo guardar tu documento para imprimirlo después. Avisa a TI.');
  }
  await audit(u.uid, 'IMPRESION_DIFERIDA', `${o.documento} · ${hojas} pág.${o.color ? ' color' : ''} (servidor de impresión no disponible)`);
  return { diferido: true, trabajo: 0, paginas: hojas, usado: o.usado + hojas, limite: cfg.limite };
}

api.post('/imprimir/:id/cancelar', auth(), wrap(async (req, res) => {
  const id = idParam(req.params.id);
  const [[r]] = await db.query('SELECT id, uid, trabajo, cancelado, diferido FROM lms_impresiones WHERE id=?', [id]);
  if (!r) throw notFound();
  if (r.uid !== req.user.uid && req.user.role !== 'admin') throw forbidden();
  if (r.cancelado) return res.json({ ok: true });
  if (r.diferido) {
    const [c] = await db.query('UPDATE lms_impresiones SET cancelado=1 WHERE id=? AND diferido=1', [id]);
    if (!c.affectedRows) throw new HttpError(409, 'Se está enviando a la impresora en este momento. Intenta cancelarlo en unos segundos.');
    await db.query('DELETE FROM lms_impresion_pendiente WHERE id=?', [id]);
    await audit(req.user.uid, 'IMPRESION_CANCELADA', `en espera #${id}${r.uid !== req.user.uid ? ' de ' + r.uid : ''}`);
    return res.json({ ok: true });
  }
  await printApi('POST', `/cancelar/${Number(r.trabajo)}`);
  await db.query('UPDATE lms_impresiones SET cancelado=1 WHERE id=?', [id]); // se devuelve el cupo
  await audit(req.user.uid, 'IMPRESION_CANCELADA', `trabajo ${r.trabajo}${r.uid !== req.user.uid ? ' de ' + r.uid : ''}`);
  res.json({ ok: true });
}));

/** Ver el documento impreso: SOLO administracion; cada consulta queda en la auditoria. */
api.get('/impresion/documento/:id', auth('admin'), wrap(async (req, res) => {
  const id = idParam(req.params.id);
  const [[r]] = await db.query('SELECT id, uid, documento, archivo FROM lms_impresiones WHERE id=?', [id]);
  if (!r) throw notFound();
  const cabeceras = tipo => {
    res.setHeader('Content-Type', tipo);
    res.setHeader('Content-Disposition', `inline; filename="${String(r.documento).replace(/[^\w .()-]/g, '_')}"`);
    res.setHeader('Cache-Control', 'no-store');
  };
  if (!r.archivo) { // trabajo en espera: la copia esta en la base de datos
    const [[p]] = await db.query('SELECT tipo, contenido FROM lms_impresion_pendiente WHERE id=?', [id]).catch(() => [[]]);
    if (!p) throw new HttpError(404, 'La copia ya no existe (se borra pasados los días de conservación).');
    await audit(req.user.uid, 'IMPRESION_VISTA', `${r.documento} de ${r.uid} (en espera)`);
    cabeceras(TIPOS_IMPRESION.includes(p.tipo) ? p.tipo : 'application/octet-stream');
    return res.end(Buffer.from(p.contenido, 'base64'));
  }
  if (!ARCHIVO_RE.test(r.archivo)) throw new HttpError(404, 'La copia ya no existe.');
  const ruta = path.join(ARCHIVO_DIR, r.archivo);
  if (!fs.existsSync(ruta)) throw new HttpError(404, 'La copia está guardada en el otro servidor (SRV-BD). Estará disponible cuando vuelva.');
  await audit(req.user.uid, 'IMPRESION_VISTA', `${r.documento} de ${r.uid}`);
  cabeceras({ pdf: 'application/pdf', jpg: 'image/jpeg', png: 'image/png' }[r.archivo.split('.').pop()]);
  fs.createReadStream(ruta).pipe(res);
}));

/* ======================= Biblioteca institucional =======================
 * Niveles: 1 Toda la institucion, 2 Personal (docentes+), 3 Secretaria y administracion, 4 Solo administracion.
 * Cada rol ve los niveles <= el suyo y publica en esos mismos niveles. Un recurso puede ser de un curso:
 * lo ven los estudiantes matriculados, su docente, secretaria y administracion.
 */
const NIVEL_ROL = { student: 1, teacher: 2, secretary: 3, admin: 4 };
const NIVELES = { 1: 'Toda la institución', 2: 'Personal (docentes, secretaría y administración)', 3: 'Secretaría y administración', 4: 'Solo administración' };
const CATEGORIAS = ['Reglamentos y normativa', 'Circulares y comunicados', 'Calendario académico', 'Formatos y plantillas', 'Material de estudio', 'Otros'];
const BIBLIO_MAX = 20 * 1024 * 1024;
const ASIGNATURAS = ['Matemáticas', 'Lengua y Literatura', 'Ciencias Naturales', 'Estudios Sociales', 'Inglés', 'Física', 'Química', 'Biología',
  'Historia', 'Filosofía', 'Educación Ciudadana', 'Educación Física', 'Educación Cultural y Artística', 'Computación', 'Emprendimiento y Gestión', 'Lectura general', 'Otras'];
const NIVELES_EDU = ['8vo EGB', '9no EGB', '10mo EGB', '1ro BGU', '2do BGU', '3ro BGU', 'Todos los niveles'];
const nivelDe = u => NIVEL_ROL[u.role] || 0;

/** Condicion SQL de lo que puede ver el usuario (alias r = lms_biblioteca). */
function filtroVisible(u) {
  const n = nivelDe(u);
  if (u.role === 'admin') return { sql: '1=1', args: [] };
  if (u.role === 'secretary') return { sql: '(r.curso_id IS NOT NULL OR r.nivel <= ?)', args: [n] };
  if (u.role === 'teacher') return { sql: '((r.curso_id IS NULL AND r.nivel <= ?) OR r.curso_id IN (SELECT id FROM lms_cursos WHERE docente_uid = ?))', args: [n, u.uid] };
  return { sql: '((r.curso_id IS NULL AND r.nivel <= 1) OR r.curso_id IN (SELECT curso_id FROM lms_matriculas WHERE estudiante_uid = ?))', args: [u.uid] };
}
/** Cursos para los que el usuario puede publicar. */
async function cursosPublicables(u) {
  if (u.role === 'admin' || u.role === 'secretary') return (await db.query('SELECT id, codigo, nombre FROM lms_cursos WHERE activo=1 ORDER BY nombre'))[0];
  if (u.role === 'teacher') return (await db.query('SELECT id, codigo, nombre FROM lms_cursos WHERE activo=1 AND docente_uid=? ORDER BY nombre', [u.uid]))[0];
  return [];
}
/** Valida destino: nivel (1..mi nivel) o curso permitido. Devuelve { nivel, cursoId }. */
async function destino(u, q) {
  if (u.role === 'student') throw forbidden();
  if (q.curso && q.seccion === 'libros') throw bad('Los libros digitales se publican por nivel, no por curso.');
  if (q.curso) {
    const id = int(q.curso, 'Curso', 1, 1e9);
    if (!(await cursosPublicables(u)).some(c => c.id === id)) throw bad('No puedes publicar en ese curso.');
    return { nivel: 1, cursoId: id };
  }
  const nivel = int(q.nivel, 'Quién lo ve', 1, 4);
  if (nivel > nivelDe(u)) throw bad('No puedes publicar para un nivel superior al tuyo.');
  return { nivel, cursoId: null };
}
function metaBiblio(q) {
  const base = { titulo: text(q.titulo, 'Título', 150), descripcion: text(q.descripcion, 'Descripción', 1000, { required: false }) };
  if (q.seccion === 'libros') {
    const asignatura = String(q.asignatura || ''), nivelEdu = String(q.nivel_educativo || '');
    if (!ASIGNATURAS.includes(asignatura)) throw bad('Elige la asignatura del libro.');
    if (!NIVELES_EDU.includes(nivelEdu)) throw bad('Elige el nivel educativo del libro.');
    return { ...base, seccion: 'libros', categoria: 'Libro digital', asignatura, nivelEdu,
      libroAutor: text(q.libro_autor, 'Autor del libro', 150), libroEditorial: text(q.libro_editorial, 'Editorial y año', 150, { required: false }) || null };
  }
  const categoria = String(q.categoria || '');
  if (!CATEGORIAS.includes(categoria)) throw bad('Elige una categoría.');
  return { ...base, seccion: 'recursos', categoria, asignatura: null, nivelEdu: null, libroAutor: null, libroEditorial: null };
}
async function verRecurso(u, id) {
  const f = filtroVisible(u);
  const [[r]] = await db.query(`SELECT r.* FROM lms_biblioteca r WHERE r.id = ? AND ${f.sql}`, [id, ...f.args]);
  if (!r) throw notFound();
  return r;
}

api.get('/biblioteca', auth(), wrap(async (req, res) => {
  const u = req.user, f = filtroVisible(u);
  const [rows] = await db.query(`SELECT r.id, r.seccion, r.titulo, r.descripcion, r.categoria, r.nivel, r.curso_id, c.nombre AS curso, r.tipo, r.url,
      r.libro_autor, r.libro_editorial, r.asignatura, r.nivel_educativo, r.archivo_nombre, r.archivo_bytes, r.autor_uid, r.autor_nombre, r.descargas, r.creado_en
      FROM lms_biblioteca r LEFT JOIN lms_cursos c ON c.id = r.curso_id WHERE ${f.sql} ORDER BY r.creado_en DESC LIMIT 1000`, f.args);
  const n = nivelDe(u);
  res.json({
    recursos: rows.map(r => ({ ...r, audiencia: r.curso_id ? `Curso: ${r.curso || r.curso_id}` : NIVELES[r.nivel],
      puedeBorrar: u.role === 'admin' || r.autor_uid === u.uid })),
    categorias: CATEGORIAS, asignaturas: ASIGNATURAS, nivelesEdu: NIVELES_EDU,
    puedePublicar: u.role !== 'student',
    niveles: Object.entries(NIVELES).filter(([k]) => Number(k) <= n).map(([k, v]) => ({ nivel: Number(k), nombre: v })),
    cursos: await cursosPublicables(u),
    maxMB: BIBLIO_MAX / 1048576,
  });
}));
/** Publicar un ARCHIVO: cuerpo binario + datos en la URL (como Imprimir). */
api.post('/biblioteca', auth('admin', 'secretary', 'teacher'), express.raw({ type: Object.keys(TIPOS_BIBLIO), limit: BIBLIO_MAX }), wrap(async (req, res) => {
  const u = req.user, q = req.query;
  if (!Buffer.isBuffer(req.body) || !req.body.length) throw bad('Selecciona un archivo.');
  const tipo = req.get('content-type').split(';')[0];
  const m = metaBiblio(q), d = await destino(u, q);
  const nombre = String(q.archivo || 'archivo').replace(/[^\p{L}\p{N} ._,()-]/gu, '_').slice(0, 150) || 'archivo';
  const [ins] = await db.query(`INSERT INTO lms_biblioteca (seccion, titulo, descripcion, categoria, libro_autor, libro_editorial, asignatura, nivel_educativo,
      nivel, curso_id, tipo, archivo_nombre, archivo_tipo, archivo_bytes, autor_uid, autor_nombre)
      VALUES (?,?,?,?,?,?,?,?,?,?,'archivo',?,?,?,?,?)`, [m.seccion, m.titulo, m.descripcion, m.categoria, m.libroAutor, m.libroEditorial, m.asignatura, m.nivelEdu,
      d.nivel, d.cursoId, nombre, tipo, req.body.length, u.uid, u.nombre]);
  try { await db.query('INSERT INTO lms_biblioteca_archivo (id, contenido) VALUES (?,?)', [ins.insertId, req.body.toString('base64')]); }
  catch (e) { await db.query('DELETE FROM lms_biblioteca WHERE id=?', [ins.insertId]).catch(() => {}); log('BIBLIOTECA', 'no se pudo guardar el archivo:', e.code || e.message); throw new HttpError(503, 'No se pudo guardar el archivo. Avisa a TI.'); }
  await audit(u.uid, 'BIBLIOTECA_PUBLICADO', `${m.seccion === 'libros' ? 'Libro: ' : ''}${m.titulo} (${nombre}) para ${d.cursoId ? 'el curso ' + d.cursoId : NIVELES[d.nivel]}`);
  res.json({ id: ins.insertId });
}));
/** Publicar un ENLACE (JSON). */
api.post('/biblioteca/enlace', auth('admin', 'secretary', 'teacher'), wrap(async (req, res) => {
  const u = req.user, b = req.body || {};
  const m = metaBiblio(b), d = await destino(u, b);
  const url = text(b.url, 'Enlace', 500);
  if (!/^https?:\/\/[^\s"'<>`]+$/i.test(url)) throw bad('El enlace debe empezar con http:// o https://');
  const [ins] = await db.query(`INSERT INTO lms_biblioteca (seccion, titulo, descripcion, categoria, libro_autor, libro_editorial, asignatura, nivel_educativo,
      nivel, curso_id, tipo, url, autor_uid, autor_nombre)
      VALUES (?,?,?,?,?,?,?,?,?,?,'enlace',?,?,?)`, [m.seccion, m.titulo, m.descripcion, m.categoria, m.libroAutor, m.libroEditorial, m.asignatura, m.nivelEdu,
      d.nivel, d.cursoId, url, u.uid, u.nombre]);
  await audit(u.uid, 'BIBLIOTECA_PUBLICADO', `${m.seccion === 'libros' ? 'Libro: ' : ''}${m.titulo} (enlace) para ${d.cursoId ? 'el curso ' + d.cursoId : NIVELES[d.nivel]}`);
  res.json({ id: ins.insertId });
}));
/** Descargar / abrir: PDF e imagenes se abren en el navegador; el resto se descarga. */
api.get('/biblioteca/:id/archivo', auth(), wrap(async (req, res) => {
  const r = await verRecurso(req.user, idParam(req.params.id));
  if (r.tipo !== 'archivo') throw notFound();
  const [[a]] = await db.query('SELECT contenido FROM lms_biblioteca_archivo WHERE id=?', [r.id]);
  if (!a) throw new HttpError(404, 'El archivo ya no existe.');
  await db.query('UPDATE lms_biblioteca SET descargas = descargas + 1 WHERE id=?', [r.id]).catch(() => {});
  const tipo = TIPOS_BIBLIO[r.archivo_tipo] ? r.archivo_tipo : 'application/octet-stream';
  const enLinea = ['application/pdf', 'image/jpeg', 'image/png'].includes(tipo) && req.query.descargar !== '1';
  res.setHeader('Content-Type', tipo);
  res.setHeader('Content-Disposition', `${enLinea ? 'inline' : 'attachment'}; filename="${String(r.archivo_nombre).replace(/[^\w .()-]/g, '_')}"; filename*=UTF-8''${encodeURIComponent(r.archivo_nombre)}`);
  res.setHeader('Content-Security-Policy', "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; sandbox");
  res.setHeader('Cache-Control', 'no-store');
  res.end(Buffer.from(a.contenido, 'base64'));
}));
api.delete('/biblioteca/:id', auth('admin', 'secretary', 'teacher'), wrap(async (req, res) => {
  const r = await verRecurso(req.user, idParam(req.params.id));
  if (req.user.role !== 'admin' && r.autor_uid !== req.user.uid) throw forbidden();
  await db.query('DELETE FROM lms_biblioteca_archivo WHERE id=?', [r.id]);
  await db.query('DELETE FROM lms_biblioteca WHERE id=?', [r.id]);
  await audit(req.user.uid, 'BIBLIOTECA_BORRADO', `${r.titulo}${r.autor_uid !== req.user.uid ? ' (de ' + r.autor_uid + ')' : ''}`);
  res.json({ ok: true });
}));

api.get('/auditoria', auth('admin'), wrap(async (req, res) => {
  const [rows] = await db.query('SELECT cuando, uid, accion, detalle FROM lms_auditoria ORDER BY id DESC LIMIT 200');
  res.json(rows);
}));

api.use((req, res) => res.status(404).json({ error: 'No encontrado.' }));
api.use((err, req, res, next) => {
  if (err instanceof HttpError) return res.status(err.status).json({ error: err.message });
  if (err.type === 'entity.too.large') return res.status(413).json({ error: 'El archivo es demasiado grande.' });
  if (err.type === 'entity.parse.failed') return res.status(400).json({ error: 'Solicitud no válida.' });
  log('ERROR', err.code || '', err.message);
  res.status(500).json({ error: 'Error interno. Intenta de nuevo.' });
});

// Funciona si Tailscale Serve quita el prefijo /plataforma y tambien si no.
app.use('/plataforma/api', api);
app.use('/api', api);
const estaticos = express.static(CFG.frontend, { index: 'index.html', dotfiles: 'deny' });
app.use('/plataforma', estaticos);
app.use(estaticos);
app.use((err, req, res, next) => {
  log('ERROR', err.type || err.message);
  res.status(err.status || 500).json({ error: 'Solicitud no válida.' });
});

app.listen(CFG.port, CFG.host, () => log(`EduNova escuchando en ${CFG.host}:${CFG.port}`));
