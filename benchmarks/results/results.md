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

