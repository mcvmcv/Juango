# Juango against Django

The same small app in both frameworks: the same models, views, data, middleware and (shared)
templates. Pages:

| Page | What it does |
|---|---|
| `/json/` | a small JSON response |
| `/template/` | a template with a 100-row loop (`{% cycle %}`, `{% if %}`, filters), no database |
| `/posts/?page=3` | 20 of 1000 posts with their authors (one join), paginated, through a template |
| `/form/` (POST) | a three-field form with a CSRF token, validated |
| `/admin/.../post/` | the admin change list for posts, logged in: 100 rows, a search box and a filter |

- `juango/`: the Juango app (`project.jl`).
- `django/`: the Django app (`benchproj/`, `benchapp/`).
- `templates/`: the templates, shared by both.
- `loadgen.c`: a small HTTP/1.1 load generator, in the manner of wrk. It's single-threaded with epoll and keeps connections alive, reopening one when the server closes it.
- `bench.py`: runs everything and writes `results/results.md` and `results/results.json`.

## Running it

    cd benchmarks
    python3 -m venv .venv && .venv/bin/pip install "django==5.2.*" gunicorn "uvicorn[standard]" "psycopg[binary]"
    (cd juango && julia --project -e 'import Pkg; Pkg.instantiate()')
    .venv/bin/python bench.py                                   # SQLite
    BENCH_PG=postgresql://user@host:5432/postgres .venv/bin/python bench.py --db sqlite postgres

PostgreSQL runs need a server where the user can create databases (`bench_juango` and
`bench_django` are dropped and created again). Each server runs on its own, in a systemd scope
capped at 5 GB, which is also where its peak memory is read from.

Measured per server:
- Requests per second and latency percentiles for each page: 32 connections for 10 s, after 3 s of warm-up.
- The time from starting the server to its first response.
- The time of the first request to each page, which in Julia includes compiling the code the page needs. These come after a login and a GET of the form page, so the form's and the admin's code is partly compiled already.
- Peak memory, including all of gunicorn's or uvicorn's worker processes.

Both apps run with `DEBUG` off, no access log, persistent database connections, Juango's default middleware (plus `MessageMiddleware`, which Django's admin needs) and the same number of workers or threads as cores.

## Results

Measured on 2026-11-14 in the afternoon, after #101 and #102 (`results/results.md`, written by `bench.py`):

Machine: Intel(R) Core(TM) i5-4440 CPU @ 3.10GHz, 4 cores, Linux 6.12.116+deb13-amd64. julia version 1.13.3; Python 3.13.5, Django 5.2.19.
32 connections, 10 s per page after 3 s of warm-up; the load generator runs on the same machine (one core). Juango: `runserver` with --threads=4,1; Django: 4 gunicorn sync workers, or 4 uvicorn workers (ASGI).

### SQLite

| Page | juango | gunicorn | uvicorn |
|---|---:|---:|---:|
| JSON response | 18,884 req/s<br>p50 1.1 / p99 6.5 ms | 4,214 req/s<br>p50 7.2 / p99 14.2 ms | 839 req/s<br>p50 28.4 / p99 99.9 ms |
| template: 100-row loop, no database | 4,146 req/s<br>p50 7.0 / p99 22.5 ms | 427 req/s<br>p50 74.0 / p99 111.3 ms | 191 req/s<br>p50 153.2 / p99 267.2 ms |
| list: join + pagination (20 of 1000) | 3,187 req/s<br>p50 8.3 / p99 41.2 ms | 668 req/s<br>p50 45.8 / p99 82.4 ms | 400 req/s<br>p50 99.5 / p99 172.8 ms |
| form POST with CSRF | 13,513 req/s<br>p50 1.6 / p99 9.0 ms | 2,815 req/s<br>p50 10.7 / p99 21.6 ms | 757 req/s<br>p50 40.6 / p99 87.6 ms |
| admin change list (logged in) | 555 req/s<br>p50 47.8 / p99 196.6 ms | 48 req/s<br>p50 656.8 / p99 865.0 ms | 50 req/s<br>p50 348.1 / p99 2216.5 ms |
| start to first response | 7.4 s | 0.5 s | 0.7 s |
| first request to each page | 1, 73, 109, 5, 188 ms | 5, 15, 77, 64, 93 ms | 4, 22, 27, 53, 78 ms |
| peak memory | 499 MB | 163 MB | 283 MB |

### PostgreSQL

| Page | juango | gunicorn | uvicorn |
|---|---:|---:|---:|
| JSON response | 19,594 req/s<br>p50 1.0 / p99 6.8 ms | 5,113 req/s<br>p50 5.9 / p99 11.8 ms | 928 req/s<br>p50 22.8 / p99 102.3 ms |
| template: 100-row loop, no database | 3,762 req/s<br>p50 7.5 / p99 29.6 ms | 503 req/s<br>p50 62.8 / p99 93.0 ms | 313 req/s<br>p50 144.0 / p99 234.8 ms |
| list: join + pagination (20 of 1000) | 1,906 req/s<br>p50 9.3 / p99 130.4 ms | 620 req/s<br>p50 50.6 / p99 73.1 ms | 215 req/s<br>p50 147.9 / p99 262.0 ms |
| form POST with CSRF | 13,340 req/s<br>p50 1.8 / p99 8.5 ms | 3,546 req/s<br>p50 8.6 / p99 16.3 ms | 821 req/s<br>p50 30.1 / p99 104.4 ms |
| admin change list (logged in) | 177 req/s<br>p50 143.9 / p99 650.3 ms | 52 req/s<br>p50 606.6 / p99 694.9 ms | 41 req/s<br>p50 680.4 / p99 1669.2 ms |
| start to first response | 7.4 s | 0.4 s | 0.6 s |
| first request to each page | 1, 73, 105, 1, 198 ms | 5, 14, 61, 76, 83 ms | 3, 22, 21, 70, 79 ms |
| peak memory | 630 MB | 184 MB | 291 MB |

What it shows:
- **Throughput:** Juango answers 4-5x as many requests as Django under gunicorn on the simple pages (JSON, form POST), about 8-10x on the template page, 3-5x on the paginated list and 3-12x on the admin change list. Latency follows the same pattern.
- **Django under uvicorn is slower than under gunicorn here:** this app's views are synchronous, and Django's ASGI handler runs them one at a time per worker, in a single thread (`sync_to_async(thread_sensitive=True)`).
- **Start-up and first requests:** 7.4 s from start to the first response on either database, and 70-200 ms for the first request to each page. Django takes 0.4-0.7 s and 15-90 ms. `manage.jl build` (a system image) is the remedy for the start-up time.
- **Memory:** Juango's one process peaks at 0.5-0.65 GB, against 165-300 MB for Django's four worker processes. Most of it is code: bare Julia is 230 MB and loading Juango adds about 200 MB; the data live at a time is 20-60 MB.
- **Tail latency:** Juango's p99 is 4-14x its p50 on the database pages, mostly garbage-collection pauses, which stop every thread (a collection every 70-150 ms under this load, each taking 5-10 ms when the machine is busy). Django's is about 1.5-2x.

This run was on a busy machine (other work pushed the load average to 11 by the end), so absolute numbers are lower than on an idle one, for every server; the comparison between servers still holds. The earlier run (2026-11-14, idle machine, before #101 and #102) is in `results/results-95.md`: start-up was 7.2 s on SQLite and 14 s on PostgreSQL, first requests up to 3.4 s, and peak memory 0.84-1.32 GB.

### What this benchmark changed in Juango

#101 and #102 (after the first run):
- **First requests:** ORM, admin and form code compiled again for each project model on its first request (4.75 s for the list page). It's now compiled once in Juango's precompile workload, for every model.
- **PostgreSQL start-up:** LibPQ.jl's dependencies invalidated about 4,000 of Juango's compiled methods when they loaded. Juango now talks to libpq directly (`src/db/backends/libpq.jl`).
- **Templates compile in the background** and are interpreted until the compiled function is ready.
- **Per query:** no global lock and no settings Dict built to find the database; the pool waits on a condition rather than polling.

The first run:

Profiling the slowest cases found:
- **PostgreSQL queries took 2.4 ms each:** LibPQ's `async_execute` waits for every result through a FileWatching watcher, which adds about 2 ms of wake-up latency (and builds debug log messages on every loop). Juango now sends the query without blocking and waits with `poll(2)` for the first millisecond, then yields to other tasks. A query now takes about 0.1 ms. The PostgreSQL list page went from 337 to 2,436 req/s, and the admin from 92 to 576.
- **Result values were parsed one at a time through a dynamic type:** LibPQ's `result[i, j]` works out the value's type for every cell. They're now read column by column.
- **`{{ obj.attr }}` on a model rebuilt the model's property names on every lookup:** `hasproperty` called `propertynames`. The names are now cached per model.
- **Templates are now compiled to Julia functions (#94):** the template page renders about 2.3x as fast as when interpreted.

