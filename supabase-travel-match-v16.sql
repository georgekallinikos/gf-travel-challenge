-- GoFerry Travel Match v0.16
-- Backward-compatible migration from 8 to 6 questions.
-- Retained questions: destination, companions, season, vehicle, trip style,
-- and booking motivator.

create or replace function public.tm_submit_answers(
  p_token text,
  p_role text,
  p_answers smallint[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  h smallint[];
  g smallint[];
  hn smallint[];
  gn smallint[];
  calculated_score smallint;
begin
  if p_role not in ('host', 'friend') then
    raise exception 'Invalid player role';
  end if;
  if array_length(p_answers, 1) not in (6, 8)
     or exists (select 1 from unnest(p_answers) as x(value) where value < 0 or value > 3) then
    raise exception 'Invalid answers';
  end if;

  perform 1 from public.travel_matches where invite_token = p_token for update;
  if not found then raise exception 'Travel Match not found'; end if;

  if p_role = 'host' then
    update public.travel_matches
       set host_answers = p_answers, host_completed_at = now(), updated_at = now()
     where invite_token = p_token;
  else
    update public.travel_matches
       set guest_answers = p_answers, guest_completed_at = now(), updated_at = now()
     where invite_token = p_token;
  end if;

  select host_answers, guest_answers into h, g
    from public.travel_matches where invite_token = p_token;

  if h is not null and g is not null then
    hn := case array_length(h, 1)
      when 8 then array[h[1], h[2], h[3], h[4], h[5], h[8]]
      when 6 then h
    end;
    gn := case array_length(g, 1)
      when 8 then array[g[1], g[2], g[3], g[4], g[5], g[8]]
      when 6 then g
    end;

    if hn is null or gn is null then
      raise exception 'Stored answers use an unsupported format';
    end if;

    select round(100.0 * count(*) filter (where hn[i] = gn[i]) / 6)::smallint
      into calculated_score from generate_series(1, 6) i;
    update public.travel_matches
       set match_score = calculated_score, updated_at = now()
     where invite_token = p_token;
  end if;

  return jsonb_build_object(
    'host_complete', h is not null,
    'guest_complete', g is not null,
    'score', calculated_score
  );
end;
$$;

revoke all on function public.tm_submit_answers(text,text,smallint[]) from public;
grant execute on function public.tm_submit_answers(text,text,smallint[]) to anon, authenticated;

-- Recalculate existing completed matches using the same six retained questions.
do $$
declare
  r record;
  hn smallint[];
  gn smallint[];
  recalculated_score smallint;
begin
  for r in
    select id, host_answers, guest_answers
      from public.travel_matches
     where host_answers is not null and guest_answers is not null
  loop
    hn := case array_length(r.host_answers, 1)
      when 8 then array[r.host_answers[1], r.host_answers[2], r.host_answers[3], r.host_answers[4], r.host_answers[5], r.host_answers[8]]
      when 6 then r.host_answers
    end;
    gn := case array_length(r.guest_answers, 1)
      when 8 then array[r.guest_answers[1], r.guest_answers[2], r.guest_answers[3], r.guest_answers[4], r.guest_answers[5], r.guest_answers[8]]
      when 6 then r.guest_answers
    end;
    if hn is not null and gn is not null then
      select round(100.0 * count(*) filter (where hn[i] = gn[i]) / 6)::smallint
        into recalculated_score from generate_series(1, 6) i;
      update public.travel_matches
         set match_score = recalculated_score, updated_at = now()
       where id = r.id;
    end if;
  end loop;
end;
$$;
