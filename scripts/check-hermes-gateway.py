#!/usr/bin/env python3
"""check-hermes-gateway.py — ¿el gateway de Hermes está corriendo, sí o sí?

Comprueba, en orden, las señales que distinguen "proceso vivo" de "gateway sano":

  1. pidfile    ~/.hermes/gateway.pid existe, es JSON y dice hermes-gateway
  2. proceso    el PID vive y su línea de comando es la del gateway
  3. estado     gateway_state.json: gateway_state=running, sin exit_reason
  4. plataformas  cada plataforma (p.ej. whatsapp) en estado connected/running
  5. bridge     el bridge local (127.0.0.1:3000) responde /health

Códigos de salida: 0 = todo bien · 1 = algún chequeo falló · 2 = solo avisos.

Uso:
    python check-hermes-gateway.py                 # resumen legible
    python check-hermes-gateway.py --json          # para scripts/cron
    python check-hermes-gateway.py --quiet         # sin detalle, solo veredicto
    python check-hermes-gateway.py --stale 300     # tolerancia de frescura (s)

No imprime secretos: solo rutas, PIDs, estados y puertos.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

OK, WARN, FAIL = "OK", "WARN", "FAIL"


def default_home() -> Path:
    env = os.environ.get("HERMES_HOME")
    if env:
        return Path(env).expanduser()
    local = os.environ.get("LOCALAPPDATA")
    if os.name == "nt" and local:
        candidate = Path(local) / "hermes"
        if candidate.exists():
            return candidate
    return Path.home() / ".hermes"


class Check:
    def __init__(self, name: str, status: str, detail: str, hint: str = "") -> None:
        self.name = name
        self.status = status
        self.detail = detail
        self.hint = hint

    def as_dict(self) -> dict:
        return {"name": self.name, "status": self.status, "detail": self.detail, "hint": self.hint}


def _load_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8")), None
    except FileNotFoundError:
        return None, "no existe"
    except (json.JSONDecodeError, OSError) as exc:
        return None, f"ilegible ({exc.__class__.__name__})"


def _parse_iso(value: str):
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


def check_pidfile(home: Path):
    path = home / "gateway.pid"
    data, err = _load_json(path)
    if err:
        return None, Check("pidfile", FAIL, f"{path} {err}", "arrancá el gateway: hermes gateway run")
    if not isinstance(data, dict) or "pid" not in data:
        return None, Check("pidfile", FAIL, f"{path} sin campo 'pid'", "borrar el pidfile y arrancar el gateway")
    kind = data.get("kind", "?")
    if kind != "hermes-gateway":
        return None, Check("pidfile", WARN, f"kind={kind!r} (se esperaba hermes-gateway)", "")
    return data, Check("pidfile", OK, f"pid={data['pid']} kind={kind}")


def check_process(pid: int):
    try:
        import psutil  # type: ignore
    except ImportError:
        psutil = None

    if psutil is None:
        try:
            os.kill(pid, 0)
        except OSError as exc:
            return Check("proceso", FAIL, f"PID {pid} no responde ({exc.__class__.__name__})",
                         "el gateway está caído: hermes gateway run")
        return Check("proceso", WARN, f"PID {pid} vivo (psutil no instalado: no valido cmdline)", "")

    try:
        proc = psutil.Process(pid)
        if not proc.is_running() or proc.status() == psutil.STATUS_ZOMBIE:
            raise psutil.NoSuchProcess(pid)
        cmdline = " ".join(proc.cmdline())
    except Exception as exc:  # psutil.NoSuchProcess / AccessDenied
        return Check("proceso", FAIL, f"PID {pid} no está vivo ({exc.__class__.__name__})",
                     "el gateway está caído: hermes gateway run")

    if "gateway" not in cmdline or "run" not in cmdline:
        return Check("proceso", WARN,
                     f"PID {pid} vivo pero no parece el gateway (cmdline: {cmdline[:70]})",
                     "posible PID reciclado: hermes gateway restart")
    return Check("proceso", OK, f"PID {pid} vivo · {proc.name()} · gateway run")


def check_state(home: Path, stale_seconds: int):
    path = home / "gateway_state.json"
    data, err = _load_json(path)
    if err:
        return None, Check("estado", FAIL, f"{path} {err}", "el gateway nunca escribió su estado")
    state = data.get("gateway_state")
    if state != "running":
        return data, Check("estado", FAIL, f"gateway_state={state!r} exit_reason={data.get('exit_reason')!r}",
                           "revisar logs/gateway-stdio.log")
    updated = _parse_iso(str(data.get("updated_at") or ""))
    age = None
    if updated is not None:
        age = (datetime.now(timezone.utc) - updated.astimezone(timezone.utc)).total_seconds()
    if age is not None and age > stale_seconds:
        return data, Check("estado", WARN, f"running pero el estado tiene {int(age)}s sin refrescarse",
                           "si no hay actividad es normal; si no responde, reiniciar")
    detail = "running" + (f" · heartbeat hace {int(age)}s" if age is not None else "")
    return data, Check("estado", OK, detail)


def check_platforms(state: dict):
    platforms = state.get("platforms") or {}
    if not platforms:
        return Check("plataformas", WARN, "el estado no lista plataformas", "revisar platform_toolsets")
    bad, ok_list, warn_list = [], [], []
    for name, info in platforms.items():
        st = (info or {}).get("state")
        if st in ("connected", "running", "ready"):
            ok_list.append(f"{name}={st}")
        elif st in ("starting", "reconnecting", "connecting", "degraded"):
            warn_list.append(f"{name}={st}")
        else:
            bad.append(f"{name}={st}")
    if bad:
        return Check("plataformas", FAIL, ", ".join(bad), "revisar logs/whatsapp/bridge.log")
    if warn_list:
        return Check("plataformas", WARN, ", ".join(warn_list), "suele resolverse solo en segundos")
    return Check("plataformas", OK, ", ".join(ok_list))


def check_bridge(port: int, timeout: float):
    url = f"http://127.0.0.1:{port}/health"
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:  # noqa: S310 (localhost)
            body = resp.read(200).decode("utf-8", "replace").strip()
            if resp.status == 200:
                return Check("bridge", OK, f"127.0.0.1:{port} /health 200 {body[:40]}")
            return Check("bridge", FAIL, f"127.0.0.1:{port} /health {resp.status}", "reiniciar el gateway")
    except (urllib.error.URLError, urllib.error.HTTPError, OSError):
        pass

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        if sock.connect_ex(("127.0.0.1", port)) == 0:
            return Check("bridge", WARN, f"puerto {port} abierto pero /health no responde",
                         "bridge a medio levantar: esperar o reiniciar")
        return Check("bridge", FAIL, f"puerto {port} cerrado", "el bridge no está escuchando: reiniciar el gateway")
    finally:
        sock.close()


def main() -> int:
    ap = argparse.ArgumentParser(description="Verifica si el gateway de Hermes está corriendo.")
    ap.add_argument("--hermes-home", default=str(default_home()), help="HERMES_HOME (default: %(default)s)")
    ap.add_argument("--bridge-port", type=int, default=3000, help="puerto del bridge local (default: 3000)")
    ap.add_argument("--timeout", type=float, default=3.0, help="timeout HTTP/TCP en segundos (default: 3)")
    ap.add_argument("--stale", type=int, default=600, help="segundos sin heartbeat antes de avisar (default: 600)")
    ap.add_argument("--json", action="store_true", help="salida JSON")
    ap.add_argument("--quiet", action="store_true", help="solo el veredicto")
    args = ap.parse_args()

    home = Path(args.hermes_home).expanduser()
    checks: list[Check] = []

    pidfile, pid_check = check_pidfile(home)
    checks.append(pid_check)
    if pidfile:
        checks.append(check_process(int(pidfile["pid"])))

    state, state_check = check_state(home, args.stale)
    checks.append(state_check)
    if state:
        checks.append(check_platforms(state))

    checks.append(check_bridge(args.bridge_port, args.timeout))

    failures = [c for c in checks if c.status == FAIL]
    warnings = [c for c in checks if c.status == WARN]
    verdict = "DOWN" if failures else ("DEGRADED" if warnings else "UP")
    code = 1 if failures else (2 if warnings else 0)

    if args.json:
        print(json.dumps({
            "verdict": verdict,
            "hermes_home": str(home),
            "pid": (pidfile or {}).get("pid"),
            "checks": [c.as_dict() for c in checks],
        }, indent=2, ensure_ascii=False))
        return code

    if args.quiet:
        print(verdict)
        return code

    width = max(len(c.name) for c in checks)
    print(f"Hermes gateway — {home}")
    for c in checks:
        print(f"  [{c.status:4}] {c.name.ljust(width)}  {c.detail}")
        if c.hint and c.status != OK:
            print(f"         {' ' * width}  → {c.hint}")
    pid = (pidfile or {}).get("pid")
    print(f"\nVeredicto: {verdict}" + (f" · PID {pid}" if pid else ""))
    if failures:
        print("Arreglo rápido: hermes gateway restart")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
