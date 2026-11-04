-- Asistencia de Baile: cada profe entra con su código. Las tablas están cerradas;
-- solo se accede a través de funciones que comprueban el código.
-- Proyecto de Supabase: "Asistencia Baile" (eu-central-1, Frankfurt).

create extension if not exists pgcrypto with schema extensions;
create schema if not exists privado;
revoke all on schema privado from public, anon, authenticated;

create table if not exists public.profes (
  id uuid primary key default gen_random_uuid(),
  nombre text not null check (char_length(nombre) between 1 and 80),
  codigo text not null unique,
  es_admin boolean not null default false,
  activo boolean not null default true,
  creado timestamptz not null default now(),
  ultimo_acceso timestamptz
);

create table if not exists public.registros (
  profe_id uuid not null references public.profes(id) on delete cascade,
  coleccion text not null check (coleccion in ('grupos','alumnos','asistencia','ajustes')),
  id text not null check (char_length(id) between 1 and 80),
  datos jsonb not null,
  actualizado timestamptz not null default now(),
  primary key (profe_id, coleccion, id)
);

alter table public.profes enable row level security;
alter table public.registros enable row level security;
revoke all on public.profes, public.registros from anon, authenticated;

/* ---------- Ayudantes privados ---------- */
create or replace function privado.profe_por_codigo(p_codigo text)
returns public.profes language sql stable security definer set search_path = '' as $$
  select p.* from public.profes p
  where p.codigo = upper(regexp_replace(coalesce(p_codigo,''), '[^A-Za-z0-9]', '', 'g'))
    and p.activo
$$;

create or replace function privado.nuevo_codigo()
returns text language plpgsql volatile set search_path = '' as $$
declare
  alfabeto text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  b bytea; c text; i int;
begin
  loop
    b := extensions.gen_random_bytes(12); c := '';
    for i in 0..11 loop
      c := c || substr(alfabeto, (get_byte(b, i) % 31) + 1, 1);
    end loop;
    exit when not exists (select 1 from public.profes where codigo = c);
  end loop;
  return c;
end $$;

revoke all on all functions in schema privado from public, anon, authenticated;

/* ---------- Funciones de la app ---------- */
create or replace function public.entrar(p_codigo text)
returns json language plpgsql volatile security definer set search_path = '' as $$
declare p public.profes;
begin
  p := privado.profe_por_codigo(p_codigo);
  if p.id is null then
    perform pg_sleep(0.6);  -- frena a quien pruebe códigos al azar
    return null;
  end if;
  update public.profes set ultimo_acceso = now() where id = p.id;
  return json_build_object('nombre', p.nombre, 'es_admin', p.es_admin);
end $$;

create or replace function public.cargar(p_codigo text)
returns json language plpgsql volatile security definer set search_path = '' as $$
declare p public.profes;
begin
  p := privado.profe_por_codigo(p_codigo);
  if p.id is null then perform pg_sleep(0.6); return null; end if;
  update public.profes set ultimo_acceso = now() where id = p.id;
  return json_build_object(
    'perfil', json_build_object('nombre', p.nombre, 'es_admin', p.es_admin),
    'registros', coalesce((
      select json_agg(json_build_object('c', r.coleccion, 'id', r.id, 'd', r.datos))
      from public.registros r where r.profe_id = p.id), '[]'::json));
end $$;

-- p_cambios: [{"c":"alumnos","id":"abc","d":{...}}]  (d = null para borrar)
create or replace function public.guardar(p_codigo text, p_cambios jsonb)
returns int language plpgsql volatile security definer set search_path = '' as $$
declare p public.profes; x jsonb; n int := 0;
begin
  p := privado.profe_por_codigo(p_codigo);
  if p.id is null then perform pg_sleep(0.6); raise exception 'codigo_no_valido'; end if;
  if jsonb_typeof(p_cambios) <> 'array' or jsonb_array_length(p_cambios) > 500 then
    raise exception 'cambios_no_validos';
  end if;
  for x in select * from jsonb_array_elements(p_cambios) loop
    if x->'d' is null or jsonb_typeof(x->'d') = 'null' then
      delete from public.registros
       where profe_id = p.id and coleccion = x->>'c' and id = x->>'id';
    else
      if jsonb_typeof(x->'d') <> 'object' or octet_length((x->'d')::text) > 20000 then
        raise exception 'registro_demasiado_grande';
      end if;
      insert into public.registros (profe_id, coleccion, id, datos, actualizado)
      values (p.id, x->>'c', x->>'id', x->'d', now())
      on conflict (profe_id, coleccion, id)
      do update set datos = excluded.datos, actualizado = now();
    end if;
    n := n + 1;
  end loop;
  if (select count(*) from public.registros where profe_id = p.id) > 20000 then
    raise exception 'limite_de_registros';
  end if;
  return n;
end $$;

/* ---------- Funciones del panel de admin ---------- */
create or replace function public.admin_profes(p_codigo text)
returns json language plpgsql stable security definer set search_path = '' as $$
declare a public.profes;
begin
  a := privado.profe_por_codigo(p_codigo);
  if a.id is null or not a.es_admin then raise exception 'solo_admin'; end if;
  return coalesce((
    select json_agg(t order by t.creado) from (
      select p.id, p.nombre, p.codigo, p.es_admin, p.activo, p.creado, p.ultimo_acceso,
        (select count(*) from public.registros r where r.profe_id = p.id and r.coleccion = 'grupos') as grupos,
        (select count(*) from public.registros r where r.profe_id = p.id and r.coleccion = 'alumnos') as alumnos,
        (select count(*) from public.registros r where r.profe_id = p.id and r.coleccion = 'asistencia') as clases,
        (select max(r.datos->>'fecha') from public.registros r where r.profe_id = p.id and r.coleccion = 'asistencia') as ultima_clase
      from public.profes p) t), '[]'::json);
end $$;

create or replace function public.admin_crear_profe(p_codigo text, p_nombre text)
returns json language plpgsql volatile security definer set search_path = '' as $$
declare a public.profes; c text;
begin
  a := privado.profe_por_codigo(p_codigo);
  if a.id is null or not a.es_admin then raise exception 'solo_admin'; end if;
  c := privado.nuevo_codigo();
  insert into public.profes (nombre, codigo) values (trim(p_nombre), c);
  return json_build_object('codigo', c);
end $$;

create or replace function public.admin_activar(p_codigo text, p_id uuid, p_activo boolean)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare a public.profes;
begin
  a := privado.profe_por_codigo(p_codigo);
  if a.id is null or not a.es_admin then raise exception 'solo_admin'; end if;
  if p_id = a.id then raise exception 'no_puedes_desactivarte'; end if;
  update public.profes set activo = p_activo where id = p_id;
end $$;

revoke all on function public.entrar(text), public.cargar(text), public.guardar(text, jsonb),
  public.admin_profes(text), public.admin_crear_profe(text, text), public.admin_activar(text, uuid, boolean)
  from public;
grant execute on function public.entrar(text), public.cargar(text), public.guardar(text, jsonb),
  public.admin_profes(text), public.admin_crear_profe(text, text), public.admin_activar(text, uuid, boolean)
  to anon, authenticated;

-- El primer código de administrador se crea a mano desde el editor SQL:
-- insert into public.profes (nombre, codigo, es_admin) values ('The Wild Side', privado.nuevo_codigo(), true);

/* ---------- Diseño exclusivo por profe ---------- */
-- null = estándar; 'mariposa' = su nombre arriba y mariposa gigante de fondo.
-- entrar() y cargar() devuelven también 'diseno' en el perfil, y admin_profes() la columna diseno.
alter table public.profes add column if not exists diseno text check (diseno in ('mariposa'));

create or replace function public.admin_diseno(p_codigo text, p_id uuid, p_diseno text)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare a public.profes;
begin
  a := privado.profe_por_codigo(p_codigo);
  if a.id is null or not a.es_admin then raise exception 'solo_admin'; end if;
  update public.profes set diseno = nullif(p_diseno, '') where id = p_id;
end $$;
revoke all on function public.admin_diseno(text, uuid, text) from public;
grant execute on function public.admin_diseno(text, uuid, text) to anon, authenticated;

-- Diseño exclusivo 'clara' (Claramente Dance)
alter table public.profes drop constraint if exists profes_diseno_check;
alter table public.profes add constraint profes_diseno_check check (diseno in ('mariposa','clara'));
