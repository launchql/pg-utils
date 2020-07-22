\echo Use "CREATE EXTENSION launchql-extension-jobs" to load this file. 
quit CREATE SCHEMA app_jobs;

CREATE TABLE app_jobs.jobs (
  id bigserial PRIMARY KEY,
  queue_name text DEFAULT (public.gen_random_uuid ()::text),
  task_identifier text NOT NULL,
  payload json DEFAULT ('{}'::json) NOT NULL,
  priority int DEFAULT (0) NOT NULL,
  run_at pg_catalog.timestamptz DEFAULT (now()) NOT NULL,
  attempts int DEFAULT (0) NOT NULL,
  max_attempts int DEFAULT (25) NOT NULL,
  last_error text,
  key text,
  locked_at pg_catalog.timestamptz,
  locked_by text,
  CONSTRAINT jobs_key_check CHECK (((length(KEY)) > (0))),
  UNIQUE (KEY)
);

CREATE TABLE app_jobs.job_queues (
  queue_name text NOT NULL PRIMARY KEY,
  job_count int DEFAULT (0) NOT NULL,
  locked_at timestamptz,
  locked_by text
);

CREATE FUNCTION app_jobs.add_job (identifier text, payload json DEFAULT NULL, queue_name text DEFAULT NULL, run_at timestamptz DEFAULT NULL, max_attempts int DEFAULT NULL, job_key text DEFAULT NULL, priority int DEFAULT NULL)
  RETURNS app_jobs.jobs
  AS $EOFCODE$
DECLARE
  v_job app_jobs.jobs;
BEGIN
  -- Apply rationality checks
  IF length(identifier) > 128 THEN
    RAISE exception 'Task identifier is too long (max length: 128).'
      USING errcode = 'GWBID';
  END IF;
  IF queue_name IS NOT NULL AND length(queue_name) > 128 THEN
    RAISE exception 'Job queue name is too long (max length: 128).'
      USING errcode = 'GWBQN';
  END IF;
  IF job_key IS NOT NULL AND length(job_key) > 512 THEN
    RAISE exception 'Job key is too long (max length: 512).'
      USING errcode = 'GWBJK';
  END IF;
  IF max_attempts < 1 THEN
    RAISE exception 'Job maximum attempts must be at least 1'
      USING errcode = 'GWBMA';
  END IF;
  IF job_key IS NOT NULL THEN
    -- Upsert job
    INSERT INTO app_jobs.jobs (task_identifier, payload, queue_name, run_at, max_attempts, KEY, priority)
      VALUES (identifier, coalesce(payload, '{}'::json), queue_name, coalesce(run_at, now()), coalesce(max_attempts, 25), job_key, coalesce(priority, 0))
    ON CONFLICT (KEY)
      DO UPDATE SET
        task_identifier = excluded.task_identifier, payload = excluded.payload, queue_name = excluded.queue_name, max_attempts = excluded.max_attempts, run_at = excluded.run_at, priority = excluded.priority,
        -- always reset error/retry state
        attempts = 0, last_error = NULL
      WHERE
        jobs.locked_at IS NULL
      RETURNING
        * INTO v_job;
    -- If upsert succeeded (insert or update), return early
    IF NOT (v_job IS NULL) THEN
      RETURN v_job;
    END IF;
    -- Upsert failed -> there must be an existing job that is locked. Remove
    -- existing key to allow a new one to be inserted, and prevent any
    -- subsequent retries by bumping attempts to the max allowed.
    UPDATE
      app_jobs.jobs
    SET
      KEY = NULL,
      attempts = jobs.max_attempts
    WHERE
      KEY = job_key;
  END IF;
  -- insert the new job. Assume no conflicts due to the update above
  INSERT INTO app_jobs.jobs (task_identifier, payload, queue_name, run_at, max_attempts, KEY, priority)
    VALUES (identifier, coalesce(payload, '{}'::json), queue_name, coalesce(run_at, now()), coalesce(max_attempts, 25), job_key, coalesce(priority, 0))
  RETURNING
    * INTO v_job;
  RETURN v_job;
END;
$EOFCODE$
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER;

CREATE FUNCTION app_jobs.complete_job (worker_id text, job_id bigint)
  RETURNS app_jobs.jobs
  LANGUAGE plpgsql
  AS $EOFCODE$
DECLARE
  v_row app_jobs.jobs;
BEGIN
  DELETE FROM app_jobs.jobs
  WHERE id = job_id
  RETURNING
    * INTO v_row;
  IF v_row.queue_name IS NOT NULL THEN
    UPDATE
      app_jobs.job_queues
    SET
      locked_by = NULL,
      locked_at = NULL
    WHERE
      queue_name = v_row.queue_name
      AND locked_by = worker_id;
  END IF;
  RETURN v_row;
END;
$EOFCODE$;

CREATE FUNCTION app_jobs.complete_jobs (job_ids bigint[])
  RETURNS SETOF app_jobs.jobs
  LANGUAGE sql
  AS $EOFCODE$
  DELETE FROM app_jobs.jobs
  WHERE id = ANY (job_ids)
    AND (locked_by IS NULL
      OR locked_at < NOW() - interval '4 hours')
  RETURNING
    *;

$EOFCODE$;

CREATE FUNCTION app_jobs.do_notify ()
  RETURNS TRIGGER
  AS $EOFCODE$
BEGIN
  PERFORM
    pg_notify(TG_ARGV[0], '');
  RETURN NEW;
END;
$EOFCODE$
LANGUAGE plpgsql;

CREATE FUNCTION app_jobs.fail_job (worker_id text, job_id bigint, error_message text)
  RETURNS app_jobs.jobs
  LANGUAGE plpgsql
  STRICT
  AS $EOFCODE$
DECLARE
  v_row app_jobs.jobs;
BEGIN
  UPDATE
    app_jobs.jobs
  SET
    last_error = error_message,
    run_at = greatest (now(), run_at) + (exp(least (attempts, 10))::text || ' seconds')::interval,
    locked_by = NULL,
    locked_at = NULL
  WHERE
    id = job_id
    AND locked_by = worker_id
  RETURNING
    * INTO v_row;
  IF v_row.queue_name IS NOT NULL THEN
    UPDATE
      app_jobs.job_queues
    SET
      locked_by = NULL,
      locked_at = NULL
    WHERE
      queue_name = v_row.queue_name
      AND locked_by = worker_id;
  END IF;
  RETURN v_row;
END;
$EOFCODE$;

CREATE FUNCTION app_jobs.get_job (worker_id text, task_identifiers text[] DEFAULT NULL, job_expiry interval DEFAULT '4 hours')
  RETURNS app_jobs.jobs
  LANGUAGE plpgsql
  AS $EOFCODE$
DECLARE
  v_job_id bigint;
  v_queue_name text;
  v_row app_jobs.jobs;
  v_now timestamptz = now();
BEGIN
  IF worker_id IS NULL OR length(worker_id) < 10 THEN
    RAISE exception 'INVALID_WORKER_ID';
  END IF;
  SELECT
    jobs.queue_name,
    jobs.id INTO v_queue_name,
    v_job_id
  FROM
    app_jobs.jobs
  WHERE (jobs.locked_at IS NULL
    OR jobs.locked_at < (v_now - job_expiry))
    AND (jobs.queue_name IS NULL
      OR EXISTS (
        SELECT
          1
        FROM
          app_jobs.job_queues
        WHERE
          job_queues.queue_name = jobs.queue_name
          AND (job_queues.locked_at IS NULL
            OR job_queues.locked_at < (v_now - job_expiry))
        FOR UPDATE
          SKIP LOCKED))
    AND run_at <= v_now
    AND attempts < max_attempts
    AND (task_identifiers IS NULL
      OR task_identifier = ANY (task_identifiers))
  ORDER BY
    priority ASC,
    run_at ASC,
    id ASC
  LIMIT 1
  FOR UPDATE
    SKIP LOCKED;
  IF v_job_id IS NULL THEN
    RETURN NULL;
  END IF;
  IF v_queue_name IS NOT NULL THEN
    UPDATE
      app_jobs.job_queues
    SET
      locked_by = worker_id,
      locked_at = v_now
    WHERE
      job_queues.queue_name = v_queue_name;
  END IF;
  UPDATE
    app_jobs.jobs
  SET
    attempts = attempts + 1,
    locked_by = worker_id,
    locked_at = v_now
  WHERE
    id = v_job_id
  RETURNING
    * INTO v_row;
  RETURN v_row;
END;
$EOFCODE$;

CREATE FUNCTION app_jobs.permanently_fail_jobs (job_ids bigint[], error_message text DEFAULT NULL::text)
  RETURNS SETOF app_jobs.jobs
  LANGUAGE sql
  AS $EOFCODE$
  UPDATE
    app_jobs.jobs
  SET
    last_error = coalesce(error_message, 'Manually marked as failed'),
    attempts = max_attempts
  WHERE
    id = ANY (job_ids)
    AND (locked_by IS NULL
      OR locked_at < NOW() - interval '4 hours')
  RETURNING
    *;

$EOFCODE$;

CREATE FUNCTION app_jobs.remove_job (job_key text)
  RETURNS app_jobs.jobs
  LANGUAGE sql
  STRICT
  AS $EOFCODE$
  DELETE FROM app_jobs.jobs
  WHERE KEY = job_key
    AND locked_at IS NULL
  RETURNING
    *;

$EOFCODE$;

CREATE FUNCTION app_jobs.reschedule_jobs (job_ids bigint[], run_at pg_catalog.timestamptz DEFAULT NULL, priority int DEFAULT NULL, attempts int DEFAULT NULL, max_attempts int DEFAULT NULL)
  RETURNS SETOF app_jobs.jobs
  LANGUAGE sql
  AS $EOFCODE$
  UPDATE
    app_jobs.jobs
  SET
    run_at = coalesce(reschedule_jobs.run_at, jobs.run_at),
    priority = coalesce(reschedule_jobs.priority, jobs.priority),
    attempts = coalesce(reschedule_jobs.attempts, jobs.attempts),
    max_attempts = coalesce(reschedule_jobs.max_attempts, jobs.max_attempts)
  WHERE
    id = ANY (job_ids)
    AND (locked_by IS NULL
      OR locked_at < NOW() - interval '4 hours')
  RETURNING
    *;

$EOFCODE$;

ALTER TABLE app_jobs.job_queues ENABLE ROW LEVEL SECURITY;

ALTER TABLE app_jobs.jobs ENABLE ROW LEVEL SECURITY;

CREATE INDEX priority_run_at_id_idx ON app_jobs.jobs (priority, run_at, id);

CREATE FUNCTION app_jobs.tg_decrease_job_queue_count ()
  RETURNS TRIGGER
  AS $EOFCODE$
DECLARE
  v_new_job_count int;
BEGIN
  UPDATE
    app_jobs.job_queues
  SET
    job_count = job_queues.job_count - 1
  WHERE
    queue_name = OLD.queue_name
  RETURNING
    job_count INTO v_new_job_count;
  IF v_new_job_count <= 0 THEN
    DELETE FROM app_jobs.job_queues
    WHERE queue_name = OLD.queue_name
      AND job_count <= 0;
  END IF;
  RETURN OLD;
END;
$EOFCODE$
LANGUAGE plpgsql
VOLATILE;

CREATE TRIGGER decrease_job_queue_count_on_delete
  AFTER DELETE ON app_jobs.jobs
  FOR EACH ROW
  WHEN (old.queue_name IS NOT NULL)
  EXECUTE PROCEDURE app_jobs. tg_decrease_job_queue_count ();

CREATE TRIGGER decrease_job_queue_count_on_update
  AFTER UPDATE OF queue_name ON app_jobs.jobs
  FOR EACH ROW
  WHEN ((new.queue_name IS DISTINCT FROM old.queue_name AND old.queue_name IS NOT NULL))
  EXECUTE PROCEDURE app_jobs. tg_decrease_job_queue_count ();

CREATE FUNCTION app_jobs.tg_increase_job_queue_count ()
  RETURNS TRIGGER
  AS $EOFCODE$
BEGIN
  INSERT INTO app_jobs.job_queues (queue_name, job_count)
    VALUES (NEW.queue_name, 1)
  ON CONFLICT (queue_name)
    DO UPDATE SET
      job_count = job_queues.job_count + 1;
  RETURN NEW;
END;
$EOFCODE$
LANGUAGE plpgsql
VOLATILE;

CREATE TRIGGER _500_increase_job_queue_count_on_insert
  AFTER INSERT ON app_jobs.jobs
  FOR EACH ROW
  WHEN (NEW.queue_name IS NOT NULL)
  EXECUTE PROCEDURE app_jobs. tg_increase_job_queue_count ();

CREATE TRIGGER _500_increase_job_queue_count_on_update
  AFTER UPDATE OF queue_name ON app_jobs.jobs
  FOR EACH ROW
  WHEN ((NEW.queue_name IS DISTINCT FROM OLD.queue_name AND NEW.queue_name IS NOT NULL))
  EXECUTE PROCEDURE app_jobs. tg_increase_job_queue_count ();

CREATE TRIGGER _900_notify_worker
  AFTER INSERT ON app_jobs.jobs
  FOR EACH ROW
  EXECUTE PROCEDURE app_jobs. do_notify ('jobs:insert');

CREATE FUNCTION app_jobs.tg_update_timestamps ()
  RETURNS TRIGGER
  AS $EOFCODE$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.created_at = NOW();
    NEW.updated_at = NOW();
  ELSIF TG_OP = 'UPDATE' THEN
    NEW.created_at = OLD.created_at;
    NEW.updated_at = greatest (now(), OLD.updated_at + interval '1 millisecond');
  END IF;
  RETURN NEW;
END;
$EOFCODE$
LANGUAGE plpgsql;

ALTER TABLE app_jobs.jobs
  ADD COLUMN created_at timestamptz;

ALTER TABLE app_jobs.jobs
  ALTER COLUMN created_at SET DEFAULT now();

ALTER TABLE app_jobs.jobs
  ADD COLUMN updated_at timestamptz;

ALTER TABLE app_jobs.jobs
  ALTER COLUMN updated_at SET DEFAULT now();

CREATE TRIGGER _100_update_jobs_modtime_tg
  BEFORE INSERT OR UPDATE ON app_jobs.jobs
  FOR EACH ROW
  EXECUTE PROCEDURE app_jobs. tg_update_timestamps ();

CREATE FUNCTION app_jobs.tg_add_job_for_row ()
  RETURNS TRIGGER
  AS $EOFCODE$
BEGIN
  PERFORM
    app_jobs.add_job (tg_argv[0], json_build_object('id', NEW.id));
  RETURN NEW;
END;
$EOFCODE$
LANGUAGE plpgsql;

COMMENT ON FUNCTION app_jobs.tg_add_job_for_row IS E'Useful shortcut to create a job on insert or update. Pass the task name as the trigger argument, and the record id will automatically be available on the JSON payload.';

