# Juango

A Django-style web framework in Julia. Roadmap: GitHub issues on mcvmcv/Juango.

## Running tests: this machine has 16 GB of RAM

- **Never run more than one test suite at a time.** `test/runtests.jl` already runs two
  groups of files in parallel (`JUANGO_TEST_JOBS`, default 2); each process peaks at about
  1-1.5 GB. Test the databases one after another, never in parallel, and don't raise
  `JUANGO_TEST_JOBS` without asking.
- **Cap every run** so it can't take the machine down (the cap covers the child processes):

      systemd-run --user --scope -q -p MemoryMax=5G -p MemorySwapMax=0 \
          julia --project=test test/runtests.jl

- **Run only the part you're working on** while developing: `test/templates.jl`, `orm.jl`,
  `forms.jl`, `views.jl`, `admin.jl`, `services.jl`, `db.jl` or `migrations.jl`, each on its
  own (they share `test/setup.jl`), under the same cap. Run the whole suite once before
  committing: about 5 minutes on SQLite.
- Juango has a precompile workload (`src/precompile.jl`). Code that takes a model, a model type
  or a queryset is marked `Base.@nospecializeinfer` with `@nospecialize` arguments, so it's
  compiled once in the workload instead of again for each of a project's models on its first
  request. Keep new ORM, admin and form code that way, and avoid closures that capture a model
  type (Julia captures its exact type). Loading MySQL.jl invalidates part of the workload, so
  the tests load it only for MySQL; the PostgreSQL driver is Juango's own (`libpq.jl`).
- `JUANGO_TEST_DATABASE` picks the database: unset for in-memory SQLite, or a
  `postgresql://` / `mysql://` URL. A throwaway database is created on that server and
  dropped afterwards.
- Don't touch the system PostgreSQL or MariaDB services. Use throwaway servers on other ports.
- Kill stray Julia processes by PID. `pkill -f <pattern>` also matches the shell running it.
