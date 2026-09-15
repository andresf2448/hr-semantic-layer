CREATE TABLE companies (
  id   BIGINT PRIMARY KEY,
  name TEXT NOT NULL
);

CREATE TABLE departments (
  id         BIGINT PRIMARY KEY,
  company_id BIGINT NOT NULL REFERENCES companies(id),
  name       TEXT NOT NULL
);

CREATE TABLE employees (
  id            BIGINT PRIMARY KEY,
  company_id    BIGINT NOT NULL REFERENCES companies(id),
  department_id BIGINT NOT NULL REFERENCES departments(id),
  name          TEXT NOT NULL,
  hire_date     DATE NOT NULL,
  active        BOOLEAN NOT NULL DEFAULT TRUE
);

-- Un registro por evaluación de desempeño.
-- Puede existir más de una evaluación por empleado durante un año.
CREATE TABLE performance_reviews (
  id          BIGINT PRIMARY KEY,
  employee_id BIGINT NOT NULL REFERENCES employees(id),
  company_id  BIGINT NOT NULL,
  period      DATE NOT NULL,
  score       NUMERIC(4,2) NOT NULL,
  status      TEXT NOT NULL, -- 'pending', 'completed', 'calibrated'

  CHECK (status IN ('pending', 'completed', 'calibrated'))
);

-- Un registro por día y empleado.
CREATE TABLE attendance (
  id          BIGINT PRIMARY KEY,
  employee_id BIGINT NOT NULL REFERENCES employees(id),
  company_id  BIGINT NOT NULL,
  date        DATE NOT NULL,
  present     BOOLEAN NOT NULL,

  UNIQUE (employee_id, date)
);

-- Índices: toda consulta de la capa semántica filtra siempre por
-- company_id (aislamiento obligatorio). El contexto técnico del
-- enunciado (sección 7) indica empresas de hasta 50.000 empleados; sin
-- estos índices, el costo de cada consulta crecería con el total de
-- filas de TODAS las empresas, no con el tamaño de la empresa que
-- consulta.
CREATE INDEX idx_departments_company_id  ON departments(company_id);
CREATE INDEX idx_employees_company_id    ON employees(company_id);
CREATE INDEX idx_employees_department_id ON employees(department_id);
CREATE INDEX idx_reviews_company_id      ON performance_reviews(company_id);
CREATE INDEX idx_reviews_employee_id     ON performance_reviews(employee_id);
CREATE INDEX idx_reviews_period          ON performance_reviews(period);
CREATE INDEX idx_attendance_company_id   ON attendance(company_id);
CREATE INDEX idx_attendance_date         ON attendance(date);