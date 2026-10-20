-- SBR_CUTZZ : base de données Supabase (réservations, créneaux bloqués, réglages du site)
-- À coller tel quel dans Supabase › SQL Editor › New query › Run. Peut être relancé sans risque.
-- Aucun secret ici : le canal de notification se règle à part (voir notify-setup.sql, non publié).

create extension if not exists pg_net with schema extensions;
create extension if not exists pgcrypto with schema extensions;

-- Réglages publics du site (une seule ligne) : bannière promo et horaires
create table if not exists public.settings (
  id int primary key default 1 check (id = 1),
  banner_fr text not null default '',
  banner_en text not null default '',
  open_time time not null default '10:00',
  close_time time not null default '22:00',
  slot_minutes int not null default 40 check (slot_minutes between 10 and 180),
  max_days_ahead int not null default 60 check (max_days_ahead between 1 and 365),
  updated_at timestamptz not null default now()
);
insert into public.settings (id) values (1) on conflict (id) do nothing;

create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(),
  ref text not null unique,
  day date not null,
  slot time not null,
  first_name text not null check (char_length(first_name) between 1 and 60),
  last_name text not null check (char_length(last_name) between 1 and 60),
  phone text not null check (char_length(phone) between 6 and 25),
  email text check (email is null or char_length(email) <= 120),
  lang text not null default 'fr' check (lang in ('fr', 'en')),
  status text not null default 'confirmed' check (status in ('confirmed', 'done', 'no_show', 'cancelled')),
  created_at timestamptz not null default now()
);
-- Un seul rendez-vous actif par créneau : c'est la base qui empêche les doublons
create unique index if not exists bookings_one_per_slot on public.bookings (day, slot) where status <> 'cancelled';
create index if not exists bookings_day on public.bookings (day);
-- Compte client (facultatif) : lien entre la réservation et le compte qui l'a faite
alter table public.bookings add column if not exists user_id uuid references auth.users (id) on delete set null;
create index if not exists bookings_user on public.bookings (user_id);

-- Créneaux bloqués par Sabri (slot vide = journée entière)
create table if not exists public.blocks (
  id uuid primary key default gen_random_uuid(),
  day date not null,
  slot time,
  note text not null default '',
  created_at timestamptz not null default now()
);
create unique index if not exists blocks_unique on public.blocks (day, coalesce(slot, '00:00'::time));

-- Comptes autorisés à l'espace admin (adresses e-mail, remplies dans notify-setup.sql)
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create table if not exists private.admins (email text primary key);

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from private.admins a where lower(a.email) = lower(coalesce(auth.jwt() ->> 'email', '')))
$$;
revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to anon, authenticated;

-- Sécurité : les visiteurs ne lisent que les réglages ; tout le reste passe par les fonctions ci-dessous.
-- Seuls les comptes listés dans private.admins (toi et Sabri) gèrent le reste.
alter table public.settings enable row level security;
alter table public.bookings enable row level security;
alter table public.blocks enable row level security;

drop policy if exists settings_read on public.settings;
create policy settings_read on public.settings for select to anon, authenticated using (true);
drop policy if exists settings_admin on public.settings;
create policy settings_admin on public.settings for update to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists bookings_admin on public.bookings;
create policy bookings_admin on public.bookings for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Un client connecté voit ses propres rendez-vous (faits avec son compte ou avec la même adresse e-mail)
drop policy if exists bookings_own on public.bookings;
create policy bookings_own on public.bookings for select to authenticated
  using (user_id = auth.uid() or lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));

drop policy if exists blocks_admin on public.blocks;
create policy blocks_admin on public.blocks for all to authenticated using (public.is_admin()) with check (public.is_admin());

revoke all on public.bookings, public.blocks from anon;
revoke insert, update, delete on public.settings from anon;
grant select on public.settings to anon, authenticated;
grant update on public.settings to authenticated;
grant select, insert, update, delete on public.bookings, public.blocks to authenticated;

-- Date et heure actuelles à Melbourne
create or replace function public.melb_now() returns timestamp
language sql stable set search_path = '' as $$ select now() at time zone 'Australia/Melbourne' $$;

-- Créneaux indisponibles entre deux dates (sans aucune donnée client)
create or replace function public.get_unavailable(p_from date, p_to date)
returns table (day date, slot time)
language sql stable security definer set search_path = '' as $$
  select b.day, b.slot from public.bookings b
   where b.status <> 'cancelled' and b.day between p_from and least(p_to, p_from + 92)
  union
  select k.day, k.slot from public.blocks k
   where k.day between p_from and least(p_to, p_from + 92)
$$;

-- Réservation par un client : vérifie tout côté serveur et renvoie le numéro de réservation
create or replace function public.book(
  p_day date, p_slot time, p_first_name text, p_last_name text,
  p_phone text, p_email text default null, p_lang text default 'fr'
) returns text
language plpgsql volatile security definer set search_path = '' as $$
declare
  s public.settings;
  now_l timestamp := public.melb_now();
  mins int;
  open_m int;
  close_m int;
  digits text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  uid uuid := auth.uid();
  new_ref text;
  alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  select * into s from public.settings where id = 1;
  mins := extract(hour from p_slot)::int * 60 + extract(minute from p_slot)::int;
  open_m := extract(hour from s.open_time)::int * 60 + extract(minute from s.open_time)::int;
  close_m := extract(hour from s.close_time)::int * 60 + extract(minute from s.close_time)::int;

  if p_day is null or p_slot is null or p_day < now_l::date or p_day > now_l::date + s.max_days_ahead then
    raise exception 'invalid_day' using errcode = 'P0001';
  end if;
  if mins < open_m or mins + s.slot_minutes > close_m or (mins - open_m) % s.slot_minutes <> 0
     or extract(second from p_slot) <> 0 then
    raise exception 'invalid_slot' using errcode = 'P0001';
  end if;
  if p_day + p_slot < now_l + interval '30 minutes' then
    raise exception 'too_late' using errcode = 'P0001';
  end if;
  if coalesce(trim(p_first_name), '') = '' or coalesce(trim(p_last_name), '') = ''
     or length(digits) not between 8 and 15 then
    raise exception 'invalid_details' using errcode = 'P0001';
  end if;
  if p_email is not null and trim(p_email) <> '' and trim(p_email) !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    raise exception 'invalid_details' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.blocks k where k.day = p_day and (k.slot is null or k.slot = p_slot)) then
    raise exception 'slot_taken' using errcode = 'P0001';
  end if;
  -- Anti-abus : 3 rendez-vous à venir maximum par numéro de téléphone
  if (select count(*) from public.bookings b
       where regexp_replace(b.phone, '\D', '', 'g') = digits
         and b.status = 'confirmed' and b.day >= now_l::date) >= 3 then
    raise exception 'too_many' using errcode = 'P0001';
  end if;

  loop
    new_ref := 'SBR-';
    for i in 1..6 loop
      new_ref := new_ref || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.bookings where ref = new_ref);
  end loop;

  -- Client connecté : la réservation est rattachée à son compte (et à son e-mail s'il n'en a pas saisi)
  if uid is not null and coalesce(trim(p_email), '') = '' then
    p_email := auth.jwt() ->> 'email';
  end if;

  begin
    insert into public.bookings (ref, day, slot, first_name, last_name, phone, email, lang, user_id)
    values (new_ref, p_day, p_slot, trim(p_first_name), trim(p_last_name), trim(p_phone),
            nullif(trim(coalesce(p_email, '')), ''), case when p_lang = 'en' then 'en' else 'fr' end, uid);
  exception when unique_violation then
    raise exception 'slot_taken' using errcode = 'P0001';
  end;
  return new_ref;
end $$;

revoke all on function public.get_unavailable(date, date) from public;
revoke all on function public.book(date, time, text, text, text, text, text) from public;
grant execute on function public.get_unavailable(date, date) to anon, authenticated;
grant execute on function public.book(date, time, text, text, text, text, text) to anon, authenticated;

-- Notification à Sabri à chaque nouvelle réservation (ntfy ou Telegram, réglé dans private.notify)
create table if not exists private.notify (
  id int primary key default 1 check (id = 1),
  ntfy_topic text,
  telegram_token text,
  telegram_chat_id text,
  admin_url text not null default 'https://sbr-cutzz.github.io/admin.html'
);
insert into private.notify (id) values (1) on conflict (id) do nothing;
-- E-mails aux clients via Brevo (clé API et expéditeur réglés dans notify-setup.sql, jamais ici)
alter table private.notify add column if not exists brevo_key text;
alter table private.notify add column if not exists sender_email text;
alter table private.notify add column if not exists sender_name text not null default 'SBR_CUTZZ';
alter table private.notify add column if not exists site_url text not null default 'https://sbr-cutzz.github.io/';

create or replace function private.notify_new_booking() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  n private.notify;
  title text;
  msg text;
begin
  select * into n from private.notify where id = 1;
  title := 'Nouvelle réservation · ' || to_char(new.day, 'DD/MM') || ' ' || to_char(new.slot, 'HH24"h"MI');
  msg := new.first_name || ' ' || left(new.last_name, 1) || '. · '
      || (array['Lundi','Mardi','Mercredi','Jeudi','Vendredi','Samedi','Dimanche'])[extract(isodow from new.day)::int]
      || ' ' || to_char(new.day, 'DD/MM') || ' à ' || to_char(new.slot, 'HH24"h"MI')
      || ' · ' || new.ref;
  if coalesce(n.ntfy_topic, '') <> '' then
    perform net.http_post(
      url := 'https://ntfy.sh/',
      body := jsonb_build_object('topic', n.ntfy_topic, 'title', title, 'message', msg,
                                 'tags', jsonb_build_array('scissors'), 'priority', 4, 'click', n.admin_url),
      headers := '{"Content-Type": "application/json"}'::jsonb);
  end if;
  if coalesce(n.telegram_token, '') <> '' and coalesce(n.telegram_chat_id, '') <> '' then
    perform net.http_post(
      url := 'https://api.telegram.org/bot' || n.telegram_token || '/sendMessage',
      body := jsonb_build_object('chat_id', n.telegram_chat_id, 'text', title || E'\n' || msg || E'\n' || n.admin_url),
      headers := '{"Content-Type": "application/json"}'::jsonb);
  end if;
  return new;
exception when others then
  -- Une notification ratée ne doit jamais bloquer la réservation
  return new;
end $$;

drop trigger if exists bookings_notify on public.bookings;
create trigger bookings_notify after insert on public.bookings
  for each row execute function private.notify_new_booking();

-- Annulation par le client lui-même (depuis son compte), jusqu'à 2 h avant le rendez-vous
create or replace function public.cancel_my_booking(p_id uuid) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  b public.bookings;
begin
  select * into b from public.bookings
   where id = p_id and status = 'confirmed'
     and (user_id = auth.uid() or lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')));
  if not found or auth.uid() is null then
    raise exception 'not_found' using errcode = 'P0001';
  end if;
  if b.day + b.slot < public.melb_now() + interval '2 hours' then
    raise exception 'too_late' using errcode = 'P0001';
  end if;
  update public.bookings set status = 'cancelled' where id = p_id;
end $$;
revoke all on function public.cancel_my_booking(uuid) from public, anon;
grant execute on function public.cancel_my_booking(uuid) to authenticated;

-- Date lisible pour les e-mails : « mardi 21 octobre à 14h40 » / « Tuesday 21 October at 2:40 pm »
create or replace function private.when_text(d date, s time, lang text) returns text
language sql immutable set search_path = '' as $$
  select case when lang = 'en' then
      trim(to_char(d, 'FMDay FMDD FMMonth')) || ' at ' || ltrim(to_char(s, 'HH12:MI'), '0') || ' ' || lower(to_char(s, 'am'))
    else
      (array['lundi','mardi','mercredi','jeudi','vendredi','samedi','dimanche'])[extract(isodow from d)::int]
      || ' ' || extract(day from d)::int || ' '
      || (array['janvier','février','mars','avril','mai','juin','juillet','août','septembre','octobre','novembre','décembre'])[extract(month from d)::int]
      || ' à ' || to_char(s, 'HH24"h"MI')
  end
$$;

create or replace function private.html(t text) returns text
language sql immutable set search_path = '' as $$
  select replace(replace(replace(coalesce(t, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;')
$$;

-- E-mail au client : confirmation à la réservation, message quand le rendez-vous est annulé
create or replace function private.email_booking() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  n private.notify;
  en boolean := new.lang = 'en';
  kind text;
  subj text;
  intro text;
  btn_label text;
  btn_url text;
  body text;
begin
  select * into n from private.notify where id = 1;

  if tg_op = 'INSERT' and new.status = 'confirmed' then
    kind := 'confirm';
  elsif tg_op = 'UPDATE' and old.status <> 'cancelled' and new.status = 'cancelled' then
    kind := 'cancel';
    -- Annulé par le client : Sabri est prévenu aussi
    if not public.is_admin() and coalesce(n.ntfy_topic, '') <> '' then
      perform net.http_post(
        url := 'https://ntfy.sh/',
        body := jsonb_build_object('topic', n.ntfy_topic,
          'title', 'Annulation · ' || to_char(new.day, 'DD/MM') || ' ' || to_char(new.slot, 'HH24"h"MI'),
          'message', new.first_name || ' ' || left(new.last_name, 1) || '. a annulé son rendez-vous · ' || new.ref || ' · le créneau est de nouveau libre',
          'tags', jsonb_build_array('x'), 'priority', 4, 'click', n.admin_url),
        headers := '{"Content-Type": "application/json"}'::jsonb);
    end if;
  else
    return new;
  end if;

  if coalesce(new.email, '') = '' or coalesce(n.brevo_key, '') = '' or coalesce(n.sender_email, '') = '' then
    return new;
  end if;

  if kind = 'confirm' then
    subj := case when en then 'Your SBR_CUTZZ appointment is confirmed' else 'Ton rendez-vous chez SBR_CUTZZ est confirmé' end;
    intro := case when en then 'Thanks ' || private.html(new.first_name) || '! Your appointment with Sabri is confirmed:'
                  else 'Merci ' || private.html(new.first_name) || ' ! Ton rendez-vous avec Sabri est confirmé :' end;
    btn_label := case when en then 'Manage my booking' else 'Gérer mon rendez-vous' end;
    btn_url := n.site_url || '#compte';
  else
    subj := case when en then 'Your SBR_CUTZZ appointment has been cancelled' else 'Ton rendez-vous chez SBR_CUTZZ est annulé' end;
    intro := case when en then 'Hi ' || private.html(new.first_name) || ', your appointment has been cancelled:'
                  else 'Salut ' || private.html(new.first_name) || ', ton rendez-vous a été annulé :' end;
    btn_label := case when en then 'Book another time' else 'Reprendre un rendez-vous' end;
    btn_url := n.site_url;
  end if;

  body := '<div style="font-family:Arial,Helvetica,sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#161412">'
    || '<p style="font-size:22px;font-weight:900;letter-spacing:3px;margin:0 0 18px">SBR<span style="color:#c9a45c">_</span>CUTZZ</p>'
    || '<p style="font-size:16px">' || intro || '</p>'
    || '<table style="font-size:15px;border-collapse:collapse;margin:12px 0">'
    || '<tr><td style="padding:4px 16px 4px 0;color:#777">' || case when en then 'When' else 'Quand' end || '</td><td style="font-weight:bold">'
    || private.when_text(new.day, new.slot, new.lang) || '</td></tr>'
    || '<tr><td style="padding:4px 16px 4px 0;color:#777">' || case when en then 'Where' else 'Où' end || '</td><td style="font-weight:bold">340 St Kilda Road, St Kilda VIC 3182</td></tr>'
    || '<tr><td style="padding:4px 16px 4px 0;color:#777">' || case when en then 'Booking no.' else 'N° de réservation' end || '</td><td style="font-weight:bold;font-family:monospace">' || new.ref || '</td></tr>'
    || '</table>'
    || case when kind = 'confirm' then
         '<p style="background:#fff4d6;border:1px solid #f2b632;border-radius:8px;padding:10px;font-size:14px"><b>'
         || case when en then 'WARNING:</b> make sure you go to ST KILDA VIC 3182, not the similar address in Melbourne CBD.'
                 else 'ATTENTION :</b> l''adresse est à ST KILDA VIC 3182, et non l''adresse similaire dans le CBD de Melbourne.' end
         || '</p>'
       else '' end
    || '<p style="margin:22px 0"><a href="' || btn_url || '" style="background:#c9a45c;color:#0c0b0a;text-decoration:none;font-weight:bold;padding:12px 22px;border-radius:999px;display:inline-block">' || btn_label || '</a></p>'
    || '<p style="font-size:13px;color:#777">' || case when en then 'Questions? Message Sabri on WhatsApp: ' else 'Une question ? Écris à Sabri sur WhatsApp : ' end
    || '<a href="https://wa.me/33761541253">+33 7 61 54 12 53</a></p></div>';

  perform net.http_post(
    url := 'https://api.brevo.com/v3/smtp/email',
    body := jsonb_build_object(
      'sender', jsonb_build_object('name', n.sender_name, 'email', n.sender_email),
      'to', jsonb_build_array(jsonb_build_object('email', new.email, 'name', new.first_name || ' ' || new.last_name)),
      'subject', subj,
      'htmlContent', body),
    headers := jsonb_build_object('Content-Type', 'application/json', 'accept', 'application/json', 'api-key', n.brevo_key));
  return new;
exception when others then
  -- Un e-mail raté ne doit jamais bloquer la réservation ni l'annulation
  return new;
end $$;

drop trigger if exists bookings_email on public.bookings;
create trigger bookings_email after insert or update of status on public.bookings
  for each row execute function private.email_booking();
