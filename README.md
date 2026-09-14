# Capa Semántica de Analítica

Una capa de abstracción que traduce preguntas de negocio declarativas en SQL
correcto y aislado por empresa, sin que ningún consumidor tenga que conocer
las tablas.

> Reto técnico para el proceso de Software Engineer en Buk.

---

## Contenido

1. [El problema](#el-problema)
2. [Qué es y qué no es](#qué-es-y-qué-no-es)
3. [Arranque rápido](#arranque-rápido)
4. [Arquitectura](#arquitectura)
5. [Cómo declara un módulo sus datos](#cómo-declara-un-módulo-sus-datos)
6. [Cómo consulta un consumidor](#cómo-consulta-un-consumidor)
7. [Aislamiento entre empresas](#aislamiento-entre-empresas)
8. [Métricas derivadas](#métricas-derivadas)
9. [Adaptador de lenguaje natural (opcional)](#adaptador-de-lenguaje-natural-opcional)
10. [Preguntas de ejemplo](#preguntas-de-ejemplo)
11. [Qué se puede pedir](#qué-se-puede-pedir)
12. [Agregar un módulo nuevo](#agregar-un-módulo-nuevo)
13. [Limitaciones conocidas](#limitaciones-conocidas)
14. [Tests](#tests)

Ver también **[FLUJO.md](FLUJO.md)** (el recorrido de una consulta paso a
paso) y **[ANATOMIA.md](ANATOMIA.md)** (referencia del formato de
`definitions/`).

---

## El problema

Cada módulo de la plataforma (Desempeño, Asistencia, Cursos, Tiempo libre)
tiene sus propias tablas y su propia lógica de consulta. Cuando un equipo
necesita datos de otro módulo, escribe SQL directo contra sus tablas. Eso
genera tres problemas:

- **Acoplamiento** — renombrar una columna rompe consultas de otros equipos.
- **Duplicación de lógica** — "evaluación completada" termina implementada de
  formas distintas en lugares distintos: un equipo escribe
  `status = 'completed'`, otro `status IN ('completed', 'calibrated')` y un
  tercero `status != 'pending'`. Las tres son razonables, las tres dan
  números distintos, y nadie se entera hasta que dos reportes se contradicen.
- **Falta de interfaz común** — no hay forma estándar de saber qué datos
  existen ni de pedirlos sin conocer el esquema.

Esta capa resuelve los tres: cada módulo **declara** su vocabulario una vez, y
cualquier consumidor pide por nombre de negocio.

---

## Qué es y qué no es

**Es** una librería Ruby que se embebería en el monolito. Recibe una consulta
declarativa en JSON y devuelve filas, más la trazabilidad completa de cómo las
obtuvo.

Una consulta declarativa se ve así:

```json
{
  "metrics": ["avg_performance_score", "completed_reviews", "completion_rate"],
  "dimensions": [
    { "name": "review_period", "granularity": "quarter" },
    "department"
  ],
  "filters": [
    { "dimension": "review_period",
      "operator": "between",
      "values": ["2025-01-01", "2025-12-31"] }
  ],
  "order_by": [{ "field": "review_period", "direction": "asc" }],
  "limit": 500
}
```

"dame el score promedio, las evaluaciones completadas y la
tasa de completitud, agrupadas por trimestre y departamento, solo del 2025,
ordenadas por trimestre."* No aparece ninguna tabla, ninguna columna, ningún
JOIN — y tampoco `company_id`, que la capa inyecta sola.

**No es** una aplicación desplegable, un dashboard, ni un servicio HTTP. Las
carpetas `db/` y `spec/` existen para poder demostrarla y probarla de forma
aislada; en un entorno real esas tablas ya existirían.

---

## Arranque rápido

### Requisitos

- Ruby 3.2+
- PostgreSQL 14+

### Instalación

**1. Clonar e instalar dependencias**

```bash
git clone <url-del-repo>
cd buk-semantic-layer
bundle install
```

**2. Crear la base de datos y el esquema**

Abre `psql` **desde la raíz del proyecto** (la ruta de `\i` es relativa a
donde lo lances):

```bash
psql -d postgres
```

Y dentro de la consola de `psql`:

```sql
CREATE DATABASE buk_semantic_layer_dev;
\c buk_semantic_layer_dev
\i db/schema.sql
\dt
\q
```

`\dt` debe listar las cinco tablas: `companies`, `departments`, `employees`,
`performance_reviews` y `attendance`.

**3. Cargar los datos de prueba**

De vuelta en la terminal:

```bash
bundle exec ruby db/seeds.rb
```

Los seeds cargan **dos empresas** con departamentos que se llaman igual en
ambas —a propósito— para que cualquier fuga de aislamiento sea visible en los
números y no solo en la teoría.

### Verificar que funciona

```bash
bundle exec rspec
```

27 tests. El central compara, fila a fila, el resultado del motor contra el
SQL de referencia del enunciado, para las dos empresas.

---

## Arquitectura

```
definitions/        Lo que declara cada módulo (datos, no código)
  core.yml            empleados y departamentos, compartidos
  performance.yml     evaluaciones de desempeño
  attendance.yml      asistencia

catalog/            Carga, valida y responde "¿esto existe?"
  loader.rb           YAML → objetos Ruby
  definitions.rb      objetos de valor: Entity, Metric, Dimension...
  validator.rb        coherencia del catálogo, al arrancar
  registry.rb         el catálogo en memoria, única fuente de verdad

engine/             Consulta declarativa → SQL → filas
  query.rb            normaliza la FORMA del JSON
  query_validator.rb  valida el CONTENIDO contra el catálogo
  planner.rb          arma el plan de ejecución
  derived_metrics.rb  parsea y expande fórmulas
  join_resolver.rb    deduce el camino de JOINs (BFS)
  sql_compiler.rb     escribe el SQL con parámetros
  executor.rb         ejecuta y devuelve datos + trazabilidad

tenancy/            El contexto de empresa, obligatorio e inmutable
errors.rb           La jerarquía de errores: los de carga y los de consulta
semantic_layer.rb   Punto de entrada de la librería

llm/  +  bin/ask    Adaptador de lenguaje natural (opcional)
db/  +  spec/       Andamiaje para probar la capa
```

Dos documentos complementan este README:

- **[FLUJO.md](FLUJO.md)** — el recorrido completo de una consulta paso a
  paso, con el input y el output exactos de cada archivo, y diagramas.
- **[ANATOMIA.md](ANATOMIA.md)** — referencia de los archivos de
  `definitions/`: qué declara cada campo, qué nombres son libres y cuáles son
  vocabulario del motor, la receta para escribir un módulo nuevo y un ejemplo
  completo de principio a fin.

---

## Cómo declara un módulo sus datos

Un equipo declara su vocabulario en YAML. No escribe SQL ni conoce el motor:

```yaml
module: performance
entities:
  reviews:
    table: performance_reviews
    tenant_key: company_id          # obligatorio: sin esto el catálogo lo rechaza
    relationships:
      - name: employee
        type: many_to_one
        entity: core.employees
        foreign_key: employee_id

    dimensions:
      review_period:
        column: period
        type: time
        granularities: [quarter, month, year]
        label: "Periodo evaluado"

    filters:
      completed:
        expression: "{{table}}.status = 'completed'"

    metrics:
      total_reviews:
        type: count
      completed_reviews:
        type: count
        filters: [completed]
      completion_rate:
        type: derived
        formula: "completed_reviews / total_reviews * 100"
```

Cada campo existe porque hay un pedazo del SQL final que no se puede escribir
sin él: `table` → FROM, `tenant_key` → el predicado de empresa, `metrics` →
las agregaciones, `dimensions` → el GROUP BY, `relationships` → los JOINs,
`filters` → las cláusulas FILTER.

**[ANATOMIA.md](ANATOMIA.md)** es la referencia completa de este formato:
campo por campo con lo que es obligatorio y quién lo lee, qué nombres son
libres, las reglas de unicidad, y por qué los filtros del YAML y los del
consumidor son dos mecanismos distintos.

---

## Cómo consulta un consumidor

```ruby
layer  = SemanticLayer::Layer.load(definitions_path: "definitions",
                                   connection: ActiveRecord::Base.connection)
tenant = SemanticLayer::Tenancy::TenantContext.new(company_id: current_user.company_id)

result = layer.run({
  "metrics"    => ["avg_performance_score", "completed_reviews", "completion_rate"],
  "dimensions" => [{ "name" => "review_period", "granularity" => "quarter" },
                   "department"],
  "filters"    => [{ "dimension" => "review_period", "operator" => "between",
                     "values" => ["2025-01-01", "2025-12-31"] }],
  "order_by"   => [{ "field" => "review_period", "direction" => "asc" }]
}, tenant: tenant)
```

Ni una tabla, ni una columna, ni un JOIN, ni `company_id`.

La respuesta trae los datos **y la trazabilidad**:

```ruby
result.data
# => [{ "review_period" => #<Date 2025-01-01>, "department" => "Ingeniería",
#       "avg_performance_score" => 4.25, "completed_reviews" => 2,
#       "completion_rate" => 100.0 }, ...]
#    Los NUMERIC llegan como BigDecimal, no como Float: el executor aplica el
#    type map de PG para no perder precisión en las divisiones.

result.meta[:sql]        # el SQL exacto que se ejecutó
result.meta[:binds]      # [1, "2025-01-01", "2025-12-31", 1000]
result.meta[:join_path]  # ["performance.reviews", "core.employees", "core.departments"]
```

`meta[:sql]` no es decoración: es lo que permite que cualquiera verifique de
dónde salió un número.

---

## Aislamiento entre empresas

Tres garantías, ninguna opcional:

**1. El contexto no se puede construir vacío.** `TenantContext` exige
`company_id:` como argumento con nombre, valida que sea un entero positivo y
se congela. No hay valor por defecto ni forma de mutarlo después.

**2. El filtro se inyecta siempre.** El compilador emite el predicado de
empresa sobre la entidad base **y** en cada `ON` de cada JOIN. Como el
catálogo rechaza al arrancar cualquier entidad sin `tenant_key`, no existe
camino de código que produzca SQL sin él.

**3. El consumidor no puede mencionarlo.** Si el JSON trae `company_id` como
dimensión o filtro, la consulta se rechaza con un error explícito. Ignorarlo
en silencio enmascararía un bug o un intento de escalada.

Además, el executor declara `app.current_company_id` a nivel de transacción,
de modo que la capa es compatible con políticas RLS si la plataforma las tiene
activas. Configurar RLS no le corresponde a esta capa: esas tablas pertenecen
a los módulos, no a ella.

---

## Métricas derivadas

Se declaran como fórmula sobre otras métricas:

```yaml
completion_rate:
  type: derived
  formula: "completed_reviews / total_reviews * 100"
```

Tres propiedades:

- **Gramática cerrada.** La fórmula se parsea a un árbol aceptando solo
  referencias a métricas, números, las cuatro operaciones y paréntesis.
  Cualquier otro carácter falla. No es interpolación de strings.
- **Expansión automática.** Pedir `completion_rate` agrega
  `completed_reviews` y `total_reviews` al SELECT interno aunque nadie las
  haya pedido, y no las devuelve.
- **Post-agregación por construcción.** El SQL se compila siempre en dos
  niveles: la agregación ocurre dentro de un CTE y la fórmula se evalúa fuera,
  donde solo existen columnas ya agregadas. Es estructuralmente imposible que
  se calcule fila a fila.

---

## Adaptador de lenguaje natural (opcional)

Un agente de IA es uno de los tres consumidores que el enunciado menciona
(junto a dashboards y APIs internas). `llm/` demuestra ese consumidor.

Vive **encima** del núcleo, nunca dentro: `llm/adapter.rb` hace `require` de
`semantic_layer.rb`, y ningún archivo del núcleo menciona `llm/`. Por eso el
núcleo se testea sin API key ni red, y cambiar de proveedor de IA no lo toca.

El modelo **nunca ve ni escribe SQL**. Solo traduce la pregunta a la consulta
declarativa, eligiendo de la lista cerrada que el catálogo le expone. Si se
equivoca, el error del validador vuelve al modelo para que reintente, con un
máximo de 3 intentos en total; cuando ese error enumera las opciones válidas
—el caso de un nombre que no existe— la corrección suele salir en el mismo
turno.

Y **el modelo no escribe ningún número**. Para el resumen no recibe la tabla
ni ninguna cifra: Ruby determina qué grupo destaca y cuál queda atrás, y el
modelo solo lo redacta en palabras. Las cifras viven únicamente en la tabla,
donde están garantizadas. A un modelo pequeño al que se le pasan números se le
escapan otros inventados; al que no recibe ninguno, no puede.

### Requisitos

```bash
curl -fsSL https://ollama.com/install.sh | sh
ollama pull llama3.2:3b
```

Modelo local: sin cuenta, sin API key y sin costo. Para mejor precisión:
`ollama pull qwen2.5:7b` y `OLLAMA_MODEL=qwen2.5:7b`.

### Uso

```bash
bundle exec ruby bin/ask [--company N] "tu pregunta"
```

Imprime, en este orden: la pregunta, el JSON que produjo el modelo, los
intentos rechazados si los hubo, el SQL generado con sus parámetros, la tabla
de datos y el resumen en prosa.

`--company` representa la sesión autenticada. Se lee antes de armar la
pregunta, así que **nunca llega al modelo**: el tenant dice *quién* pregunta,
la pregunta dice *qué* se quiere saber.

---

## Preguntas de ejemplo

Con la base de datos cargada y Ollama corriendo. Son preguntas en lenguaje
natural, así que el modelo puede interpretar alguna distinto de lo esperado:
el JSON que produjo se imprime siempre, antes de los datos.

### La misma pregunta, tres formas

Las tres apuntan a lo mismo y normalmente producen el mismo SQL y los mismos
datos:

```bash
bundle exec ruby bin/ask "score promedio de desempeño por departamento"
bundle exec ruby bin/ask "muéstrame la nota media de las evaluaciones por departamento"
bundle exec ruby bin/ask "¿qué tal viene cada departamento en desempeño?"
```

Un LLM no es determinista: la traducción puede variar entre corridas, y la
precisión mejora con modelos más potentes que el de 3B que la demo usa por
defecto.

El motor no depende de eso: elija lo que elija el modelo, el SQL lo escribe
siempre el compilador.

### Desempeño

```bash
bundle exec ruby bin/ask "¿cuántas evaluaciones se completaron por departamento?"
bundle exec ruby bin/ask "tasa de completitud por departamento"
bundle exec ruby bin/ask "score promedio por departamento y trimestre en 2025"
bundle exec ruby bin/ask "evaluaciones completadas por mes en 2025"
bundle exec ruby bin/ask "compara evaluaciones completadas contra el total, por departamento"
bundle exec ruby bin/ask "score promedio por empleado"
bundle exec ruby bin/ask "evaluaciones agrupadas por estado"
```

### Asistencia

```bash
bundle exec ruby bin/ask "tasa de asistencia por departamento"
bundle exec ruby bin/ask "días presentes por departamento"
bundle exec ruby bin/ask "tasa de asistencia por empleado"
```

Los seeds solo cargan asistencia del 6 al 17 de enero de 2025; fuera de ese
rango el resultado es vacío, correctamente.

### Aislamiento entre empresas

La misma pregunta, dos empresas, números distintos. Los departamentos se
llaman igual en ambas:

```bash
bundle exec ruby bin/ask --company 1 "tasa de completitud por departamento"
bundle exec ruby bin/ask --company 2 "tasa de completitud por departamento"
```

### Consultas que el motor rechaza

Las protecciones viven en el validador y se disparan venga la consulta de un
dashboard, de una API interna o de un LLM. Se ven mejor llamando al motor
directamente, porque así no dependen de lo que el modelo decida emitir:

```ruby
# Métrica inexistente -> el error lista las disponibles
layer.run({ "metrics" => ["avg_salary"] }, tenant: tenant)
# => UnknownMetricError: metric 'avg_salary' does not exist. Available: ...

# Granularidad no declarada
layer.run({ "metrics"    => ["avg_performance_score"],
            "dimensions" => [{ "name" => "review_period", "granularity" => "week" }] },
          tenant: tenant)
# => InvalidQueryError: dimension 'review_period' does not support granularity
#    'week'. Supported: quarter, month, year

# Métricas de dos tablas de hechos -> evita fan-out
layer.run({ "metrics" => ["avg_performance_score", "attendance_rate"] }, tenant: tenant)
# => InvalidQueryError: the query mixes metrics from more than one entity...

# La empresa no es negociable
layer.run({ "metrics" => ["total_reviews"], "dimensions" => ["company_id"] },
          tenant: tenant)
# => InvalidQueryError: 'company_id' cannot be used as a dimension:
#    per-company isolation is applied automatically by the semantic layer
```

Que fallen **es el comportamiento correcto**. Un motor que devuelve un número
inflado sin avisar es peor que uno que rechaza la consulta.

### El límite del vocabulario cerrado

El modelo solo puede elegir nombres de la lista que le da el catálogo, y está
obligado a elegir alguno. No tiene forma de responder "eso no existe", así que
ante un concepto ausente elige **lo más parecido**:

```bash
bundle exec ruby bin/ask "¿cuál es el salario promedio?"
# devuelve avg_performance_score: no hay ninguna métrica de salario
```

La lista cerrada garantiza que la consulta sea **válida**, no que sea **la que
se pidió**. Por eso `bin/ask` imprime el JSON declarativo antes de los datos:
ahí se ve que pidió `avg_performance_score` y no un salario.

---

## Qué se puede pedir

Todo sale de `definitions/`. Nada está en el código.

| Métricas | Dimensiones |
|---|---|
| `avg_performance_score` | `department` |
| `completed_reviews` | `review_period` *(quarter, month, year)* |
| `total_reviews` | `review_status` |
| `completion_rate` *(derivada)* | `attendance_date` *(day, week, month, quarter, year)* |
| `present_days` | `employee_name` |
| `total_attendance_days` | `employee_active` |
| `attendance_rate` *(derivada)* | `hire_date` *(month, quarter, year)* |

Operadores de filtro: `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `in`, `between`.

---

## Agregar un módulo nuevo

Un archivo YAML. Cero líneas modificadas en el motor.

El método: clasificar la tabla como **hecho** (una fila = un evento medible,
con fecha y valores agregables) o **dimensión** (una fila = algo que existe y
clasifica los hechos). Cada tabla de hechos define un módulo con su propio
archivo; las dimensiones usadas por más de un módulo van a `core.yml`.

La prueba en una línea: *si este módulo desapareciera, ¿los otros seguirían
necesitando esta tabla?* Si sí, va a `core`.

`definitions/attendance.yml` es exactamente eso: un módulo agregado después,
sin tocar `performance.yml` ni el motor.

La receta completa —los nueve pasos, las reglas de nombres, el checklist del
validador y un ejemplo desarrollado de principio a fin— está en
**[ANATOMIA.md](ANATOMIA.md)**.

---

## Limitaciones conocidas

- **Métricas de dos tablas de hechos en una consulta.** El planner las rechaza
  en vez de producir un resultado inflado por fan-out. La solución diseñada
  —agregar cada entidad en su propio CTE y unirlas por las dimensiones
  comunes— no está implementada.
- **RLS no viene configurado.** Es una decisión de plataforma, no de esta
  capa: las tablas pertenecen a los módulos. La capa ya declara la variable de
  sesión que esas políticas leerían.
- **Integridad del esquema.** `performance_reviews.company_id` y
  `attendance.company_id` son columnas desnormalizadas sin foreign key: nada
  impide, al insertar, que queden desincronizadas del empleado real. La
  solución son claves foráneas compuestas —`UNIQUE (id, company_id)` en
  `employees` y `FOREIGN KEY (employee_id, company_id)` en cada tabla de
  hechos—, que no se aplicaron para no alejarse del esquema del enunciado. En
  tiempo de **lectura** el riesgo ya está cubierto: cada JOIN que genera el
  motor incluye la igualdad de empresa explícitamente.
- **Sin caché ni pre-agregaciones.** Cada consulta va a la base de datos.
- **Sustitución silenciosa en el adaptador de lenguaje natural.** Ante un
  concepto que el catálogo no tiene, el modelo elige el término más parecido
  en vez de rechazar la pregunta, porque el contrato lo obliga a devolver al
  menos una métrica. La mitigación diseñada —permitir que el modelo declare la
  pregunta como no respondible, y que el adaptador lo reporte en vez de
  reintentar— no está implementada. Hoy la salvaguarda es que el JSON
  declarativo se imprime antes de los datos.

---

## Tests

```bash
bundle exec rspec
```

| Archivo | Qué demuestra |
|---|---|
| `spec/correctness_spec.rb` | El resultado coincide fila a fila con el SQL de referencia del enunciado, en las dos empresas. Los JOINs salen de las definiciones. Ningún valor de usuario se interpola. |
| `spec/tenancy_spec.rb` | El contexto no se puede omitir, falsear ni mutar. El filtro está siempre, también en cada JOIN. Un payload de inyección termina en los parámetros y la tabla sigue viva. |
| `spec/derived_metrics_spec.rb` | La fórmula se evalúa fuera del CTE. El resultado coincide con la razón de agregados y **difiere** del promedio de razones por empleado. |
