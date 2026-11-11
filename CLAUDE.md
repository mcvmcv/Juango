# Juango

A Django-style web framework in Julia. Roadmap: GitHub issues on mcvmcv/Juango.

## Running tests: this machine has 16 GB of RAM

- **Never run more than one Julia test process at a time.** A full suite run uses about
  5 GB; three in parallel ran the machine out of memory. Test the databases one after
  another, never in parallel.
- **Cap every run** so it can't take the machine down:

      systemd-run --user --scope -q -p MemoryMax=5G -p MemorySwapMax=0 \
          julia --heap-size-hint=3G --project=test test/orm.jl

- **Run only the part you're working on.** The suite is split by area: `test/templates.jl`,
  `orm.jl`, `forms.jl`, `views.jl`, `admin.jl`, `services.jl`, `db.jl` and
  `migrations.jl`. Each one runs on its own: they share `test/setup.jl`. Run the whole
  suite (`test/runtests.jl`, or `Pkg.test()`) once before committing.
- `JUANGO_TEST_DATABASE` picks the database: unset for in-memory SQLite, or a
  `postgresql://` / `mysql://` URL. A throwaway database is created on that server and
  dropped afterwards.
- Don't touch the system PostgreSQL or MariaDB services. Use throwaway servers on other ports.
- Kill stray Julia processes by PID. `pkill -f <pattern>` also matches the shell running it.
