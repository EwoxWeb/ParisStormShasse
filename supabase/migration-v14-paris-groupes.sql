-- =====================================================================
-- Migration v14 : enregistrer les deux paris ensemble
-- À lancer UNE SEULE FOIS (après la v13).
-- =====================================================================

begin;

create or replace function public.place_two_bets(p_hunt uuid, p_guess1 integer, p_guess2 integer)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'COMPTE_TWITCH_REQUIS'; end if;
  if p_guess1 is null or p_guess2 is null
     or p_guess1 not between 1 and 10000000
     or p_guess2 not between 1 and 10000000 then
    raise exception 'NOMBRES_INVALIDES';
  end if;
  if p_guess1 = p_guess2 then raise exception 'PARI_DEJA_JOUE'; end if;

  insert into public.bets (hunt_id, guess) values (p_hunt, p_guess1);
  insert into public.bets (hunt_id, guess) values (p_hunt, p_guess2);
end;
$$;

revoke execute on function public.place_two_bets(uuid, integer, integer) from public, anon;
grant execute on function public.place_two_bets(uuid, integer, integer) to authenticated;

commit;
