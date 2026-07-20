-- BAC 2K27 registrations: run this migration in the Supabase SQL editor.
-- The RPC below is the authority for capacity; the browser must not allocate seats itself.

create table if not exists public.registrations (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  normalized_full_name text not null,
  phone text,
  stream text not null,
  math_average numeric(4,2),
  general_average numeric(4,2),
  status text not null check (status in ('confirmed', 'waitlist')),
  parent_id uuid references public.registrations(id),
  created_at timestamptz not null default timezone('utc', now())
);

create unique index if not exists registrations_phone_unique
  on public.registrations(phone) where phone is not null;
create unique index if not exists registrations_normalized_name_unique
  on public.registrations(normalized_full_name);
create index if not exists registrations_status_created_at_idx
  on public.registrations(status, created_at, id);

-- Public clients call the function, not the table. Adjust roles if you use Supabase Auth.
alter table public.registrations enable row level security;
revoke all on public.registrations from anon, authenticated;

create or replace function public.get_bac_capacity()
returns integer
language sql
security definer
set search_path = public
as $$ select count(*)::integer from public.registrations where status = 'confirmed'; $$;
revoke all on function public.get_bac_capacity() from public;
grant execute on function public.get_bac_capacity() to anon, authenticated;

create or replace function public.register_bac_student(
  p_full_name text,
  p_normalized_full_name text,
  p_phone text,
  p_stream text,
  p_math_average numeric,
  p_general_average numeric,
  p_sibling jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := timezone('utc', now());
  v_existing uuid;
  v_confirmed integer;
  v_primary_status text;
  v_sibling_status text := null;
  v_primary_id uuid;
  v_primary_queue integer;
  v_waitlist_pos integer;
  v_sibling_name text;
  v_sibling_normalized text;
begin
  -- A transaction-level lock serializes allocation so two requests cannot claim seat 225.
  perform pg_advisory_xact_lock(2027, 225);

  if p_full_name is null or btrim(p_full_name) = '' or p_phone !~ '^0[567][0-9]{8}$'
     or p_stream not in ('علوم تجريبية', 'رياضيات', 'تقني رياضي')
     or p_math_average not between 0 and 20 or p_general_average not between 0 and 20 then
    raise exception 'بيانات التسجيل غير صالحة';
  end if;

  if p_sibling is not null then
    v_sibling_name := nullif(btrim(p_sibling->>'full_name'), '');
    v_sibling_normalized := lower(regexp_replace(
      translate(coalesce(v_sibling_name,''), 'إأآىة', 'ااايه'), '\s+', ' ', 'g'));
    if v_sibling_name is null
       or p_sibling->>'stream' not in ('علوم تجريبية', 'رياضيات', 'تقني رياضي')
       or (p_sibling->>'math_average')::numeric not between 0 and 20
       or (p_sibling->>'general_average')::numeric not between 0 and 20 then
      raise exception 'بيانات الأخ أو الأخت غير مكتملة';
    end if;
  end if;

  select id into v_existing from public.registrations
   where phone = p_phone or normalized_full_name = p_normalized_full_name
      or (v_sibling_name is not null and normalized_full_name = v_sibling_normalized)
   limit 1;
  if v_existing is not null then
    raise exception 'يوجد تسجيل سابق بنفس رقم الهاتف أو الاسم';
  end if;

  select count(*) into v_confirmed from public.registrations where status = 'confirmed';
  v_primary_status := case when v_confirmed < 225 then 'confirmed' else 'waitlist' end;

  insert into public.registrations
    (full_name, normalized_full_name, phone, stream, math_average, general_average, status, created_at)
  values
    (btrim(p_full_name), p_normalized_full_name, p_phone, p_stream, p_math_average, p_general_average, v_primary_status, v_now)
  returning id into v_primary_id;

  if v_sibling_name is not null then
    -- Recount after the primary insert: if one seat remained, exactly one sibling is waitlisted.
    select count(*) into v_confirmed from public.registrations where status = 'confirmed';
    v_sibling_status := case when v_confirmed < 225 then 'confirmed' else 'waitlist' end;
    insert into public.registrations
      (full_name, normalized_full_name, stream, math_average, general_average, status, parent_id, created_at)
    values
      (v_sibling_name, v_sibling_normalized, p_sibling->>'stream',
       (p_sibling->>'math_average')::numeric, (p_sibling->>'general_average')::numeric,
       v_sibling_status, v_primary_id, v_now);
  end if;

  if v_primary_status = 'confirmed' then
    select count(*) into v_primary_queue from public.registrations
      where status = 'confirmed' and (created_at < v_now or (created_at = v_now and id = v_primary_id));
  else
    select count(*) into v_waitlist_pos from public.registrations
      where status = 'waitlist' and (created_at < v_now or (created_at = v_now and id = v_primary_id));
  end if;

  return jsonb_build_object(
    'status', v_primary_status,
    'queue_number', case when v_primary_status = 'confirmed' then v_primary_queue else null end,
    'waitlist_position', case when v_primary_status = 'waitlist' then v_waitlist_pos else null end,
    'confirmed_count', (case when v_primary_status = 'confirmed' then 1 else 0 end) +
                       (case when v_sibling_status = 'confirmed' then 1 else 0 end),
    'sibling_status', v_sibling_status
  );
end;
$$;

revoke all on function public.register_bac_student(text, text, text, text, numeric, numeric, jsonb) from public;
grant execute on function public.register_bac_student(text, text, text, text, numeric, numeric, jsonb) to anon, authenticated;
