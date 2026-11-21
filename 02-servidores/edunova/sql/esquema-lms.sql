-- EduNova - tablas de la plataforma (prefijo lms_) en la base institucion.
-- Se puede ejecutar varias veces: solo crea lo que falta.
SET NAMES utf8mb4;

CREATE TABLE IF NOT EXISTS lms_cursos (
  id            INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  codigo        VARCHAR(30)  NOT NULL,
  nombre        VARCHAR(120) NOT NULL,
  asignatura    VARCHAR(120) NOT NULL DEFAULT '',
  nivel         VARCHAR(40)  NOT NULL DEFAULT '',
  paralelo      VARCHAR(10)  NOT NULL DEFAULT '',
  periodo       VARCHAR(20)  NOT NULL DEFAULT '2026-2027',
  capacidad     SMALLINT UNSIGNED NOT NULL DEFAULT 35,
  docente_uid   VARCHAR(64)  NULL,
  activo        TINYINT(1)   NOT NULL DEFAULT 1,
  creado_en     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uk_codigo (codigo),
  KEY k_docente (docente_uid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS lms_matriculas (
  curso_id       INT UNSIGNED NOT NULL,
  estudiante_uid VARCHAR(64)  NOT NULL,
  creado_en      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (curso_id, estudiante_uid),
  KEY k_estudiante (estudiante_uid),
  CONSTRAINT fk_mat_curso FOREIGN KEY (curso_id) REFERENCES lms_cursos(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS lms_actividades (
  id            INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  curso_id      INT UNSIGNED NOT NULL,
  titulo        VARCHAR(150) NOT NULL,
  descripcion   TEXT         NOT NULL,
  tipo          VARCHAR(20)  NOT NULL DEFAULT 'tarea',
  fecha_limite  DATETIME     NOT NULL,
  puntaje_max   DECIMAL(5,2) NOT NULL DEFAULT 10.00,
  creado_por    VARCHAR(64)  NOT NULL,
  creado_en     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY k_curso (curso_id),
  CONSTRAINT fk_act_curso FOREIGN KEY (curso_id) REFERENCES lms_cursos(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS lms_entregas (
  actividad_id   INT UNSIGNED NOT NULL,
  estudiante_uid VARCHAR(64)  NOT NULL,
  contenido      TEXT         NULL,
  entregado_en   DATETIME     NULL,
  nota           DECIMAL(5,2) NULL,
  comentario     VARCHAR(500) NULL,
  calificado_por VARCHAR(64)  NULL,
  calificado_en  DATETIME     NULL,
  PRIMARY KEY (actividad_id, estudiante_uid),
  KEY k_est (estudiante_uid),
  CONSTRAINT fk_ent_act FOREIGN KEY (actividad_id) REFERENCES lms_actividades(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS lms_anuncios (
  id         INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  curso_id   INT UNSIGNED NOT NULL,
  autor_uid  VARCHAR(64)  NOT NULL,
  titulo     VARCHAR(150) NOT NULL,
  cuerpo     TEXT         NOT NULL,
  creado_en  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY k_curso (curso_id),
  CONSTRAINT fk_anu_curso FOREIGN KEY (curso_id) REFERENCES lms_cursos(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS lms_auditoria (
  id       BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  cuando   DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  uid      VARCHAR(64) NOT NULL,
  accion   VARCHAR(40) NOT NULL,
  detalle  VARCHAR(500) NOT NULL DEFAULT '',
  KEY k_cuando (cuando)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Ponderacion por tipo de actividad (la define el docente; suma 100 %).
CREATE TABLE IF NOT EXISTS lms_ponderaciones (
  curso_id  INT UNSIGNED NOT NULL,
  tipo      VARCHAR(20)  NOT NULL,
  peso      DECIMAL(5,2) NOT NULL,
  PRIMARY KEY (curso_id, tipo),
  CONSTRAINT fk_pon_curso FOREIGN KEY (curso_id) REFERENCES lms_cursos(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Impresiones enviadas desde la plataforma (cupo diario por rol).
CREATE TABLE IF NOT EXISTS lms_impresiones (
  id           INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  uid          VARCHAR(64)  NOT NULL,
  trabajo      INT UNSIGNED NOT NULL,
  impresora    VARCHAR(127) NOT NULL,
  documento    VARCHAR(100) NOT NULL,
  paginas      SMALLINT UNSIGNED NOT NULL,
  paginas_doc  SMALLINT UNSIGNED NOT NULL,
  copias       TINYINT UNSIGNED NOT NULL DEFAULT 1,
  color        TINYINT(1)   NOT NULL DEFAULT 0,
  cancelado    TINYINT(1)   NOT NULL DEFAULT 0,
  creado_en    DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY k_uid_fecha (uid, creado_en),
  KEY k_fecha (creado_en)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Grupo de impresion (impresoras que usan estudiantes y docentes).
CREATE TABLE IF NOT EXISTS lms_impresoras_pool (
  nombre     VARCHAR(127) NOT NULL PRIMARY KEY,
  color      TINYINT(1)   NOT NULL DEFAULT 0,
  activa     TINYINT(1)   NOT NULL DEFAULT 1,
  creado_en  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Copia del documento impreso (solo administracion la ve; se borra a los N dias).
ALTER TABLE lms_impresiones ADD COLUMN IF NOT EXISTS archivo VARCHAR(80) NULL;

-- Impresion diferida: documentos en espera cuando la plataforma la atiende el servidor de respaldo.
ALTER TABLE lms_impresiones ADD COLUMN IF NOT EXISTS diferido TINYINT(1) NOT NULL DEFAULT 0;
CREATE TABLE IF NOT EXISTS lms_impresion_pendiente (
  id        INT UNSIGNED NOT NULL PRIMARY KEY,
  tipo      VARCHAR(40)  NOT NULL,
  rango     VARCHAR(100) NULL,
  contenido LONGTEXT     NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=ascii;
