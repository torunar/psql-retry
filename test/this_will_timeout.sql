set lock_timeout = '1s';

select * from test_lock where id = 1 for update;
