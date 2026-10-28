-- TEG Leveranceplan: database-skema (backup af opsaetningen i Supabase)
--
-- Eksporteret 2026-09-30 fra Supabase-projektet "topas-analyst"
-- (ref oxpuloflkdcpshrabvkn). Kun plan_*-tabellerne; resten af projektet
-- tilhoerer andre vaerktoejer.
--
-- Filen er et oejebliksbillede, ikke en migration: den skal ikke koeres mod
-- den eksisterende database. Den kan bruges til at genskabe opsaetningen i
-- et tomt projekt. Data (personer, spor, punkter m.m.) er ikke med.
-- Opdater filen naar skemaet aendres.

-- ---------------------------------------------------------------------------
-- Tabeller
-- ---------------------------------------------------------------------------

create table public.plan_people (
  id text not null,
  name text not null,
  role text default ''::text not null,
  sort integer default 0 not null,
  department text default ''::text not null,
  constraint plan_people_pkey primary key (id)
);

create table public.plan_departments (
  name text not null,
  sort integer default 0 not null,
  constraint plan_departments_pkey primary key (name)
);

create table public.plan_tracks (
  id text not null,
  name text not null,
  owner text default ''::text not null,
  color text default '--s-blue'::text not null,
  from_m integer default 0 not null,
  solid_to integer default 17 not null,
  to_m integer default 17 not null,
  ongoing boolean default false not null,
  baseline boolean default false not null,
  sort integer,
  fee_onetime integer,
  fee_recurring integer,
  fee_extra_label text,
  fee_extra integer,
  category text,
  fee_internal numeric,
  constraint plan_tracks_pkey primary key (id),
  constraint plan_tracks_fee_extra_check check ((fee_extra is null) or (fee_extra >= 0)),
  constraint plan_tracks_fee_internal_check check ((fee_internal is null) or (fee_internal >= (0)::numeric)),
  constraint plan_tracks_fee_onetime_check check ((fee_onetime is null) or (fee_onetime >= 0)),
  constraint plan_tracks_fee_recurring_check check ((fee_recurring is null) or (fee_recurring >= 0))
);

-- m / from_m / to_m er maanedsindeks 0-26 (jul 2026 - sep 2028).
create table public.plan_milestones (
  id uuid default gen_random_uuid() not null,
  track_id text not null references public.plan_tracks(id) on delete cascade,
  m integer not null,
  label text not null,
  owner text default ''::text not null,
  from_m integer,
  status text default 'todo'::text not null,
  constraint plan_milestones_pkey primary key (id),
  constraint plan_milestones_status_check check (status = any (array['todo'::text, 'igang'::text, 'faerdig'::text, 'blokeret'::text])),
  constraint plan_ms_from_ck check ((from_m is null) or ((from_m >= 0) and (from_m <= 26))),
  constraint plan_ms_m_ck check ((m >= 0) and (m <= 26)),
  constraint plan_ms_period_ck check ((from_m is null) or (from_m <= m))
);

create table public.plan_allocations (
  id uuid default gen_random_uuid() not null,
  person_id text references public.plan_people(id) on delete cascade,
  track_id text not null references public.plan_tracks(id) on delete cascade,
  from_m integer not null,
  to_m integer not null,
  pct integer default 0 not null,
  milestone_id uuid references public.plan_milestones(id) on delete cascade,
  dept text,
  constraint plan_allocations_pkey primary key (id),
  constraint plan_alloc_from_ck check ((from_m >= 0) and (from_m <= 26)),
  constraint plan_alloc_person_or_dept check ((((person_id is not null))::integer + ((dept is not null))::integer) = 1),
  constraint plan_alloc_to_ck check ((to_m >= 0) and (to_m <= 26)),
  constraint plan_allocations_pct_check check ((pct >= 0) and (pct <= 150))
);

create unique index plan_alloc_unique_ms_dept on public.plan_allocations
  using btree (milestone_id, dept) where ((milestone_id is not null) and (dept is not null));
create unique index plan_alloc_unique_ms_person on public.plan_allocations
  using btree (milestone_id, person_id) where (milestone_id is not null);

create table public.plan_dependencies (
  id uuid default gen_random_uuid() not null,
  from_ms uuid not null references public.plan_milestones(id) on delete cascade,
  to_track text not null references public.plan_tracks(id) on delete cascade,
  to_ms uuid references public.plan_milestones(id) on delete cascade,
  dep_type text default 'start'::text not null,
  constraint plan_dependencies_pkey primary key (id),
  constraint plan_dependencies_dep_type_check check (dep_type = any (array['start'::text, 'finish'::text]))
);

create table public.plan_subtasks (
  id uuid default gen_random_uuid() not null,
  milestone_id uuid not null references public.plan_milestones(id) on delete cascade,
  label text not null,
  person_id text references public.plan_people(id) on delete set null,
  hours numeric,
  done boolean default false not null,
  created_at timestamp with time zone default now() not null,
  due_date date,
  status text default 'todo'::text not null,
  constraint plan_subtasks_pkey primary key (id),
  constraint plan_subtasks_hours_check check ((hours is null) or (hours >= (0)::numeric)),
  constraint plan_subtasks_status_check check (status = any (array['todo'::text, 'igang'::text, 'faerdig'::text, 'blokeret'::text]))
);

create table public.plan_changelog (
  id bigint generated always as identity not null,
  changed_at timestamp with time zone default now() not null,
  changed_by text not null,
  table_name text not null,
  action text not null,
  old_data jsonb,
  new_data jsonb,
  constraint plan_changelog_pkey primary key (id)
);

-- Gaester med laeseadgang. Ingen policies: tabellen laeses kun via
-- security definer-funktionerne nedenfor, og redigeres i Supabase-dashboardet.
create table public.plan_readonly (
  email text not null,
  note text,
  created_at timestamp with time zone default now() not null,
  constraint plan_readonly_pkey primary key (email)
);

-- ---------------------------------------------------------------------------
-- Funktioner
-- ---------------------------------------------------------------------------

-- Redigering: topas.dk-brugere der ikke staar paa plan_readonly.
create or replace function public.plan_can_edit()
 returns boolean
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select coalesce((auth.jwt()->>'email') ilike '%@topas.dk', false)
     and not exists (select 1 from plan_readonly r where lower(r.email) = lower(coalesce(auth.jwt()->>'email','')));
$function$;

-- Laesning: topas.dk-brugere plus gaester paa plan_readonly.
create or replace function public.plan_can_read()
 returns boolean
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select coalesce((auth.jwt()->>'email') ilike '%@topas.dk', false)
      or exists (select 1 from plan_readonly r where lower(r.email) = lower(coalesce(auth.jwt()->>'email','')));
$function$;

create or replace function public.plan_log_change()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  insert into plan_changelog (changed_by, table_name, action, old_data, new_data)
  values (
    coalesce(auth.jwt()->>'email', 'system'),
    tg_table_name, tg_op,
    case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
    case when tg_op in ('UPDATE','INSERT') then to_jsonb(new) end
  );
  return coalesce(new, old);
end $function$;

-- Holder punkt-allokeringers periode i sync med punktets periode.
create or replace function public.plan_sync_alloc_period()
 returns trigger
 language plpgsql
 set search_path to 'public'
as $function$
begin
  update plan_allocations set from_m = new.from_m, to_m = new.m where milestone_id = new.id;
  return new;
end $function$;

revoke execute on function public.plan_can_edit(), public.plan_can_read(),
  public.plan_log_change(), public.plan_sync_alloc_period() from public, anon;
grant execute on function public.plan_can_edit(), public.plan_can_read() to authenticated;

-- ---------------------------------------------------------------------------
-- Triggere
-- ---------------------------------------------------------------------------

create trigger trg_log_change after insert or delete or update on public.plan_people
  for each row execute function plan_log_change();
create trigger trg_log_change after insert or delete or update on public.plan_departments
  for each row execute function plan_log_change();
create trigger trg_log_change after insert or delete or update on public.plan_tracks
  for each row execute function plan_log_change();
create trigger trg_log_change after insert or delete or update on public.plan_milestones
  for each row execute function plan_log_change();
create trigger trg_log_change after insert or delete or update on public.plan_allocations
  for each row execute function plan_log_change();
create trigger trg_log_change after insert or delete or update on public.plan_dependencies
  for each row execute function plan_log_change();
create trigger trg_log_change after insert or delete or update on public.plan_subtasks
  for each row execute function plan_log_change();

create trigger trg_plan_sync_alloc_period after update of from_m, m on public.plan_milestones
  for each row execute function plan_sync_alloc_period();

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.plan_people       enable row level security;
alter table public.plan_departments  enable row level security;
alter table public.plan_tracks       enable row level security;
alter table public.plan_milestones   enable row level security;
alter table public.plan_allocations  enable row level security;
alter table public.plan_dependencies enable row level security;
alter table public.plan_subtasks     enable row level security;
alter table public.plan_changelog    enable row level security;
alter table public.plan_readonly     enable row level security;

-- Samme fire policies paa alle redigerbare plan-tabeller.
do $$
declare t text;
begin
  foreach t in array array['plan_people','plan_departments','plan_tracks','plan_milestones',
                           'plan_allocations','plan_dependencies','plan_subtasks'] loop
    execute format('create policy "plan read" on public.%I for select to authenticated using (plan_can_read())', t);
    execute format('create policy "plan insert" on public.%I for insert to authenticated with check (plan_can_edit())', t);
    execute format('create policy "plan update" on public.%I for update to authenticated using (plan_can_edit()) with check (plan_can_edit())', t);
    execute format('create policy "plan delete" on public.%I for delete to authenticated using (plan_can_edit())', t);
  end loop;
end $$;

-- Changelog: kun topas.dk (ikke gaester). Skrives kun af triggeren.
create policy "topas users read" on public.plan_changelog for select to authenticated
  using ((auth.jwt() ->> 'email'::text) ~~* '%@topas.dk'::text);

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------

alter publication supabase_realtime add table
  public.plan_people, public.plan_departments, public.plan_tracks, public.plan_milestones,
  public.plan_allocations, public.plan_dependencies, public.plan_subtasks, public.plan_changelog;
