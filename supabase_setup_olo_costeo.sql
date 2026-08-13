-- ═══════════════════════════════════════════════════════════════════════════
-- OLO · Costeo de Última Milla · Costa Rica 2026
-- Script de creación de base de datos para Supabase (PostgreSQL)
--
-- Ejecutar en: Supabase Dashboard → SQL Editor → New query → Run
--
-- Contenido:
--   1. Tablas de catálogo (tipos de camión, capacidades, rendimiento)
--   2. Costos fijos (conductor, ayudante, depreciación, otros)
--   3. Costos variables (40 componentes de mantenimiento por tipo)
--   4. Parámetros globales (TC, factores, días operativos)
--   5. Rutas y SKUs guardados
--   6. Vistas de cálculo
--   7. Row Level Security (RLS)
-- ═══════════════════════════════════════════════════════════════════════════

-- Limpieza (comentar si no querés borrar datos existentes)
drop view  if exists v_costo_variable_por_km cascade;
drop view  if exists v_costo_fijo_mensual    cascade;
drop table if exists sku_cotizaciones        cascade;
drop table if exists rutas                   cascade;
drop table if exists costos_variables        cascade;
drop table if exists costos_fijos            cascade;
drop table if exists depreciacion            cascade;
drop table if exists parametros_globales     cascade;
drop table if exists tipos_camion            cascade;
drop type  if exists frecuencia_tipo         cascade;
drop type  if exists costo_fijo_categoria    cascade;


-- ═══════════════════════════════════════════════════════════════════════════
-- 1. TIPOS ENUMERADOS
-- ═══════════════════════════════════════════════════════════════════════════

-- Cómo se amortiza la frecuencia de un componente variable
--   km    → cada N kilómetros
--   year  → N veces al año (se divide entre KM_ANUAL)
--   month → mensual (se divide entre KM mensuales)
create type frecuencia_tipo as enum ('km', 'year', 'month');

create type costo_fijo_categoria as enum ('conductor', 'ayudante', 'otros');


-- ═══════════════════════════════════════════════════════════════════════════
-- 2. TIPOS DE CAMIÓN — capacidad y rendimiento
-- ═══════════════════════════════════════════════════════════════════════════

create table tipos_camion (
  codigo          text primary key,               -- 't1' | 't3' | 't5'
  etiqueta        text        not null,
  descripcion     text        not null,
  capacidad_kg    numeric(10,2) not null check (capacidad_kg  > 0),
  capacidad_m3    numeric(10,2) not null check (capacidad_m3  > 0),
  km_por_litro    numeric(6,2)  not null check (km_por_litro  > 0),
  orden           smallint      not null,
  created_at      timestamptz   not null default now()
);

comment on table  tipos_camion is 'Catálogo de tipos de camión de flota propia OLO';
comment on column tipos_camion.km_por_litro is 'Rendimiento de diésel usado para calcular combustible de la ruta';

insert into tipos_camion (codigo, etiqueta, descripcion, capacidad_kg, capacidad_m3, km_por_litro, orden) values
  ('t1', '1–2.5 Ton', '1 a 2.5 Toneladas', 2500, 14, 8.5, 1),
  ('t3', '3–4.5 Ton', '3 a 4.5 Toneladas', 4500, 28, 6.0, 2),
  ('t5', '5–7 Ton',   '5 a 7 Toneladas',   7000, 42, 4.2, 3);


-- ═══════════════════════════════════════════════════════════════════════════
-- 3. PARÁMETROS GLOBALES
-- ═══════════════════════════════════════════════════════════════════════════

create table parametros_globales (
  clave       text primary key,
  valor       numeric(14,4) not null,
  unidad      text,
  descripcion text        not null,
  updated_at  timestamptz not null default now()
);

insert into parametros_globales (clave, valor, unidad, descripcion) values
  ('tipo_cambio_usd',      452,   '₡/USD',   'Tipo de cambio colón/dólar (se refresca vía API)'),
  ('precio_diesel',        635,   '₡/L',     'Precio del litro de diésel (fuente: RECOPE)'),
  ('km_anual',           36000,   'KM',      'Kilometraje anual de referencia para amortizar componentes anuales'),
  ('horas_dia',              8,   'horas',   'Jornada laboral estándar'),
  ('horas_extra_umbral',    12,   'horas',   'Umbral a partir del cual aplica pago de horas extra'),
  ('horas_max',             16,   'horas',   'Duración máxima permitida de una ruta'),
  ('factor_horas_extra',   1.5,   'x',       'Multiplicador salarial sobre horas extra'),
  ('dias_operativos',       30,   'días/mes','Divisor de los costos fijos mensuales para obtener costo diario'),
  ('factor_ocupacion',      85,   '%',       'Porcentaje máximo aprovechable de la capacidad del camión'),
  ('factor_volumetrico',   333,   'kg/m³',   'Factor de conversión de volumen a peso facturable');


-- ═══════════════════════════════════════════════════════════════════════════
-- 4. COSTOS FIJOS MENSUALES (conductor / ayudante / otros)
-- ═══════════════════════════════════════════════════════════════════════════

create table costos_fijos (
  id          bigserial primary key,
  categoria   costo_fijo_categoria not null,
  concepto    text          not null,
  monto       numeric(14,2) not null check (monto >= 0),
  orden       smallint      not null default 0,
  activo      boolean       not null default true,
  created_at  timestamptz   not null default now(),
  updated_at  timestamptz   not null default now(),
  unique (categoria, concepto)
);

comment on table costos_fijos is 'Costos fijos mensuales. Se dividen entre dias_operativos y se multiplican por los días de la ruta.';

create index idx_costos_fijos_categoria on costos_fijos (categoria) where activo;

insert into costos_fijos (categoria, concepto, monto, orden) values
  ('conductor', 'Salario Chofer',     820600.00, 1),
  ('conductor', 'Aguinaldo Chofer',    83333.33, 2),
  ('conductor', 'Seguro (terceros)',   19000.00, 3),
  ('conductor', 'Marchamo',            18949.16, 4),
  ('conductor', 'DEKRA',                 888.00, 5),
  ('conductor', 'Zapatos y chaleco',    4000.00, 6),
  ('ayudante',  'Salario Ayudante',    462666.84, 1),
  ('ayudante',  'Aguinaldo Ayudante',   38555.57, 2);


-- ═══════════════════════════════════════════════════════════════════════════
-- 5. DEPRECIACIÓN POR TIPO DE CAMIÓN
-- ═══════════════════════════════════════════════════════════════════════════

create table depreciacion (
  codigo_camion   text primary key references tipos_camion(codigo) on delete cascade,
  valor_vehiculo  numeric(14,2) not null check (valor_vehiculo > 0),
  vida_meses      smallint      not null check (vida_meses > 0),
  -- Columna calculada: depreciación mensual
  monto_mensual   numeric(14,2) generated always as
                    (valor_vehiculo / vida_meses) stored,
  updated_at      timestamptz   not null default now()
);

comment on column depreciacion.monto_mensual is 'Depreciación lineal mensual = valor_vehiculo / vida_meses';

insert into depreciacion (codigo_camion, valor_vehiculo, vida_meses) values
  ('t1', 10000000, 60),
  ('t3', 20000000, 72),
  ('t5', 35000000, 72);


-- ═══════════════════════════════════════════════════════════════════════════
-- 6. COSTOS VARIABLES — 40 componentes de mantenimiento
--    Cada componente tiene frecuencia y costo propio por tipo de camión.
-- ═══════════════════════════════════════════════════════════════════════════

create table costos_variables (
  id          bigserial primary key,
  componente  text            not null unique,
  frecuencia  frecuencia_tipo not null,
  cantidad    text,                            -- ej. '1 UND', '8/11.5 L', '2 Ejes'

  freq_t1     numeric(12,2) not null check (freq_t1 > 0),
  costo_t1    numeric(14,2) not null check (costo_t1 >= 0),
  freq_t3     numeric(12,2) not null check (freq_t3 > 0),
  costo_t3    numeric(14,2) not null check (costo_t3 >= 0),
  freq_t5     numeric(12,2) not null check (freq_t5 > 0),
  costo_t5    numeric(14,2) not null check (costo_t5 >= 0),

  orden       smallint    not null default 0,
  activo      boolean     not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table  costos_variables is 'Componentes de mantenimiento. El costo por KM depende de la frecuencia y del tipo de camión.';
comment on column costos_variables.freq_t1 is 'km: cada N km · year: N veces/año · month: mensual (usar 1)';

create index idx_costos_variables_activo on costos_variables (activo) where activo;

insert into costos_variables
  (componente, frecuencia, cantidad, freq_t1, costo_t1, freq_t3, costo_t3, freq_t5, costo_t5, orden)
values
  ('Filtro de Agua', 'km', '1 UND', 15000, 9040, 15000, 11300, 15000, 15820, 1),
  ('Filtro de Aire', 'km', '1 UND', 15000, 14464, 15000, 18080, 15000, 24860, 2),
  ('Filtro de Aceite', 'km', '1 UND', 5000, 7232, 5000, 9040, 5000, 13560, 3),
  ('Lata de Aceite', 'km', '8/11.5 L', 5000, 28928, 5000, 36160, 5000, 51980, 4),
  ('Engrase General', 'km', '1 Serv', 5000, 7232, 5000, 9040, 5000, 13560, 5),
  ('Engrase de Cojinetes', 'km', '2 Ejes', 20000, 12656, 20000, 15820, 20000, 20340, 6),
  ('Engrase de Patas', 'km', '1 Serv', 10000, 5424, 10000, 6780, 10000, 9040, 7),
  ('Engrase Patas/Zapatas 4 Puntas', 'km', '4 Ptos', 10000, 7232, 10000, 9040, 10000, 11300, 8),
  ('MO General (por hora)', 'month', '1 Hora', 1, 9040, 1, 11300, 1, 13560, 9),
  ('MO (por evento)', 'month', '1 UND', 1, 9040, 1, 11300, 1, 13560, 10),
  ('MO Servicio de Frenos', 'km', '2.5/3 H', 25000, 21696, 25000, 27120, 22000, 36160, 11),
  ('Filtro de Diesel', 'km', '1 UND', 10000, 12656, 10000, 15820, 10000, 20340, 12),
  ('Trampa de Diesel', 'km', '1 UND', 10000, 10848, 10000, 13560, 10000, 18080, 13),
  ('Batería', 'year', '2 UND', 2, 72320, 2, 90400, 2, 113000, 14),
  ('Kit Clutch', 'km', '1 Kit', 70000, 130176, 70000, 162720, 65000, 226000, 15),
  ('MO Cambio de Clutch', 'km', '5/6 H', 70000, 43392, 70000, 54240, 65000, 81360, 16),
  ('Aceite diferencial (85W140)', 'km', '4/6 L', 40000, 16272, 40000, 20340, 40000, 29380, 17),
  ('Aceite de Caja (85W190)', 'km', '4/5.5 L', 40000, 16272, 40000, 20340, 40000, 27120, 18),
  ('MO Diferencial y Caja', 'km', '1.5 H', 40000, 14464, 40000, 18080, 40000, 22600, 19),
  ('Mantenimiento Arrancador', 'km', '1 Serv', 80000, 50624, 80000, 63280, 80000, 85880, 20),
  ('Monitoreo Sensores/Computadora', 'km', '1 Escaneo', 10000, 16272, 10000, 20340, 10000, 24860, 21),
  ('Bomba de Agua', 'km', '1 UND', 120000, 47008, 120000, 58760, 100000, 81360, 22),
  ('MO Cambio Balancines/Tensores', 'km', '3/4 H', 100000, 32544, 100000, 40680, 100000, 54240, 23),
  ('Balancines', 'km', '1 Juego', 100000, 39776, 100000, 49720, 100000, 67800, 24),
  ('Tensores', 'km', '1 UND', 100000, 25312, 100000, 31640, 100000, 42940, 25),
  ('Rach', 'km', '2 UND', 60000, 18080, 60000, 22600, 60000, 33900, 26),
  ('Empastado Zapatas 4 Puntas', 'km', '1 Juego', 50000, 39776, 50000, 49720, 45000, 72320, 27),
  ('Juego de Llantas (6 Nuevas)', 'km', '6 UND', 50000, 325440, 50000, 406800, 45000, 569520, 28),
  ('2 Cojinetes de Rueda / UND', 'year', '1 UND', 4, 10848, 4, 13560, 4, 18080, 29),
  ('Válvula Compensadora de Bolsas', 'year', '1 UND', 5, 10848, 5, 13560, 5, 17176, 30),
  ('Bolsas / UND', 'year', '1 UND', 4, 21696, 4, 27120, 4, 36160, 31),
  ('Rampa Hidráulica / UND', 'year', '1 UND', 8, 144640, 8, 180800, 8, 254250, 32),
  ('Shocks / UND', 'year', '1 UND', 3, 21696, 3, 27120, 3, 36160, 33),
  ('King Pin', 'year', '1 UND', 5, 18080, 5, 22600, 4, 39550, 34),
  ('Crucetas / UND', 'year', '1 UND', 3, 10848, 3, 13560, 3, 20340, 35),
  ('Cojinete Cardan c/Base', 'year', '1 UND', 4, 9944, 4, 12430, 4, 18080, 36),
  ('Refuerzo de Resorte / UND', 'year', '1 UND', 5, 14464, 5, 18080, 5, 27120, 37),
  ('Forrado de Madera / UND', 'year', '1 UND', 6, 28928, 6, 36160, 6, 45200, 38),
  ('Piso / UND', 'year', '1 UND', 8, 43392, 8, 54240, 8, 81360, 39),
  ('Persiana / UND', 'year', '1 UND', 7, 36160, 7, 45200, 7, 58760, 40);


-- ═══════════════════════════════════════════════════════════════════════════
-- 7. RUTAS GUARDADAS
-- ═══════════════════════════════════════════════════════════════════════════

create table rutas (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid        references auth.users(id) on delete cascade,
  nombre          text        not null,
  codigo_camion   text        not null references tipos_camion(codigo),

  -- Parámetros de la ruta
  kilometros      numeric(10,2) not null check (kilometros    >= 0),
  dias            smallint      not null default 1  check (dias between 1 and 7),
  horas           smallint      not null default 8  check (horas between 1 and 16),
  con_ayudante    boolean       not null default false,

  -- Snapshot de parámetros al momento de guardar
  precio_diesel     numeric(10,2) not null,
  tipo_cambio       numeric(10,2) not null,
  dias_operativos   smallint      not null default 30,
  factor_ocupacion  numeric(5,2)  not null default 85,
  factor_volumetrico numeric(8,2) not null default 333,

  -- Carga transportada
  carga_peso_kg   numeric(12,2) default 0,
  carga_vol_m3    numeric(12,3) default 0,

  -- Resultados calculados (snapshot)
  costo_fijo         numeric(14,2),
  costo_combustible  numeric(14,2),
  costo_mantenimiento numeric(14,2),
  costo_horas_extra  numeric(14,2),
  costo_total        numeric(14,2),

  notas       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index idx_rutas_user    on rutas (user_id, created_at desc);
create index idx_rutas_camion  on rutas (codigo_camion);


-- ═══════════════════════════════════════════════════════════════════════════
-- 8. COTIZACIONES DE SKU
-- ═══════════════════════════════════════════════════════════════════════════

create table sku_cotizaciones (
  id              uuid primary key default gen_random_uuid(),
  ruta_id         uuid references rutas(id) on delete cascade,
  user_id         uuid references auth.users(id) on delete cascade,

  referencia      text          not null,
  peso_kg         numeric(12,3) not null check (peso_kg >= 0),
  volumen_m3      numeric(12,4) not null check (volumen_m3 >= 0),
  cantidad        integer       not null default 1 check (cantidad > 0),

  -- Resultados calculados
  peso_volumetrico  numeric(12,3),
  peso_facturable   numeric(12,3),
  costo_unitario    numeric(14,4),
  costo_total       numeric(14,2),
  max_uds_peso      integer,
  max_uds_volumen   integer,
  max_uds_efectivo  integer,

  created_at  timestamptz not null default now()
);

create index idx_sku_ruta on sku_cotizaciones (ruta_id);
create index idx_sku_user on sku_cotizaciones (user_id, created_at desc);


-- ═══════════════════════════════════════════════════════════════════════════
-- 9. VISTAS DE CÁLCULO
-- ═══════════════════════════════════════════════════════════════════════════

-- Costo fijo mensual total por tipo de camión (incluye depreciación)
create view v_costo_fijo_mensual as
select
  tc.codigo                                     as codigo_camion,
  tc.etiqueta,
  coalesce(cond.total, 0)                       as total_conductor,
  coalesce(ayud.total, 0)                       as total_ayudante,
  coalesce(otro.total, 0)                       as total_otros,
  d.monto_mensual                               as depreciacion_mensual,
  coalesce(cond.total,0) + coalesce(otro.total,0) + d.monto_mensual
                                                as fijo_sin_ayudante,
  coalesce(cond.total,0) + coalesce(otro.total,0) + d.monto_mensual + coalesce(ayud.total,0)
                                                as fijo_con_ayudante
from tipos_camion tc
join depreciacion d on d.codigo_camion = tc.codigo
left join (select sum(monto) total from costos_fijos where categoria='conductor' and activo) cond on true
left join (select sum(monto) total from costos_fijos where categoria='ayudante'  and activo) ayud on true
left join (select sum(monto) total from costos_fijos where categoria='otros'     and activo) otro on true;

comment on view v_costo_fijo_mensual is 'Totales de costo fijo mensual por tipo de camión, con y sin ayudante';


-- Costo por kilómetro de cada componente variable, por tipo de camión
create view v_costo_variable_por_km as
with km_anual as (
  select valor as v from parametros_globales where clave = 'km_anual'
)
select
  cv.id,
  cv.componente,
  cv.frecuencia,
  cv.cantidad,
  t.codigo_camion,
  t.frecuencia_valor,
  t.costo_valor,
  case cv.frecuencia
    when 'km'    then t.costo_valor / nullif(t.frecuencia_valor, 0)
    when 'year'  then t.costo_valor / nullif(t.frecuencia_valor * (select v from km_anual), 0)
    when 'month' then t.costo_valor / nullif((select v from km_anual) / 12.0, 0)
  end as costo_por_km
from costos_variables cv
cross join lateral (values
  ('t1', cv.freq_t1, cv.costo_t1),
  ('t3', cv.freq_t3, cv.costo_t3),
  ('t5', cv.freq_t5, cv.costo_t5)
) as t(codigo_camion, frecuencia_valor, costo_valor)
where cv.activo;

comment on view v_costo_variable_por_km is 'Costo por KM de cada componente, desglosado por tipo de camión';


-- ═══════════════════════════════════════════════════════════════════════════
-- 10. TRIGGER updated_at
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

create trigger trg_costos_fijos_updated      before update on costos_fijos
  for each row execute function set_updated_at();
create trigger trg_costos_variables_updated   before update on costos_variables
  for each row execute function set_updated_at();
create trigger trg_depreciacion_updated       before update on depreciacion
  for each row execute function set_updated_at();
create trigger trg_parametros_updated         before update on parametros_globales
  for each row execute function set_updated_at();
create trigger trg_rutas_updated              before update on rutas
  for each row execute function set_updated_at();


-- ═══════════════════════════════════════════════════════════════════════════
-- 11. ROW LEVEL SECURITY
--     Catálogos: lectura pública, escritura solo autenticados.
--     Rutas y SKUs: cada usuario ve únicamente sus registros.
-- ═══════════════════════════════════════════════════════════════════════════

alter table tipos_camion        enable row level security;
alter table parametros_globales enable row level security;
alter table costos_fijos        enable row level security;
alter table costos_variables    enable row level security;
alter table depreciacion        enable row level security;
alter table rutas               enable row level security;
alter table sku_cotizaciones    enable row level security;

-- Catálogos: lectura para todos
create policy "lectura publica tipos_camion"        on tipos_camion        for select using (true);
create policy "lectura publica parametros"          on parametros_globales for select using (true);
create policy "lectura publica costos_fijos"        on costos_fijos        for select using (true);
create policy "lectura publica costos_variables"    on costos_variables    for select using (true);
create policy "lectura publica depreciacion"        on depreciacion        for select using (true);

-- Catálogos: escritura solo autenticados
create policy "escritura auth parametros"       on parametros_globales for all
  using (auth.uid() is not null) with check (auth.uid() is not null);
create policy "escritura auth costos_fijos"     on costos_fijos        for all
  using (auth.uid() is not null) with check (auth.uid() is not null);
create policy "escritura auth costos_variables" on costos_variables    for all
  using (auth.uid() is not null) with check (auth.uid() is not null);
create policy "escritura auth depreciacion"     on depreciacion        for all
  using (auth.uid() is not null) with check (auth.uid() is not null);

-- Rutas y SKUs: aislamiento por usuario
create policy "rutas propias" on rutas for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "skus propios"  on sku_cotizaciones for all
  using (auth.uid() = user_id) with check (auth.uid() = user_id);


-- ═══════════════════════════════════════════════════════════════════════════
-- 12. VERIFICACIÓN
-- ═══════════════════════════════════════════════════════════════════════════

select 'tipos_camion'        as tabla, count(*) as filas from tipos_camion
union all select 'parametros_globales', count(*) from parametros_globales
union all select 'costos_fijos',        count(*) from costos_fijos
union all select 'depreciacion',        count(*) from depreciacion
union all select 'costos_variables',    count(*) from costos_variables
order by tabla;

-- Esperado:
--   costos_fijos          8
--   costos_variables     40
--   depreciacion          3
--   parametros_globales  10
--   tipos_camion          3
