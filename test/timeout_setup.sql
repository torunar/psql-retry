begin;

create table if not exists test_lock (
    id serial primary key,
    value text
);

insert into test_lock (id, value) values (1, 'one'), (2, 'two') on conflict do nothing;

commit;

begin;

select * from test_lock where id = 1 for update;

select pg_sleep(100);
