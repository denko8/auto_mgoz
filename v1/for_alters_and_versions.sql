--Скрипт формирующий функции и таблицы для того, чтобы можно было применять альтеры


CREATE TABLE dv.adm_databaseversions (
	id bigserial NOT NULL,
	"version" varchar(20) NOT NULL,
	released timestamp NULL,
	"comments" varchar(2000) NULL,
	status_id int2 NOT NULL DEFAULT 0,
	author varchar(100) NOT NULL,
	CONSTRAINT adm_databaseversions_pkey PRIMARY KEY (id)
);


-- Глобальные переменные
CREATE TABLE IF NOT EXISTS global_vars (name TEXT PRIMARY KEY, value numeric);

-- установка переменной
CREATE OR REPLACE FUNCTION put_var(key TEXT, data numeric) RETURNS VOID AS '
  BEGIN
    LOOP
        UPDATE global_vars SET value = data WHERE name = key;
        IF found THEN
            RETURN;
        END IF;
        BEGIN
            INSERT INTO global_vars(name,value) VALUES (key, data);
            RETURN;
        EXCEPTION WHEN unique_violation THEN
            -- do nothing, and loop to try the UPDATE again
        END;
    END LOOP;
  END;
' LANGUAGE plpgsql;

-- получение переменной
CREATE OR REPLACE FUNCTION get_var(key TEXT) RETURNS numeric AS '
  DECLARE
    result TEXT;
  BEGIN
    SELECT value FROM global_vars where name = key INTO result;
    RETURN result;
  END;
' LANGUAGE plpgsql;


-- удаление переменной
CREATE OR REPLACE FUNCTION del_var(key TEXT) RETURNS VOID AS '
  BEGIN
    DELETE FROM global_vars WHERE name = key;
  END;
' LANGUAGE plpgsql;

-- проверка версии
create or replace function PC_VALIDATE_DB_VERSION_VALID (p_newVersion varchar,
p_minVersion varchar,
p_author varchar,
p_comment varchar)
returns void
as $$
#variable_conflict use_column
declare
  cnt numeric;
  currentVersion varchar(20);
begin
  select MAX(version)
  into strict currentVersion
  from adm_databaseversions 
  ;
  raise notice '%', 'Current database version - ' || currentVersion;
  raise notice '%', 'New database version - ' || p_newVersion;
  raise notice '%', 'Minimum database version - ' || p_minVersion;
  if p_minVersion -- не требуется проверка
   = '1.0.0' then
    return;
  end if;
  select count(*)
  into strict cnt
  from ADM_DATABASEVERSIONS
  where Version = p_minVersion
  ;
  if cnt = 0 then
    raise exception '%s', 'Mandatory update ' || p_minVersion || ' not found!' using errcode = 'AA001';
  end if;
exception
  when OTHERS
  then
    raise notice '%', 'Error on validate version = ' || SQLERRM;
    raise;
end;
$$
language plpgsql;

-- запись в версионную таблицу
create or replace function PC_VALIDATE_DB_VERSION_SUCCESS (p_newVersion varchar,
p_minVersion varchar,
p_author varchar,
p_comment varchar)
returns void
as $$
#variable_conflict use_column
declare
  currentVersion varchar(20);
  err_msg varchar(250);
  mid numeric(10);
begin
  delete from -- обновление триггеров для таблиц аудита
  --pc_audit.create_audit_triggers();
   adm_databaseversions
  where Version = p_newVersion;
  select MAX(id) into strict mid from adm_databaseversions ; 
  select case when mid is null then 0 else mid end into mid; 
  insert into -- вставляем метку о начале выполнения скрипта
   adm_databaseversions(id, Version, released, comments, status_id, author)
  values (mid + 1, p_newVersion,
  current_timestamp,
  p_comment,
  1,
  p_author); 
  select version
   into strict currentVersion
   from  ADM_DATABASEVERSIONS
   WHERE STATUS_ID = 1
   order by id desc
   limit 1;
 
  raise notice '%', 'Database success update to version ' || p_newVersion || '!';
exception
  when OTHERS
  then
    err_msg := SUBSTR(SQLERRM, 1, 250);
    raise notice '%', 'ERROR - ' || err_msg;
end;
$$
language plpgsql;

-- пулучение начального шага
create or replace function ADV_SCRIPTING_GET_START_STEP ()
returns numeric
as $$
#variable_conflict use_column
begin
  return get_var('start_step');
end;
$$
language plpgsql;

-- получение завершающего шага
create or replace function ADV_SCRIPTING_GET_STOP_STEP ()
returns numeric
as $$
#variable_conflict use_column
begin
  return stop_step;
end;
$$
language plpgsql;

-- завершение выполнения
create or replace function ADV_SCRIPTING_EXEC_STATEMENT (current_step numeric,
sql_statement varchar,
comments varchar)
returns void
as $$
#variable_conflict use_column
declare
  err_num varchar;
  err_msg varchar(250);
  out_msg varchar(1000);
  raise_again boolean;
  error_fl boolean;
  st_time varchar(25);
  end_time varchar(25);
begin    

  if current_step >= get_var('start_step') and (get_var('stop_step') = 0 or current_step <= get_var('stop_step')) then
    raise_again := false;
    err_num := '0';
    error_fl := false;
    begin
      st_time := to_char(current_timestamp, 'yyyymmdd hh24:mi:ss');
      -- замены
      select REGEXP_REPLACE(sql_statement, '[ ]{1}ID[ ]+NUMBER [(]10[)]', 'ID SERIAL') into sql_statement;
      select REPLACE(sql_statement, 'VARCHAR2', 'VARCHAR') into sql_statement;
      select REPLACE(sql_statement, 'NUMBER (1) DEFAULT 0', 'SMALLINT') into sql_statement;
      select REPLACE(sql_statement, 'NUMBER (1) DEFAULT 1', 'SMALLINT') into sql_statement;
      select REPLACE(sql_statement, 'NUMBER (1)', 'SMALLINT') into sql_statement;
      select REPLACE(sql_statement, 'NUMBER (10)', 'BIGINT') into sql_statement;
      select REPLACE(sql_statement, ' CHAR)', ')') into sql_statement;
      select REPLACE(sql_statement, 'NUMBER', 'NUMERIC') into sql_statement;
      select REPLACE(sql_statement, 'sysdate', 'current_date') into sql_statement;      
      select REPLACE(sql_statement, 'NOSORT', '') into sql_statement;
      select REPLACE(sql_statement, 'NOLOGGING', '') into sql_statement;
      select REPLACE(sql_statement, 'LOGGING', '') into sql_statement;
      select REPLACE(sql_statement, 'CLOB', 'TEXT') into sql_statement;
      select REPLACE(sql_statement, 'BLOB', 'VARCHAR') into sql_statement;
      select REPLACE(sql_statement, 'RAW', 'VARCHAR') into sql_statement;
      select REPLACE(sql_statement, 'CASCADE CONSTRAINTS', 'CASCADE') into sql_statement;    

      if sql_statement like '%ALTER TABLE%' then 
       if sql_statement not like '%ADD CONSTRAINT%' then
         -- убираем скобки при добавлении нового поля
         select REGEXP_REPLACE(sql_statement, '[(]\s+\n', '') into sql_statement;
         select REGEXP_REPLACE(sql_statement, '[)]\s+\n', '') into sql_statement;        
       end if; 

       if sql_statement like '%MODIFY%' then
           select REGEXP_REPLACE(sql_statement, 'MODIFY\s+[(]', 'ALTER COLUMN') into sql_statement;
        select REGEXP_REPLACE(sql_statement, '[)]\s+\n', '') into sql_statement;
        select REGEXP_REPLACE(sql_statement, 'DEFAULT', 'SET DEFAULT') into sql_statement;
        select REGEXP_REPLACE(sql_statement, 'NUMERIC', 'TYPE NUMERIC') into sql_statement;
        select REGEXP_REPLACE(sql_statement, 'VARCHAR', 'TYPE VARCHAR') into sql_statement;
        select REGEXP_REPLACE(sql_statement, 'BIGINT', 'TYPE BIGINT') into sql_statement;
        select REGEXP_REPLACE(sql_statement, 'SMALLINT', 'TYPE SMALLINT') into sql_statement;
       end if;

      end if;    

      if sql_statement like '%CREATE SEQUENCE%' then return; end if;
      if sql_statement like '%CREATE OR REPLACE TRIGGER%' then return; end if;

      execute sql_statement;
      end_time := to_char(current_timestamp, 'yyyymmdd hh24:mi:ss');
    exception
      when others      
      then
        err_msg := SUBSTR(SQLERRM, 1, 250);
        end_time := to_char(current_timestamp, 'yyyymmdd hh24:mi:ss');
        error_fl := true;
        if err_msg = '' then
          out_msg := ' Ok ';  
        else
          raise_again := true;
          out_msg := ' Error ' || SQLSTATE;
        end if;
        raise notice '%', 'Step ' || current_step || out_msg || '  time: ' || st_time || ' - ' || end_time;
        if get_var('log_options') = 2 then
          raise notice '%', comments;  
        elsif get_var('log_options') = 3 then
          raise notice '%', substr(sql_statement, 1, 250);
        end if;
        if out_msg != ' Ok ' then
          raise notice '%', '';
          raise notice '%', err_msg;
        end if;
        raise notice '%', '';
        raise notice '%', '';
        if raise_again then
          raise;
        end if;
    end;
    if not error_fl then
      out_msg := ' Ok ';
      raise notice '%', 'Step ' || current_step || out_msg || '  time: ' || st_time || ' - ' || end_time;
      if get_var('log_options') = 2 then
        raise notice '%', comments;  
      elsif get_var('log_options') = 3 then
        raise notice '%', substr(sql_statement, 1, 250);
      end if;
      raise notice '%', '';
      raise notice '%', '';
    end if;
  end if;
end;
$$
language plpgsql;

-- инициализация
create or replace function ADV_SCRIPTING_INIT_STEPS (start_step_in numeric,
stop_step_in numeric,
log_option_in numeric)
returns void
as $$
#variable_conflict use_column
begin
   perform put_var('start_step', start_step_in);
   perform put_var('stop_step', stop_step_in); 
   perform put_var('log_options', log_option_in); 
end;
$$
language plpgsql;

ALTER ROLE data SET search_path TO dv;

DO $$DECLARE r record;
DECLARE
    v_schema varchar := 'dv';
    v_new_owner varchar := 'data';
BEGIN
    FOR r IN 
        select 'ALTER TABLE "' || table_schema || '"."' || table_name || '" OWNER TO ' || v_new_owner || ';' as a from information_schema.tables where table_schema = v_schema
        union all
        select 'ALTER TABLE "' || sequence_schema || '"."' || sequence_name || '" OWNER TO ' || v_new_owner || ';' as a from information_schema.sequences where sequence_schema = v_schema
        union all
        select 'ALTER TABLE "' || table_schema || '"."' || table_name || '" OWNER TO ' || v_new_owner || ';' as a from information_schema.views where table_schema = v_schema
        union all
        select 'ALTER FUNCTION "'||nsp.nspname||'"."'||p.proname||'"('||pg_get_function_identity_arguments(p.oid)||') OWNER TO ' || v_new_owner || ';' as a from pg_proc p join pg_namespace nsp ON p.pronamespace = nsp.oid where nsp.nspname = v_schema
    LOOP
        EXECUTE r.a;
    END LOOP;
END$$;


-- Cкрипт, формирующий в БД табличку для ведения установленных версий 

CREATE TABLE meta.versions (
    id SERIAL PRIMARY KEY,
    version_name VARCHAR(255) NOT NULL,
    applied_at TIMESTAMP NOT NULL
);

DO $$DECLARE r record;
DECLARE
    v_schema varchar := 'meta';
    v_new_owner varchar := 'meta';
BEGIN
    FOR r IN 
        select 'ALTER TABLE "' || table_schema || '"."' || table_name || '" OWNER TO ' || v_new_owner || ';' as a from information_schema.tables where table_schema = v_schema
        union all
        select 'ALTER TABLE "' || sequence_schema || '"."' || sequence_name || '" OWNER TO ' || v_new_owner || ';' as a from information_schema.sequences where sequence_schema = v_schema
        union all
        select 'ALTER TABLE "' || table_schema || '"."' || table_name || '" OWNER TO ' || v_new_owner || ';' as a from information_schema.views where table_schema = v_schema
        union all
        select 'ALTER FUNCTION "'||nsp.nspname||'"."'||p.proname||'"('||pg_get_function_identity_arguments(p.oid)||') OWNER TO ' || v_new_owner || ';' as a from pg_proc p join pg_namespace nsp ON p.pronamespace = nsp.oid where nsp.nspname = v_schema
    LOOP
        EXECUTE r.a;
    END LOOP;
END$$;