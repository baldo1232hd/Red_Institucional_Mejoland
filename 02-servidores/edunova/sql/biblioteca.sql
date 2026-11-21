-- EduNova - tablas de la Biblioteca institucional (los archivos se guardan en la base y se replican).
CREATE TABLE IF NOT EXISTS lms_biblioteca (
  id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  titulo VARCHAR(150) NOT NULL,
  descripcion VARCHAR(1000) NOT NULL DEFAULT '',
  categoria VARCHAR(60) NOT NULL,
  nivel TINYINT UNSIGNED NOT NULL DEFAULT 1 COMMENT '1 institucion, 2 personal, 3 secretaria+admin, 4 solo admin',
  curso_id INT UNSIGNED NULL COMMENT 'si no es NULL: solo ese curso',
  tipo ENUM('archivo','enlace') NOT NULL,
  url VARCHAR(500) NULL,
  archivo_nombre VARCHAR(160) NULL,
  archivo_tipo VARCHAR(120) NULL,
  archivo_bytes INT UNSIGNED NOT NULL DEFAULT 0,
  autor_uid VARCHAR(64) NOT NULL,
  autor_nombre VARCHAR(150) NOT NULL,
  descargas INT UNSIGNED NOT NULL DEFAULT 0,
  creado_en DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY idx_nivel (nivel), KEY idx_curso (curso_id), KEY idx_autor (autor_uid)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE IF NOT EXISTS lms_biblioteca_archivo (
  id INT UNSIGNED NOT NULL PRIMARY KEY,
  contenido LONGTEXT CHARACTER SET ascii NOT NULL
) ENGINE=InnoDB;
-- Biblioteca: dos secciones (libros digitales / recursos de estudio)
ALTER TABLE lms_biblioteca
  ADD COLUMN IF NOT EXISTS seccion ENUM('recursos','libros') NOT NULL DEFAULT 'recursos' AFTER id,
  ADD COLUMN IF NOT EXISTS libro_autor VARCHAR(150) NULL AFTER categoria,
  ADD COLUMN IF NOT EXISTS libro_editorial VARCHAR(150) NULL AFTER libro_autor,
  ADD COLUMN IF NOT EXISTS asignatura VARCHAR(80) NULL AFTER libro_editorial,
  ADD COLUMN IF NOT EXISTS nivel_educativo VARCHAR(30) NULL AFTER asignatura,
  ADD INDEX IF NOT EXISTS idx_seccion (seccion, asignatura);
