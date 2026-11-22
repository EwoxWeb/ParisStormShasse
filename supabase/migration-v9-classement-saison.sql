-- =====================================================================
-- Migration v9 : date des résultats, nécessaire au classement de la Saison 2
-- À lancer UNE SEULE FOIS (après la v8).
-- Les anciens résultats restent sans date et ne sont donc pas recomptés.
-- =====================================================================

begin;

alter table public.hunts add column result_at timestamptz;

create or replace function public.set_hunt_result_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.status = 'finished' and new.result is not null then
    if tg_op = 'INSERT' then
      new.result_at := now();
    elsif old.status <> 'finished' or old.result is distinct from new.result then
      new.result_at := now();
    else
      new.result_at := old.result_at;
    end if;
  else
    new.result_at := null;
  end if;
  return new;
end;
$$;

create trigger hunts_set_result_at before insert or update on public.hunts
  for each row execute function public.set_hunt_result_at();

commit;
