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

Measured on 2026-11-14 (`results/results.md`, written by `bench.py`):

Machine: Intel(R) Core(TM) i5-4440 CPU @ 3.10GHz, 4 cores, Linux 6.12.116+deb13-amd64. julia version 1.13.3; Python 3.13.5, Django 5.2.19.
32 connections, 10 s per page after 3 s of warm-up; the load generator runs on the same machine (one core). Juango: `runserver` with --threads=4,1; Django: 4 gunicorn sync workers, or 4 uvicorn workers (ASGI).

### SQLite

| Page | juango | gunicorn | uvicorn |
|---|---:|---:|---:|
| JSON response | 26,184 req/s<br>p50 0.8 / p99 3.8 ms | 6,893 req/s<br>p50 4.4 / p99 7.0 ms | 1,170 req/s<br>p50 25.4 / p99 46.7 ms |
| template: 100-row loop, no database | 6,213 req/s<br>p50 4.4 / p99 15.4 ms | 671 req/s<br>p50 45.9 / p99 69.2 ms | 410 req/s<br>p50 82.6 / p99 139.6 ms |
| list: join + pagination (20 of 1000) | 4,004 req/s<br>p50 6.9 / p99 26.0 ms | 1,157 req/s<br>p50 26.9 / p99 39.0 ms | 524 req/s<br>p50 70.2 / p99 114.8 ms |
| form POST with CSRF | 18,712 req/s<br>p50 1.2 / p99 4.6 ms | 4,658 req/s<br>p50 6.6 / p99 10.4 ms | 1,014 req/s<br>p50 36.6 / p99 54.1 ms |
| admin change list (logged in) | 834 req/s<br>p50 35.1 / p99 103.0 ms | 78 req/s<br>p50 408.5 / p99 467.0 ms | 60 req/s<br>p50 476.8 / p99 1083.7 ms |
| start to first response | 7.2 s | 0.3 s | 0.5 s |
| first request to each page | 1, 352, 3079, 2, 1505 ms | 1, 15, 49, 57, 57 ms | 3, 12, 13, 59, 72 ms |
| peak memory | 842 MB | 165 MB | 300 MB |

### PostgreSQL

| Page | juango | gunicorn | uvicorn |
|---|---:|---:|---:|
| JSON response | 21,733 req/s<br>p50 0.9 / p99 5.5 ms | 6,866 req/s<br>p50 4.4 / p99 8.3 ms | 1,297 req/s<br>p50 28.2 / p99 42.2 ms |
| template: 100-row loop, no database | 5,850 req/s<br>p50 4.3 / p99 17.4 ms | 696 req/s<br>p50 45.2 / p99 57.9 ms | 404 req/s<br>p50 81.7 / p99 154.2 ms |
| list: join + pagination (20 of 1000) | 2,436 req/s<br>p50 7.5 / p99 88.9 ms | 879 req/s<br>p50 34.6 / p99 57.3 ms | 242 req/s<br>p50 152.6 / p99 266.1 ms |
| form POST with CSRF | 16,393 req/s<br>p50 1.2 / p99 7.0 ms | 4,762 req/s<br>p50 6.4 / p99 11.9 ms | 1,148 req/s<br>p50 26.1 / p99 59.0 ms |
| admin change list (logged in) | 576 req/s<br>p50 32.8 / p99 324.0 ms | 75 req/s<br>p50 426.2 / p99 473.0 ms | 39 req/s<br>p50 1136.9 / p99 1502.7 ms |
| start to first response | 14.0 s | 0.4 s | 0.6 s |
| first request to each page | 1, 368, 3352, 2, 2875 ms | 1, 13, 51, 60, 61 ms | 10, 14, 24, 66, 73 ms |
| peak memory | 1,319 MB | 194 MB | 296 MB |

What it shows:
- **Throughput:** Juango answers 3-4x as many requests as Django under gunicorn on the simple pages (JSON, form POST). It's about 9x on the template page, 2.8-3.5x on the paginated list and 7-10x on the admin change list. Latency follows the same pattern.
- **Django under uvicorn is slower than under gunicorn here:** this app's views are synchronous, and Django's ASGI handler runs them one at a time per worker, in a single thread (`sync_to_async(thread_sensitive=True)`).
- **Start-up and first requests are Juango's weak side:** 7 s from start to the first response (14 s with LibPQ, which invalidates part of the precompiled code), and up to 3 s for the first request to a page whose code wasn't precompiled. `manage.jl build` (a system image) is the remedy for deployments.
- **Memory:** Juango uses 0.8-1.3 GB, against 165-300 MB for Django's four worker processes.
- **Tail latency:** Juango's p99 on PostgreSQL is 5-10x its p50, probably garbage-collection pauses.

### What this benchmark changed in Juango

Profiling the slowest cases found:
- **PostgreSQL queries took 2.4 ms each:** LibPQ's `async_execute` waits for every result through a FileWatching watcher, which adds about 2 ms of wake-up latency (and builds debug log messages on every loop). Juango now sends the query without blocking and waits with `poll(2)` for the first millisecond, then yields to other tasks. A query now takes about 0.1 ms. The PostgreSQL list page went from 337 to 2,436 req/s, and the admin from 92 to 576.
- **Result values were parsed one at a time through a dynamic type:** LibPQ's `result[i, j]` works out the value's type for every cell. They're now read column by column.
- **`{{ obj.attr }}` on a model rebuilt the model's property names on every lookup:** `hasproperty` called `propertynames`. The names are now cached per model.
- **Templates are now compiled to Julia functions (#94):** the template page renders about 2.3x as fast as when interpreted.

