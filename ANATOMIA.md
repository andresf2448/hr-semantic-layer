# Anatomía de un módulo semántico

Referencia de los archivos de `definitions/`: qué declara cada campo, qué
nombres son libres y cuáles son vocabulario del motor, y la receta para
escribir un módulo nuevo desde cero.

Complementa a los otros dos documentos del repositorio: el
[README](README.md) explica qué es la capa y cómo usarla, y [FLUJO.md](FLUJO.md)
recorre una consulta completa paso a paso. Este archivo se queda en un solo
punto: **el archivo de definiciones**.

---

## 1. Toda tabla es una de dos cosas

El método se llama **modelado dimensional** (Kimball). La prueba cabe en una
pregunta: *¿esta fila **pasó**, o esta fila **es**?*

| | Tabla de HECHOS | Tabla de DIMENSIONES |
|---|---|---|
| Una fila es | un evento medible que ocurrió | algo que existe |
| Tiene | fecha y valores agregables | atributos descriptivos |
| Crece | indefinidamente | poco |
| Responde al | *cuánto* | *de quién / de dónde* |
| En este proyecto | `performance_reviews`, `attendance` | `departments`, `employees` (y `companies`, que existe en el esquema pero no se declara como entidad: ver §4) |

De ahí sale la organización de `definitions/`:

> **Un módulo = el equipo dueño de una tabla de hechos, con su propio archivo.
> Las dimensiones que usa más de un módulo viven en `core.yml`.**

La prueba para decidir: *si este módulo desapareciera, ¿los otros seguirían
necesitando esta tabla?* Si sí, va a `core`.

**Trampa frecuente:** "es dimensión" **no** significa "va a `core`". Una
dimensión que solo usa su propio módulo se queda con él. `core` es para las
**compartidas**.

---

## 2. El archivo, campo por campo

```yaml
# ①
module: performance
# ②
owner: equipo-desempeno

# ③
entities:
  # ④
  reviews:
    # ⑤
    table: performance_reviews
    # ⑥
    tenant_key: company_id

    # ⑦
    relationships:
      - name: employee              # libre: solo aparece en mensajes de error
        type: many_to_one           # único valor que el resolvedor recorre
        entity: core.employees      # debe existir, exactamente así
        foreign_key: employee_id    # columna real de ESTA tabla
        references: id              # columna real de la OTRA tabla

    # ⑧
    dimensions:
      review_period:                # término del vocabulario de negocio
        column: period
        type: time
        granularities: [quarter, month, year]
        label: "Periodo evaluado"

    # ⑨
    filters:
      completed:                    # local a esta entidad
        expression: "{{table}}.status = 'completed'"

    # ⑩
    metrics:
      completed_reviews:
        type: count
        filters: [completed]
        label: "Evaluaciones completadas"
      completion_rate:
        type: derived
        formula: "completed_reviews / total_reviews * 100"
        unit: percent
```

| # | Campo | ¿Obligatorio? | En qué se convierte | Quién lo lee |
|---|---|---|---|---|
| ① | `module` | **Sí** | El prefijo del nombre: `performance.reviews` | `catalog/loader.rb` |
| ② | `owner` | No | Nada: documentación estructurada | nadie |
| ③ | `entities` | **Sí** | Una entidad consultable por clave | `catalog/loader.rb` |
| ④ | *clave de entidad* | **Sí** | El alias del SQL: `FROM performance_reviews reviews` | `JoinResolver.alias_for` |
| ⑤ | `table` | **Sí** | El `FROM` | `engine/sql_compiler.rb` |
| ⑥ | `tenant_key` | **Sí, sin default** | `WHERE reviews.company_id = $1` | `engine/sql_compiler.rb` |
| ⑦ | `relationships` | Si hace falta JOIN | `INNER JOIN ... ON ...` | `engine/join_resolver.rb` |
| ⑧ | `dimensions` | No | `SELECT` + `GROUP BY`, y el `WHERE` del consumidor | `engine/sql_compiler.rb`; su `label` y sus `granularities`, `catalog/registry.rb` → `llm/tool_schema.rb` |
| ⑨ | `filters` | No | `FILTER (WHERE ...)` pegado a una métrica | `engine/sql_compiler.rb` |
| ⑩ | `metrics` | No | Las agregaciones del `SELECT` | `engine/sql_compiler.rb`; su `label` y su `unit`, `catalog/registry.rb` → `llm/tool_schema.rb` |

### Claves de estructura vs. nombres propios

Hay dos tipos de clave en el YAML y conviene no confundirlos.

**Claves de estructura.** El loader las busca por su nombre literal, así que
escribir `tabla` en vez de `table` deja el campo en `nil`:

`module` · `entities` · `table` · `tenant_key` · `relationships` ·
`dimensions` · `metrics` · `filters` · `name` · `type` · `entity` ·
`foreign_key` · `references` · `column` · `granularities` · `label` ·
`formula` · `unit` · `expression`

Las que el validador exige —`module`, `table`, `tenant_key`, `column`,
`foreign_key`, `formula` en las derivadas— hacen fallar el arranque. Las demás
tienen valor por defecto (`type` de dimensión es `string`, `type` de relación
es `many_to_one`, `references` es `id`, `label` toma el nombre técnico) o
simplemente quedan vacías, así que un error de tipeo ahí se manifiesta más
tarde. `owner` no lo lee nadie: no aparece en esta lista porque el loader ni
siquiera lo busca.

**Nombres propios.** Son los que se inventan al declarar, y se convierten en
el vocabulario que ve el consumidor: la clave de la entidad, y las claves de
cada dimensión, métrica y filtro.

> Las claves de estructura son vocabulario del motor. Las que se inventan son
> vocabulario del negocio.

---

## 3. Los valores que no se pueden inventar

| Campo | Valores admitidos | Consecuencia |
|---|---|---|
| `type` de métrica | `count`, `sum`, `avg`, `min`, `max`, `derived` | `sum`, `avg`, `min` y `max` exigen `column`; `count` y `derived` no |
| `type` de dimensión | cualquiera; solo `time` cambia el comportamiento | `time` habilita `granularities` y las exige |
| `granularities` | `day`, `week`, `month`, `quarter`, `year` | Se traducen a `DATE_TRUNC('...', col)::date` |
| `type` de relación | `many_to_one` (es el default) | Es el único que el resolvedor recorre |

### Por qué solo `many_to_one`

Recorrer hacia el lado "muchos" duplica las filas de la tabla base, y toda
agregación sobre ella queda inflada. El resolvedor no *puede* producir fan-out
porque no sabe caminar en esa dirección.

```
employees → departments (many_to_one)     departments → employees (one_to_many)
  Ana   + Ingeniería                        Ingeniería + Ana      ← Ingeniería
  Luis  + Ingeniería                        Ingeniería + Luis     ← aparece dos veces
  Carla + Ventas                            Ventas     + Carla
  Jorge + Ventas                            Ventas     + Jorge

4 empleados → 4 filas  ✓                  2 departamentos → 4 filas  ✗
```

Una relación declarada al revés simplemente se ignora: la consulta falla
cerrado (*"there is no way to relate X to Y"*) en vez de devolver un número
mal calculado.

---

## 4. Tres alcances de nombres

| Qué | Alcance | Por qué |
|---|---|---|
| Métricas y dimensiones | **Global** | El consumidor las nombra directamente en el JSON: dos iguales serían ambiguas |
| Alias de entidad | **Global** | El alias del SQL es solo la parte corta: dos iguales producen SQL ambiguo |
| Filtros con nombre | **Local a la entidad** | El consumidor nunca los nombra; solo los referencia una métrica de la misma entidad |

Consecuencia práctica: dos módulos pueden tener cada uno su filtro `completed`
sin chocar, pero no dos métricas `completion_rate`.

---

## 5. Dimensiones y filtros no son lo mismo

Una **dimensión** es un término del vocabulario que el consumidor puede
nombrar. Agrupar y filtrar son las dos cosas que puede hacer con él:

```jsonc
// agrupar por ella  ->  GROUP BY
"dimensions": ["employee_active"]

// filtrar por ella  ->  WHERE
"filters": [{ "dimension": "employee_active", "operator": "eq", "values": [true] }]
```

Nótese la clave `"dimension"` dentro del filtro: un filtro del consumidor se
apoya en una dimensión. **No se puede filtrar por algo que no esté declarado
como dimensión.**

El bloque `filters:` del YAML es otra cosa:

| | `dimensions:` (YAML) | `filters:` (YAML) |
|---|---|---|
| Qué es | Un término que el consumidor puede nombrar | Una condición fija con nombre |
| Quién lo usa | El consumidor, en su JSON | Una métrica de la misma entidad |
| A dónde va en el SQL | `GROUP BY` o `WHERE` | `FILTER (WHERE ...)` pegado a una agregación |
| Cuándo aplica | Cuando el consumidor lo pide | Siempre: es parte de qué significa la métrica |

`completed_reviews` significa "completadas" siempre, para todos los
consumidores: por eso vive en el YAML. "Solo empleados activos" es una decisión
de quien pregunta hoy: por eso viaja en la consulta.

### El placeholder `{{table}}`

Quien escribe el YAML no sabe con qué alias va a aparecer su tabla en el SQL
final: eso lo decide el resolvedor de joins mucho después.

```
YAML:       expression: "{{table}}.status = 'completed'"
                             ↓
SQL final:  COUNT(*) FILTER (WHERE reviews.status = 'completed')
```

Escribir el nombre de la tabla a mano duplicaría un dato que ya está en
`table:`, y omitir el prefijo rompería la consulta apenas dos tablas del JOIN
compartan un nombre de columna.

---

## 6. Receta: escribir un módulo desde cero

El orden importa: no se pueden nombrar dimensiones antes de saber qué entidades
hay, ni escribir métricas antes de tener los filtros que usan.

**1. Clasificar cada tabla.** *¿Esta fila pasó, o esta fila es?* Hecho o
dimensión. Ninguna otra decisión tiene sentido antes de esta.

**2. Decidir dónde vive cada una.** La tabla de hechos define el módulo. Para
cada dimensión: *¿la necesitarían los otros módulos si este desapareciera?*
Sí → `core.yml`. No → se queda en este módulo.

**3. Nombrar módulo y entidades.** Un archivo `definitions/<modulo>.yml`.
Verificar que ningún alias de entidad choque con los existentes.

**4. Declarar el par no negociable.** Por cada entidad, `table` y
`tenant_key`. Sin lo segundo el catálogo no arranca: no hay default, a
propósito.

**5. Relaciones, del hecho hacia afuera.** Siempre `many_to_one`, siempre
desde la tabla de hechos. Al apuntar a `core.employees` se hereda todo `core`:
se puede agrupar por `department` sin declarar nada de departamentos, porque
el BFS encuentra el camino.

**6. Dimensiones: descartar, no elegir.** Columna por columna:

- identificadores y claves foráneas → fuera, son plomería
- la columna de tenant → nunca, es el eje que controla el motor
- ¿se suma o se promedia? → es una *medida*, materia prima de métricas
- lo que queda → dimensión

**7. Filtros con nombre.** Condiciones que forman parte de la *definición* de
una métrica. Usar `{{table}}`.

**8. Métricas.** Base primero, derivadas después. Toda métrica que no sea
`count` declara `column`; toda derivada solo puede referenciar métricas que
existan, sin ciclos.

**9. Arrancar y leer los errores.** El validador junta **todos** los errores y
los reporta juntos, así que se arregla todo en una pasada.

### Lo que no hay que hacer

Cero líneas en `engine/`, `catalog/`, `tenancy/` o `llm/`. Cero cambios en los
otros archivos de `definitions/`. Cero SQL escrito. Y el adaptador de lenguaje
natural sabe preguntar por el módulo nuevo de inmediato, porque el listado del
catálogo se regenera en cada llamada.

`definitions/attendance.yml` es exactamente eso: un módulo agregado después de
`performance.yml`, sin modificar ni una línea del anterior ni del motor.

---

## 7. Ejemplo completo: el módulo de Cursos

Supongamos que el equipo de Capacitación quiere exponer sus datos. Estas son
sus tablas (el ejemplo es hipotético: no está implementado en este
repositorio).

```sql
CREATE TABLE courses (
  id         BIGSERIAL PRIMARY KEY,
  company_id BIGINT NOT NULL,
  name       TEXT NOT NULL,
  category   TEXT NOT NULL      -- 'técnico', 'liderazgo', 'compliance'
);

CREATE TABLE course_enrollments (
  id           BIGSERIAL PRIMARY KEY,
  company_id   BIGINT NOT NULL,
  employee_id  BIGINT NOT NULL REFERENCES employees(id),
  course_id    BIGINT NOT NULL REFERENCES courses(id),
  enrolled_at  DATE NOT NULL,
  status       TEXT NOT NULL,   -- 'enrolled', 'completed', 'dropped'
  progress_pct INTEGER NOT NULL DEFAULT 0
);
```

### Paso 1 — Clasificar cada tabla

*¿Esta fila pasó, o esta fila es?*

- `course_enrollments` → una inscripción **pasó** en una fecha, tiene
  `progress_pct` agregable y crece sin parar → **tabla de hechos**.
- `courses` → un curso **es**; describe y clasifica inscripciones →
  **tabla de dimensiones**.

### Paso 2 — Decidir dónde vive cada una

`course_enrollments` es la tabla de hechos: define el módulo.

Para `courses` aplica la prueba: *si el módulo de Cursos desapareciera,
¿Desempeño y Asistencia seguirían necesitando esta tabla?* No, nadie más la
usa. Entonces **se queda en el módulo**, no va a `core`. Ser una dimensión no
la manda a `core`; solo van ahí las **compartidas**.

### Paso 3 — Nombrar módulo y entidades

Archivo `definitions/training.yml`, con `module: training` y dos entidades:
`enrollments` y `courses`. Ninguno de esos alias choca con los existentes
(`employees`, `departments`, `reviews`, `attendance_records`).

### Paso 4 — El par no negociable

Cada entidad declara `table` y `tenant_key`. Sin lo segundo el catálogo no
arranca.

### Paso 5 — Relaciones, del hecho hacia afuera

La tabla de hechos apunta a sus dimensiones, nunca al revés:

- `enrollments` → `core.employees` por `employee_id`
- `enrollments` → `training.courses` por `course_id`

Al declarar la primera, el módulo **hereda todo `core`**: se puede agrupar por
`department` sin declarar nada de departamentos, porque el resolvedor encuentra
el camino `enrollments → employees → departments`.

### Paso 6 — Dimensiones: descartar, no elegir

`course_enrollments`, columna por columna:

| Columna | ¿Dimensión? | Por qué |
|---|---|---|
| `id` | no | Identificador técnico: plomería |
| `company_id` | no | Es el tenant: lo controla el motor, no el consumidor |
| `employee_id`, `course_id` | no | Claves foráneas: son el *cómo se llega*, no el *qué se muestra* |
| `enrolled_at` | **sí** | Dimensión temporal |
| `status` | **sí** | Categoría |
| `progress_pct` | no | Se promedia: es una **medida**, materia prima de métricas |

`courses`: `id` y `company_id` fuera; `name` y `category` quedan.

**Sobre los nombres.** `status` y `name` cargarían sin error —la unicidad se
comprueba sobre el nombre completo, y no existe ninguna dimensión llamada así
en el catálogo—, pero serían pésimos términos de vocabulario: el consumidor
pide `"dimensions": ["status"]` sin saber de qué. Los nombres quedan
`enrollment_status`, `course_name` y `course_category`. Donde la unicidad
global **sí** muerde es en la métrica derivada: `completion_rate` ya existe,
así que tiene que ser `course_completion_rate`.

### Paso 7 y 8 — Filtros y métricas

El filtro sí puede llamarse `completed` aunque `performance.reviews` ya tenga
uno con ese nombre: los filtros son **locales a su entidad**.

La métrica derivada, en cambio, no puede llamarse `completion_rate`: ese
nombre ya lo registra `performance.reviews` y el validador rechaza el catálogo
con *"name 'completion_rate' is declared in more than one entity"*. Queda
`course_completion_rate`.

### El archivo terminado

```yaml
module: training
owner: equipo-capacitacion

entities:
  enrollments:
    table: course_enrollments
    tenant_key: company_id

    relationships:
      - name: employee
        type: many_to_one
        entity: core.employees
        foreign_key: employee_id
        references: id
      - name: course
        type: many_to_one
        entity: training.courses
        foreign_key: course_id
        references: id

    dimensions:
      enrollment_date:
        column: enrolled_at
        type: time
        granularities: [month, quarter, year]
        label: "Fecha de inscripción"
      enrollment_status:
        column: status
        type: string
        label: "Estado de la inscripción"

    filters:
      completed:
        expression: "{{table}}.status = 'completed'"

    metrics:
      total_enrollments:
        type: count
        label: "Inscripciones totales"
      completed_courses:
        type: count
        filters: [completed]
        label: "Cursos completados"
      avg_course_progress:
        type: avg
        column: progress_pct
        unit: percent
        label: "Progreso promedio"
      course_completion_rate:
        type: derived
        formula: "completed_courses / total_enrollments * 100"
        unit: percent
        label: "Tasa de finalización de cursos"

  courses:
    table: courses
    tenant_key: company_id

    dimensions:
      course_name:
        column: name
        type: string
        label: "Curso"
      course_category:
        column: category
        type: string
        label: "Categoría del curso"
```

### Lo que se obtiene sin escribir una línea más

Un consumidor puede pedir esto de inmediato:

```json
{
  "metrics": ["course_completion_rate"],
  "dimensions": ["department", "course_category"]
}
```

Y el motor genera solo este SQL, cruzando un módulo nuevo con dimensiones que
pertenecen a otro:

```sql
WITH base AS (
  SELECT
    departments.name AS department,
    courses.category AS course_category,
    COUNT(*) FILTER (WHERE enrollments.status = 'completed') AS m_completed_courses,
    COUNT(*) AS m_total_enrollments
  FROM course_enrollments enrollments
  INNER JOIN employees employees
    ON employees.id = enrollments.employee_id
   AND employees.company_id = enrollments.company_id
  INNER JOIN departments departments
    ON departments.id = employees.department_id
   AND departments.company_id = employees.company_id
  INNER JOIN courses courses
    ON courses.id = enrollments.course_id
   AND courses.company_id = enrollments.company_id
  WHERE enrollments.company_id = $1
  GROUP BY 1, 2
)
SELECT
  department,
  course_category,
  ((m_completed_courses::numeric / NULLIF(m_total_enrollments, 0)) * 100) AS course_completion_rate
FROM base
LIMIT $2
```

Y el adaptador de lenguaje natural responde `bundle exec ruby bin/ask "tasa de
finalización de cursos por departamento"` sin que se haya tocado ningún
prompt: el listado del catálogo que recibe el modelo se regenera en cada
llamada.

**Lo único que no es automático:** una consulta que mezcle
`course_completion_rate` con `avg_performance_score` sería rechazada, porque
son dos tablas de hechos distintas. Es la limitación multi-CTE documentada en
el README.

---

## 8. Checklist antes de arrancar

- [ ] `module` declarado en el archivo *(lo verifica el loader, y aborta en el primer archivo que falle)*
- [ ] cada entidad con `table` **y** `tenant_key`
- [ ] alias de entidad únicos en todo el catálogo
- [ ] cada `relationship` apunta a una entidad que existe, con `foreign_key`
- [ ] nombres de métricas y dimensiones únicos globalmente
- [ ] tipos de métrica dentro de `count`, `sum`, `avg`, `min`, `max`, `derived`
- [ ] las de tipo `sum`, `avg`, `min` o `max` declaran `column`
- [ ] toda dimensión declara `column`; las `time`, `granularities` válidas
- [ ] cada métrica usa filtros declarados en su propia entidad
- [ ] toda métrica `derived` declara `formula`
- [ ] las fórmulas derivadas referencian métricas existentes, sin ciclos

**Lo que no se valida:** que `table`, `column`, `foreign_key` y `references`
existan de verdad en la base de datos. El catálogo no introspecciona
PostgreSQL, así que un nombre mal escrito ahí falla en la primera consulta, no
al arrancar. Verificarlo contra `information_schema` al cargar sería la mejora
natural.
