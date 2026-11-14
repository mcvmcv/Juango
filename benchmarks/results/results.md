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

