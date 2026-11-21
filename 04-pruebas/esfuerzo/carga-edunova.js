// =====================================================================
//  PRUEBAS DE ESFUERZO - Paso 2: carga sobre EduNova (se ejecuta con k6 desde una PC de administracion)
//  Simula estudiantes (est001..est200) y docentes (doc01..doc50) usando la plataforma a la vez:
//   Estudiante: inicia sesion, resumen, mis cursos, abre un curso, a veces entrega una tarea,
//               biblioteca, a veces descarga el PDF, mis notas. Piensa 3-8 s entre vueltas.
//   Docente:    inicia sesion, sus cursos, abre un curso, revisa entregas y a veces pone una nota.
//  La carga sube por escalones (25% -> 50% -> 100% de MAX) para ver donde empieza a sufrir.
//  Variables:  URL   = direccion de EduNova tal como la abres en el navegador (sin /api)
//              CLAVE = clave comun de las cuentas de prueba
//              MAX   = estudiantes simultaneos al final (por defecto 100, maximo 200)
// =====================================================================
import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Trend, Counter } from 'k6/metrics';

const BASE = String(__ENV.URL || '').trim().replace(/\/+$/, '');
const CLAVE = String(__ENV.CLAVE || '').trim();
const MAX = Math.min(200, Math.max(4, Number(String(__ENV.MAX || 100).trim())));
if (!BASE || !CLAVE) throw new Error('Faltan URL o CLAVE (usa ejecutar-prueba.bat).');
const API = `${BASE}/api`;
const DOCENTES = Math.max(2, Math.round(MAX / 8));
const esc = n => Math.max(1, Math.round(MAX * n));
const CORTA = __ENV.CORTA === '1';                  // prueba corta de diagnostico (~1,5 min)
const T = (m) => CORTA ? `${Math.max(5, Math.round(m * 9))}s` : `${m}m`;

const tLogin = new Trend('login_ms', true);
const tPagina = new Trend('pagina_ms', true);
const tDescarga = new Trend('descarga_ms', true);
const entregas = new Counter('entregas_enviadas');
const notas = new Counter('notas_puestas');

export const options = {
  scenarios: {
    estudiantes: {
      executor: 'ramping-vus', exec: 'estudiante', startVUs: 0, gracefulRampDown: '20s',
      stages: [
        { duration: T(1), target: esc(0.25) }, { duration: T(2), target: esc(0.25) },
        { duration: T(1), target: esc(0.5) }, { duration: T(2), target: esc(0.5) },
        { duration: T(1), target: MAX }, { duration: T(3), target: MAX },
        { duration: T(0.5), target: 0 },
      ],
    },
    docentes: { executor: 'constant-vus', exec: 'docente', vus: DOCENTES, duration: T(10) },
  },
  thresholds: {
    http_req_failed: ['rate<0.02'],          // menos del 2% de errores
    pagina_ms: ['p(95)<2000'],               // 95% de las paginas en menos de 2 s
    login_ms: ['p(95)<3000'],                // 95% de los inicios de sesion en menos de 3 s
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'max'],
  noCookiesReset: true,                    // la sesion (cookie) se mantiene entre vueltas, como en un navegador real
};

const JSONH = { headers: { 'Content-Type': 'application/json' } };
const ok400 = { responseCallback: http.expectedStatuses({ min: 200, max: 299 }, 400) };
const azar = a => a[Math.floor(Math.random() * a.length)];
const pausa = (a, b) => sleep(a + Math.random() * (b - a));
let sesion = false, vueltas = 0;

function login(uid) {
  const r = http.post(`${API}/login`, JSON.stringify({ username: uid, password: CLAVE }), { ...JSONH, tags: { paso: 'login' } });
  tLogin.add(r.timings.duration);
  sesion = check(r, { 'login 200': x => x.status === 200 });
  if (!sesion && vueltas === 0) console.warn(`${uid}: login ${r.status} ${String(r.body).slice(0, 120)}`);
  return sesion;
}
let avisos = 0;
function get(path, paso) {
  const r = http.get(`${API}${path}`, { tags: { paso } });
  tPagina.add(r.timings.duration);
  if (r.status !== 200 && avisos < 3) { avisos++; console.warn(`VU ${__VU} vuelta ${vueltas} ${paso}: HTTP ${r.status} ${r.error || ''} ${String(r.body || '').slice(0, 90).replace(/\s+/g, ' ')}`); }
  if (r.status === 401) sesion = false;
  check(r, { [`${paso} 200`]: x => x.status === 200 });
  try { return r.status === 200 ? r.json() : null; } catch (e) { return null; }
}

export function estudiante() {
  const uid = `est${String(((__VU - 1) % 200) + 1).padStart(3, '0')}`;
  vueltas++;
  if (!sesion || vueltas % 15 === 0) { if (!login(uid)) { pausa(5, 10); return; } }
  group('estudiante', () => {
    get('/resumen', 'resumen');
    const cursos = get('/cursos', 'cursos');
    if (Array.isArray(cursos) && cursos.length) {
      const det = get(`/cursos/${azar(cursos).id}`, 'curso');
      const acts = (det && det.actividades || []).filter(a => !Number(a.vencida));
      if (acts.length && Math.random() < 0.25) {
        const r = http.post(`${API}/actividades/${azar(acts).id}/entrega`,
          JSON.stringify({ contenido: `Entrega de prueba de ${uid} - ${new Date().toISOString()}` }),
          { ...JSONH, ...ok400, tags: { paso: 'entrega' } });
        tPagina.add(r.timings.duration);
        if (r.status === 200 || r.status === 201) entregas.add(1);
      }
    }
    const bib = get('/biblioteca', 'biblioteca');
    const pdf = bib && (bib.recursos || []).find(x => x.tipo === 'archivo');
    if (pdf && Math.random() < 0.3) {
      const r = http.get(`${API}/biblioteca/${pdf.id}/archivo?descargar=1`, { tags: { paso: 'descarga' } });
      tDescarga.add(r.timings.duration);
      check(r, { 'descarga 200': x => x.status === 200 });
    }
    get('/mis-notas', 'notas');
  });
  pausa(3, 8);
}

export function docente() {
  const uid = `doc${String(((__VU - 1) % 50) + 1).padStart(2, '0')}`;
  vueltas++;
  if (!sesion || vueltas % 15 === 0) { if (!login(uid)) { pausa(5, 10); return; } }
  group('docente', () => {
    const cursos = get('/cursos', 'cursos');
    if (!Array.isArray(cursos) || !cursos.length) return;
    const det = get(`/cursos/${azar(cursos).id}`, 'curso');
    const acts = det && det.actividades || [];
    if (!acts.length) return;
    const a = azar(acts);
    const ent = get(`/actividades/${a.id}/entregas`, 'entregas');
    const pend = (ent && ent.entregas || []).filter(e => e.entregado_en && e.nota === null);
    if (pend.length && Math.random() < 0.3) {
      const e = azar(pend);
      const r = http.put(`${API}/actividades/${a.id}/notas/${e.uid}`,
        JSON.stringify({ nota: Math.round(Math.random() * 10), comentario: 'Nota de prueba' }), { ...JSONH, tags: { paso: 'nota' } });
      tPagina.add(r.timings.duration);
      if (check(r, { 'nota 200': x => x.status === 200 })) notas.add(1);
    }
  });
  pausa(5, 10);
}
