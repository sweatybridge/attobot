-- pg_ssh exposes ssh.ssh_exec(host_name, command) for running remote commands
-- over SSH from inside PostgreSQL. The .so, control, and install SQL are
-- installed from the Debian package in the Dockerfile; CREATE EXTENSION creates
-- the ssh schema, the ssh.hosts catalog, and the SECURITY DEFINER ssh_exec.
-- No shared_preload_libraries: there is no background worker.
CREATE EXTENSION IF NOT EXISTS pg_ssh;
