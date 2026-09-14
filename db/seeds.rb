#!/usr/bin/env ruby

require_relative "connection"

conn = ActiveRecord::Base.connection

def insert(conn, table, row)
  columns = row.keys.join(", ")
  values  = row.values.map { |v| conn.quote(v) }.join(", ")
  conn.execute("INSERT INTO #{table} (#{columns}) VALUES (#{values})")
end

reviews_count    = 0
attendance_count = 0

conn.transaction do
  # Permite re-correr el script sin chocar con datos de una corrida anterior.
  conn.execute("TRUNCATE companies, departments, employees, performance_reviews, attendance CASCADE")

  # -- Empresas ---------------------------------------------------------
  insert(conn, "companies", id: 1, name: "Empresa Alfa")
  insert(conn, "companies", id: 2, name: "Empresa Beta")

  # -- Departamentos (mismos nombres en ambas empresas, a propósito) -----
  insert(conn, "departments", id: 1, company_id: 1, name: "Ingeniería")
  insert(conn, "departments", id: 2, company_id: 1, name: "Ventas")
  insert(conn, "departments", id: 3, company_id: 2, name: "Ingeniería")
  insert(conn, "departments", id: 4, company_id: 2, name: "Ventas")

  # -- Empleados ----------------------------------------------------------
  # Dos quedan "active: false" para que la dimensión employee_active tenga
  # los dos valores y un filtro por ella devuelva algo distinto del total.
  employees = [
    { id: 1, company_id: 1, department_id: 1, name: "Ana Torres",    hire_date: "2022-01-10", active: true  },
    { id: 2, company_id: 1, department_id: 1, name: "Luis Medina",   hire_date: "2021-05-03", active: true  },
    { id: 3, company_id: 1, department_id: 2, name: "Carla Ruiz",    hire_date: "2023-02-15", active: true  },
    { id: 4, company_id: 1, department_id: 2, name: "Jorge Paredes", hire_date: "2020-09-01", active: false },
    { id: 5, company_id: 2, department_id: 3, name: "Marta Gómez",   hire_date: "2022-03-20", active: true  },
    { id: 6, company_id: 2, department_id: 3, name: "Pedro Salas",   hire_date: "2021-11-11", active: true  },
    { id: 7, company_id: 2, department_id: 4, name: "Sofía León",    hire_date: "2023-06-01", active: true  },
    { id: 8, company_id: 2, department_id: 4, name: "Diego Rojas",   hire_date: "2019-12-01", active: false },
  ]
  employees.each { |e| insert(conn, "employees", e) }

  # Mapa employee_id -> company_id derivado de los empleados ya insertados,
  # para que sea IMPOSIBLE que una evaluación o un registro de asistencia
  # quede con un company_id distinto al de su propio empleado -- ni
  # siquiera por accidente de tipeo en este script.
  employee_company = employees.each_with_object({}) { |e, h| h[e[:id]] = e[:company_id] }

  # -- Evaluaciones de desempeño ------------------------------------------
  # period = inicio de cada trimestre de 2025. Status mezclado a propósito:
  # 'pending' y 'calibrated' NO deben contar en completed_reviews/completion_rate.
  reviews = [
    # Empresa 1 - Ingeniería
    { employee_id: 1, period: "2025-01-01", score: 4.0, status: "completed"  },
    { employee_id: 2, period: "2025-01-01", score: 4.5, status: "completed"  },
    { employee_id: 1, period: "2025-04-01", score: 4.2, status: "completed"  },
    { employee_id: 2, period: "2025-04-01", score: 3.8, status: "pending"    },
    # Ana tiene DOS evaluaciones en Q2 (el enunciado permite más de una
    # por empleado al año). Esto hace que los empleados NO tengan el mismo
    # número de evaluaciones, que es lo que permite demostrar en un test
    # que la tasa calculada sobre agregados difiere del promedio de
    # razones por empleado.
    { employee_id: 1, period: "2025-04-01", score: 3.9, status: "pending"    },
    { employee_id: 1, period: "2025-07-01", score: 4.6, status: "completed"  },
    { employee_id: 2, period: "2025-07-01", score: 4.0, status: "completed"  },
    { employee_id: 1, period: "2025-10-01", score: 4.8, status: "calibrated" },
    { employee_id: 2, period: "2025-10-01", score: 4.3, status: "completed"  },
    # Empresa 1 - Ventas
    { employee_id: 3, period: "2025-01-01", score: 3.5, status: "completed"  },
    { employee_id: 4, period: "2025-01-01", score: 4.0, status: "completed"  },
    { employee_id: 3, period: "2025-04-01", score: 3.7, status: "completed"  },
    { employee_id: 4, period: "2025-04-01", score: 3.9, status: "completed"  },
    { employee_id: 3, period: "2025-07-01", score: 3.6, status: "pending"    },
    { employee_id: 4, period: "2025-07-01", score: 4.1, status: "completed"  },
    { employee_id: 3, period: "2025-10-01", score: 3.8, status: "completed"  },
    { employee_id: 4, period: "2025-10-01", score: 4.2, status: "completed"  },
    # Empresa 2 - Ingeniería
    { employee_id: 5, period: "2025-01-01", score: 4.4, status: "completed"  },
    { employee_id: 6, period: "2025-01-01", score: 4.1, status: "completed"  },
    { employee_id: 5, period: "2025-04-01", score: 4.5, status: "completed"  },
    { employee_id: 6, period: "2025-04-01", score: 4.0, status: "completed"  },
    { employee_id: 5, period: "2025-07-01", score: 4.3, status: "completed"  },
    { employee_id: 6, period: "2025-07-01", score: 3.9, status: "completed"  },
    { employee_id: 5, period: "2025-10-01", score: 4.6, status: "completed"  },
    { employee_id: 6, period: "2025-10-01", score: 4.2, status: "completed"  },
    # Empresa 2 - Ventas
    { employee_id: 7, period: "2025-01-01", score: 3.9, status: "completed"  },
    { employee_id: 8, period: "2025-01-01", score: 4.0, status: "completed"  },
    { employee_id: 7, period: "2025-04-01", score: 4.0, status: "completed"  },
    { employee_id: 8, period: "2025-04-01", score: 3.8, status: "pending"    },
    { employee_id: 7, period: "2025-07-01", score: 4.1, status: "completed"  },
    { employee_id: 8, period: "2025-07-01", score: 4.2, status: "completed"  },
    { employee_id: 7, period: "2025-10-01", score: 3.7, status: "completed"  },
    { employee_id: 8, period: "2025-10-01", score: 4.3, status: "completed"  },
  ]
  reviews.each_with_index do |r, i|
    insert(conn, "performance_reviews", r.merge(id: i + 1, company_id: employee_company[r[:employee_id]]))
  end
  reviews_count = reviews.size

  # -- Asistencia -----------------------------------------------------------
  # 10 días hábiles (6 al 17 de enero de 2025) por empleado, con distintos
  # patrones de ausencia para obtener tasas de asistencia variadas.
  dates = %w[2025-01-06 2025-01-07 2025-01-08 2025-01-09 2025-01-10
             2025-01-13 2025-01-14 2025-01-15 2025-01-16 2025-01-17]

  # índices (0-based) de días AUSENTES por empleado
  absences = {
    1 => [2],          # Ana:   90% asistencia
    2 => [1, 5],       # Luis:  80%
    3 => [4],          # Carla: 90%
    4 => [0, 3, 7],    # Jorge: 70%
    5 => [],           # Marta: 100%
    6 => [9],          # Pedro: 90%
    7 => [2, 6],       # Sofía: 80%
    8 => [0, 1, 4, 8], # Diego: 60%
  }

  attendance_id = 1
  employees.each do |e|
    dates.each_with_index do |date, i|
      present = !absences.fetch(e[:id]).include?(i)
      insert(conn, "attendance",
        id: attendance_id, employee_id: e[:id], company_id: e[:company_id],
        date: date, present: present)
      attendance_id += 1
    end
  end
  attendance_count = attendance_id - 1
end

puts "Seeds cargados: 2 empresas, 4 departamentos, 8 empleados, " \
     "#{reviews_count} evaluaciones, #{attendance_count} registros de asistencia."