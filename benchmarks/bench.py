#!/usr/bin/env python3
"""Juango against Django: the same app in both (see README.md).

    benchmarks/.venv/bin/python benchmarks/bench.py [--db sqlite postgres] [--servers juango gunicorn uvicorn]

Each server runs alone, in its own systemd scope capped at 5 GB (its peak memory is read from
there), with one database at a time. For each: the time from starting it to its first response,
the time of the first request to each page (Julia compiles code as it first runs it), then
requests per second and latency for each page with `loadgen` (-c connections for -d seconds,
after -w seconds of warm-up). Results go to results/results.json and results/results.md.
"""
import argparse
import http.cookiejar
import json
import os
import platform
import re
import shlex
import signal
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
VENV = HERE / ".venv" / "bin"
DATA = HERE / "data"
RESULTS = HERE / "results"
LOADGEN = HERE / ".loadgen"
THREADS = os.cpu_count() or 4

PAGES = [  # name, method, path (Juango), path (Django), description
    ("json", "GET", "/json/", "/json/", "JSON response"),
    ("template", "GET", "/template/", "/template/", "template: 100-row loop, no database"),
    ("posts", "GET", "/posts/?page=3", "/posts/?page=3", "list: join + pagination (20 of 1000)"),
    ("form", "POST", "/form/", "/form/", "form POST with CSRF"),
    ("admin", "GET", "/admin/post/", "/admin/benchapp/post/", "admin change list (logged in)"),
]


def server_cmd(name, port):
    if name == "juango":
        return ["julia", f"--threads={THREADS},1", "--project=" + str(HERE / "juango"),
                str(HERE / "juango" / "manage.jl"), "runserver", f"127.0.0.1:{port}"], HERE / "juango"
    if name == "gunicorn":
        return [str(VENV / "gunicorn"), "-w", str(THREADS), "-b", f"127.0.0.1:{port}", "benchproj.wsgi"], HERE / "django"
    if name == "uvicorn":
        return [str(VENV / "uvicorn"), "--workers", str(THREADS), "--no-access-log", "--host", "127.0.0.1",
                "--port", str(port), "benchproj.asgi:application"], HERE / "django"
    raise ValueError(name)


def framework(name):
    return "juango" if name == "juango" else "django"


def db_url(db, fw, pg):
    if db == "sqlite":
        return str(DATA / f"{fw}.sqlite3")
    u = urllib.parse.urlparse(pg)
    return urllib.parse.urlunparse(u._replace(path=f"/bench_{fw}"))


def run(cmd, cwd, env, quiet=True):
    r = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"failed: {shlex.join(cmd)}\n{r.stdout}\n{r.stderr}")
    return r.stdout


def capped(cmd, unit=None):
    """`cmd` in a transient systemd scope with 5 GB of memory and no swap."""
    pre = ["systemd-run", "--user", "--scope", "-q", "-p", "MemoryMax=5G", "-p", "MemorySwapMax=0"]
    return pre + (["--unit", unit] if unit else []) + cmd


def prepare(db, pg):
    """A fresh database for each framework, migrated and seeded."""
    for fw in ("juango", "django"):
        env = dict(os.environ, BENCH_DB=db_url(db, fw, pg))
        if db == "sqlite":
            DATA.mkdir(exist_ok=True)
            for suffix in ("", "-wal", "-shm"):
                Path(db_url(db, fw, pg) + suffix).unlink(missing_ok=True)
        else:
            import psycopg
            with psycopg.connect(pg, autocommit=True) as c:
                c.execute(f"DROP DATABASE IF EXISTS bench_{fw}")
                c.execute(f"CREATE DATABASE bench_{fw}")
        if fw == "juango":
            for c in ("migrate", "seed"):
                run(capped(["julia", "--project=.", "manage.jl", c]), HERE / "juango", env)
        else:
            for c in (["migrate", "-v0"], ["seed"]):
                run([str(VENV / "python"), "manage.py"] + c, HERE / "django", env)


def get(url, opener=None, data=None):
    req = urllib.request.Request(url, data=urllib.parse.urlencode(data).encode() if data else None)
    with (opener or urllib.request.build_opener()).open(req, timeout=120) as r:
        return r.status, r.read().decode()


def csrf_token(html):
    return re.search(r'name="csrfmiddlewaretoken" value="([^"]+)"', html).group(1)


def cookie_header(jar):
    return "; ".join(f"{c.name}={c.value}" for c in jar)


def request_bytes(method, path, port, cookie="", body=""):
    lines = [f"{method} {path} HTTP/1.1", f"Host: 127.0.0.1:{port}", "User-Agent: loadgen", "Accept: */*"]
    if cookie:
        lines.append(f"Cookie: {cookie}")
    if method == "POST":
        lines += ["Content-Type: application/x-www-form-urlencoded", f"Content-Length: {len(body.encode())}"]
    return ("\r\n".join(lines) + "\r\n\r\n" + body).encode()


def scope_memory_peak(unit):
    cg = subprocess.run(["systemctl", "--user", "show", "-p", "ControlGroup", "--value", unit + ".scope"],
                        capture_output=True, text=True).stdout.strip()
    try:
        return int(Path("/sys/fs/cgroup" + cg + "/memory.peak").read_text()) if cg else None
    except OSError:
        return None


def bench_server(name, db, pg, args):
    port = 8701
    fw = framework(name)
    cmd, cwd = server_cmd(name, port)
    unit = f"juango-bench-{name}-{os.getpid()}"
    env = dict(os.environ, BENCH_DB=db_url(db, fw, pg), **({"BENCH_ASGI": "1"} if name == "uvicorn" else {}))
    base = f"http://127.0.0.1:{port}"
    t0 = time.monotonic()
    log = RESULTS / f"{name}-{db}.log"
    with open(log, "wb") as logf:
        proc = subprocess.Popen(capped(cmd, unit), cwd=cwd, env=env, stdout=logf, stderr=subprocess.STDOUT,
                                start_new_session=True)
    out = {"server": name, "db": db}
    try:
        while True:
            if proc.poll() is not None:
                sys.exit(f"{name} exited:\n{log.read_text()[-3000:]}")
            try:
                if get(base + "/json/")[0] == 200:
                    break
            except OSError:
                time.sleep(0.05)
        out["startup_s"] = round(time.monotonic() - t0, 2)

        # the first request to each page, then a session for the admin and a CSRF token for the form
        jar = http.cookiejar.CookieJar()
        browser = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
        _, html = get(base + "/admin/login/", browser)
        get(base + "/admin/login/", browser, {"username": "admin", "password": "admin-pass",
                                              "csrfmiddlewaretoken": csrf_token(html), "next": "/admin/"})
        admin_cookie = cookie_header(jar)
        form_jar = http.cookiejar.CookieJar()
        anon = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(form_jar))
        _, html = get(base + "/form/", anon)
        form_body = urllib.parse.urlencode({"name": "Ann", "email": "ann@example.com", "message": "Hello there",
                                            "csrfmiddlewaretoken": csrf_token(html)})
        out["first_request_ms"] = {}
        out["pages"] = {}
        for page, method, jpath, dpath, _ in PAGES:
            path = jpath if fw == "juango" else dpath
            cookie = admin_cookie if page == "admin" else cookie_header(form_jar) if page == "form" else ""
            body = form_body if page == "form" else ""
            rfile = RESULTS / f".req-{page}"
            rfile.write_bytes(request_bytes(method, path, port, cookie, body))
            t = time.monotonic()
            o = browser if page == "admin" else anon
            st, text = get(base + path, o, dict(urllib.parse.parse_qsl(body)) if body else None)
            out["first_request_ms"][page] = round(1000 * (time.monotonic() - t), 1)
            if st != 200 or (page == "form" and not text.startswith("Thanks")) or (page == "admin" and "Post number" not in text):
                sys.exit(f"{name} {page}: unexpected response {st}: {text[:300]}")
            r = subprocess.run([str(LOADGEN), "-c", str(args.connections), "-d", str(args.duration), "-w", str(args.warmup),
                                "127.0.0.1", str(port), str(rfile)], capture_output=True, text=True, check=True)
            out["pages"][page] = json.loads(r.stdout)
            p = out["pages"][page]
            print(f"  {name:9s} {db:8s} {page:9s} {p['rps']:9.0f} req/s   p50 {p['p50_ms']:7.2f} ms   p99 {p['p99_ms']:7.2f} ms"
                  + (f"   {p['bad_status']} bad, {p['errors']} errors" if p["bad_status"] or p["errors"] else ""), flush=True)
        out["memory_peak_mb"] = round((scope_memory_peak(unit) or 0) / 2**20)
    finally:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            proc.wait(30)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
    return out


def markdown(results, args):
    machine = f"{platform.processor() or platform.machine()}, {os.cpu_count()} cores, {platform.system()} {platform.release()}"
    try:
        cpu = next(l.split(":", 1)[1].strip() for l in open("/proc/cpuinfo") if l.startswith("model name"))
        machine = f"{cpu}, {os.cpu_count()} cores, {platform.system()} {platform.release()}"
    except (OSError, StopIteration):
        pass
    julia = subprocess.run(["julia", "--version"], capture_output=True, text=True).stdout.strip()
    import django
    lines = [f"Machine: {machine}. {julia}; Python {platform.python_version()}, Django {django.get_version()}.",
             f"{args.connections} connections, {args.duration} s per page after {args.warmup} s of warm-up; the load "
             f"generator runs on the same machine (one core). Juango: `runserver` with --threads={THREADS},1; "
             f"Django: {THREADS} gunicorn sync workers, or {THREADS} uvicorn workers (ASGI).", ""]
    for db in args.db:
        rs = [r for r in results if r["db"] == db]
        if not rs:
            continue
        lines += [f"### {'SQLite' if db == 'sqlite' else 'PostgreSQL'}", "",
                  "| Page | " + " | ".join(r["server"] for r in rs) + " |",
                  "|---|" + "---:|" * len(rs)]
        for page, *_, desc in PAGES:
            cells = [f"{r['pages'][page]['rps']:,.0f} req/s<br>p50 {r['pages'][page]['p50_ms']:.1f} / p99 {r['pages'][page]['p99_ms']:.1f} ms"
                     for r in rs]
            lines.append(f"| {desc} | " + " | ".join(cells) + " |")
        lines.append("| start to first response | " + " | ".join(f"{r['startup_s']:.1f} s" for r in rs) + " |")
        lines.append("| first request to each page | " + " | ".join(
            ", ".join(f"{v:.0f}" for v in r["first_request_ms"].values()) + " ms" for r in rs) + " |")
        lines.append("| peak memory | " + " | ".join(f"{r['memory_peak_mb']:,} MB" for r in rs) + " |")
        lines.append("")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", nargs="+", default=["sqlite"], choices=["sqlite", "postgres"])
    ap.add_argument("--servers", nargs="+", default=["juango", "gunicorn", "uvicorn"], choices=["juango", "gunicorn", "uvicorn"])
    ap.add_argument("--pg", default=os.environ.get("BENCH_PG", "postgresql://postgres@127.0.0.1:5432/postgres"),
                    help="a PostgreSQL server to create the bench_juango and bench_django databases on")
    ap.add_argument("-c", "--connections", type=int, default=32)
    ap.add_argument("-d", "--duration", type=float, default=10)
    ap.add_argument("-w", "--warmup", type=float, default=3)
    args = ap.parse_args()
    RESULTS.mkdir(exist_ok=True)
    if not LOADGEN.exists() or LOADGEN.stat().st_mtime < (HERE / "loadgen.c").stat().st_mtime:
        subprocess.run(["cc", "-O2", "-o", str(LOADGEN), str(HERE / "loadgen.c")], check=True)
    results = []
    for db in args.db:
        print(f"Preparing the {db} databases...", flush=True)
        prepare(db, args.pg)
        for s in args.servers:
            results.append(bench_server(s, db, args.pg, args))
    (RESULTS / "results.json").write_text(json.dumps(results, indent=1))
    md = markdown(results, args)
    (RESULTS / "results.md").write_text(md + "\n")
    print("\n" + md)


if __name__ == "__main__":
    main()
