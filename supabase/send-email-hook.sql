-- SBR_CUTZZ : envoi des codes de connexion clients via l'API Brevo (même chemin que les e-mails de confirmation)
-- À coller dans Supabase › SQL Editor › Run, puis activer dans Authentication › Hooks › « Send Email hook »
-- (type Postgres, fonction public.send_auth_email). Peut être relancé sans risque.

create or replace function public.send_auth_email(event jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  n private.notify;
  to_email text := event -> 'user' ->> 'email';
  code text := event -> 'email_data' ->> 'token';
  en boolean := coalesce(event -> 'user' -> 'user_metadata' ->> 'lang', '') = 'en';
  body text;
begin
  select * into n from private.notify where id = 1;
  if coalesce(n.brevo_key, '') = '' or coalesce(to_email, '') = '' or coalesce(code, '') = '' then
    return jsonb_build_object('error', jsonb_build_object('http_code', 500, 'message', 'email_not_configured'));
  end if;

  body := '<div style="font-family:Arial,Helvetica,sans-serif;max-width:520px;margin:0 auto;padding:24px;color:#161412">'
    || '<p style="font-size:22px;font-weight:900;letter-spacing:3px;margin:0 0 18px">SBR<span style="color:#c9a45c">_</span>CUTZZ</p>'
    || '<p style="font-size:16px">Ton code de connexion / Your sign-in code :</p>'
    || '<p style="font-size:32px;font-weight:bold;letter-spacing:8px;margin:12px 0">' || code || '</p>'
    || '<p style="font-size:13px;color:#777">Valable 1 heure. Si tu n''as rien demandé, ignore cet e-mail.<br>'
    || 'Valid for 1 hour. If you didn''t ask for it, just ignore this email.</p></div>';

  perform net.http_post(
    url := 'https://api.brevo.com/v3/smtp/email',
    body := jsonb_build_object(
      'sender', jsonb_build_object('name', n.sender_name, 'email', n.sender_email),
      'to', jsonb_build_array(jsonb_build_object('email', to_email)),
      'subject', 'Ton code SBR_CUTZZ : ' || code,
      'htmlContent', body),
    headers := jsonb_build_object('Content-Type', 'application/json', 'accept', 'application/json', 'api-key', n.brevo_key));
  return '{}'::jsonb;
end $$;

revoke all on function public.send_auth_email(jsonb) from public, anon, authenticated;
grant usage on schema public to supabase_auth_admin;
grant execute on function public.send_auth_email(jsonb) to supabase_auth_admin;
