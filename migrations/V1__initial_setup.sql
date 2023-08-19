create extension if not exists pg_trgm;

create or replace function array_to_string_immutable (
    arg text[],
    separator text,
    null_string text default null)
returns text immutable parallel safe language sql as $$
select array_to_string(arg,separator,null_string) $$;

create table if not exists people (
    id         uuid unique ,
    apelido    varchar(32) unique,
    nome       varchar(100),
    nascimento date,
    stack      text[] null,
    for_search text generated always as (
        lower(apelido) || ' ' ||
        lower(nome)    || ' ' ||
        coalesce(lower(array_to_string_immutable(stack, ' '::text)), ''::text)
    ) stored
);

create index if not exists people_id_idx
on people (id);

create index if not exists people_for_search_gin_trgm_idx
on people
using gin (for_search gin_trgm_ops);

-- create index people_for_search_gist_trgm_idx
-- on people
-- using gist (for_search gist_trgm_ops);

