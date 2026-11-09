#!/usr/bin/env python3
"""hermes-wake.py — levanta el gateway de Hermes cuando está caído.

Tres modos, del más simple al más ambicioso:

  --once            (default) un chequeo; si el gateway no está sano, lo arranca.
                    Pensado para el Programador de tareas de Windows cada minuto.
  --watch           bucle permanente cada --interval segundos (vigilante residente).
  --message         además de arrancar, intenta despertarlo "por WhatsApp": si el
                    bridge sobrevivió, drena la cola de mensajes entrantes y, si
                    hay alguno, contesta "levantando…" y arranca el gateway.

Salvaguardas:
  * Nunca toca un gateway sano (si responde, sale sin hacer nada).
  * Cooldown entre intentos (--cooldown, default 120 s) para no entrar en bucle.
  * Lockfile para que dos instancias no arranquen dos gateways.
  * Escritura append a ~/.hermes/cache/wake.log, sin secretos.

Códigos de salida: 0 = sano o levantado · 1 = no se pudo levantar · 2 = cooldown.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path

DETACHED_PROCESS = 0x00000008
CREATE_NEW_PROCESS_GROUP = 0x00000200
CREATE_NO_WINDOW = 0x08000000


# --------------------------------------------------------------------------- #
# Utilidades
# --------------------------------------------------------------------------- #
def default_home() -> Path:
    env = os.environ.get("HERMES_HOME")
    if env:
        return Path(env).expanduser()
    local = os.environ.get("LOCALAPPDATA")
    if os.name == "nt" and local:
        cand = Path(local) / "hermes"
        if cand.exists():
            return cand
    return Path.home() / ".hermes"


def read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None


def pid_alive(pid: int) -> bool:
    try:
        import psutil  # type: ignore

        proc = psutil.Process(pid)
        return proc.is_running() and proc.status() != psutil.STATUS_ZOMBIE
    except ImportError:
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False
    except Exception:
        return False


class Log:
    def __init__(self, path: Path, echo: bool) -> None:
        self.path = path
        self.echo = echo
        path.parent.mkdir(parents=True, exist_ok=True)

    def __call__(self, msg: str) -> None:
        line = f"{datetime.now().astimezone().strftime('%Y-%m-%d %H:%M:%S')} {msg}"
        if self.echo:
            print(line, flush=True)
        try:
            with self.path.open("a", encoding="utf-8") as fh:
                fh.write(line + "\n")
        except OSError:
            pass


# --------------------------------------------------------------------------- #
# Señales de vida
# --------------------------------------------------------------------------- #
def gateway_pid(home: Path) -> int | None:
    data = read_json(home / "gateway.pid")
    if isinstance(data, dict) and isinstance(data.get("pid"), int):
        return data["pid"]
    return None


def gateway_state(home: Path) -> str | None:
    data = read_json(home / "gateway_state.json")
    if isinstance(data, dict):
        return data.get("gateway_state")
    return None


def gateway_healthy(home: Path) -> tuple[bool, str]:
    pid = gateway_pid(home)
    if pid is None:
        return False, "sin pidfile"
    if not pid_alive(pid):
        return False, f"PID {pid} muerto"
    state = gateway_state(home)
    if state and state != "running":
        return False, f"estado {state!r}"
    return True, f"PID {pid} {state or 'running'}"


def bridge_health(port: int, timeout: float = 3.0) -> dict | None:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=timeout) as r:  # noqa: S310
            return json.loads(r.read(4096).decode("utf-8", "replace"))
    except (urllib.error.URLError, urllib.error.HTTPError, OSError, json.JSONDecodeError):
        return None


def bridge_port_open(port: int, timeout: float = 1.0) -> bool:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        return sock.connect_ex(("127.0.0.1", port)) == 0
    finally:
        sock.close()


# --------------------------------------------------------------------------- #
# Acciones
# --------------------------------------------------------------------------- #
def python_for(agent_dir: Path) -> str:
    for rel in ("venv/Scripts/python.exe", "venv/bin/python"):
        cand = agent_dir / rel
        if cand.exists():
            return str(cand)
    return sys.executable


def start_gateway(home: Path, log: Log, dry_run: bool) -> bool:
    agent_dir = home / "hermes-agent"
    python = python_for(agent_dir)
    stdout_path = home / "cache" / "wake-gateway-stdout.log"
    env = dict(os.environ)
    env["PYTHONPATH"] = str(agent_dir)
    env.setdefault("HERMES_HOME", str(home))

    if dry_run:
        log(f"[dry-run] arrancaría: {python} -m hermes_cli.main gateway run --replace")
        return True

    log(f"arrancando gateway: {python} -m hermes_cli.main gateway run")
    try:
        with stdout_path.open("a", encoding="utf-8") as out:
            proc = subprocess.Popen(  # noqa: S603
                [python, "-m", "hermes_cli.main", "gateway", "run", "--replace"],
                cwd=str(agent_dir),
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=out,
                stderr=subprocess.STDOUT,
                creationflags=DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW,
                close_fds=True,
            )
    except OSError as exc:
        log(f"ERROR al arrancar: {exc}")
        return False
    log(f"lanzado PID {proc.pid} (log: {stdout_path})")
    return True


def wait_healthy(home: Path, log: Log, timeout: float) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        ok, detail = gateway_healthy(home)
        if ok:
            log(f"gateway arriba: {detail}")
            return True
        time.sleep(3)
    log(f"el gateway NO respondió en {int(timeout)}s")
    return False


def drain_bridge_messages(port: int, timeout: float = 3.0) -> list:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/messages", timeout=timeout) as r:  # noqa: S310
            data = json.loads(r.read(1 << 20).decode("utf-8", "replace"))
            return data if isinstance(data, list) else []
    except (urllib.error.URLError, urllib.error.HTTPError, OSError, json.JSONDecodeError):
        return []


def bridge_send(port: int, chat_id: str, message: str, timeout: float = 5.0) -> bool:
    payload = json.dumps({"chatId": chat_id, "message": message}).encode()
    req = urllib.request.Request(  # noqa: S310
        f"http://127.0.0.1:{port}/send", data=payload,
        headers={"Content-Type": "application/json"}, method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310
            return r.status == 200
    except (urllib.error.URLError, urllib.error.HTTPError, OSError):
        return False


def start_bridge(home: Path, log: Log, port: int, dry_run: bool) -> subprocess.Popen | None:
    """Arranca el bridge Baileys por fuera del gateway (solo para despertar)."""
    agent_dir = home / "hermes-agent"
    bridge_js = agent_dir / "scripts" / "whatsapp-bridge" / "bridge.js"
    node_candidates = sorted((home / "tools").glob("node-*/node.exe"))
    node = str(node_candidates[-1]) if node_candidates else None
    if not bridge_js.exists() or not node:
        log("no encuentro bridge.js o node: no puedo leer mensajes con el gateway caído")
        return None
    if dry_run:
        log(f"[dry-run] arrancaría el bridge: {node} {bridge_js} --port {port}")
        return None
    cmd = [node, str(bridge_js), "--port", str(port),
           "--session", str(home / "whatsapp" / "session"), "--mode", "bot"]
    log(f"arrancando bridge suelto: {' '.join(cmd)}")
    try:
        return subprocess.Popen(  # noqa: S603
            cmd, cwd=str(home), stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            creationflags=CREATE_NO_WINDOW,
            close_fds=True,
        )
    except OSError as exc:
        log(f"ERROR al arrancar el bridge: {exc}")
        return None


# --------------------------------------------------------------------------- #
# Cooldown / lock
# --------------------------------------------------------------------------- #
def cooldown_active(state_path: Path, seconds: int) -> float:
    data = read_json(state_path) or {}
    last = float(data.get("last_attempt") or 0)
    remaining = seconds - (time.time() - last)
    return remaining if remaining > 0 else 0.0


def mark_attempt(state_path: Path) -> None:
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(json.dumps({"last_attempt": time.time()}), encoding="utf-8")


def acquire_lock(path: Path) -> bool:
    try:
        fd = os.open(str(path), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        # lock viejo (más de 10 min) → se recicla
        try:
            if time.time() - path.stat().st_mtime > 600:
                path.unlink(missing_ok=True)
                return acquire_lock(path)
        except OSError:
            pass
        return False
    os.write(fd, str(os.getpid()).encode())
    os.close(fd)
    return True


def release_lock(path: Path) -> None:
    try:
        path.unlink()
    except OSError:
        pass


def cycle(home: Path, args, log: Log) -> int:
    ok, detail = gateway_healthy(home)
    if ok:
        log(f"gateway sano ({detail}) — nada que hacer")
        return 0

    log(f"gateway caído: {detail}")

    remaining = cooldown_active(home / "cache" / "wake-state.json", args.cooldown)
    if remaining > 0:
        log(f"cooldown activo: faltan {int(remaining)}s")
        return 2

    if not acquire_lock(home / "cache" / "wake.lock"):
        log("otra instancia ya está levantando el gateway")
        return 2

    try:
        if args.message:
            health = bridge_health(args.bridge_port)
            spawned = None
            if health is None:
                spawned = start_bridge(home, log, args.bridge_port, args.dry_run)
                for _ in range(20):
                    if bridge_health(args.bridge_port):
                        break
                    time.sleep(2)
                health = bridge_health(args.bridge_port)

            if health and str(health.get("status")) == "connected":
                msgs = drain_bridge_messages(args.bridge_port)
                if msgs:
                    chats = {m.get("chatId") for m in msgs if isinstance(m, dict) and m.get("chatId")}
                    log(f"despertar por WhatsApp: {len(msgs)} mensaje(s) de {sorted(c for c in chats if c)}")
                    for chat in chats:
                        if chat:
                            bridge_send(args.bridge_port, chat,
                                        "Hermes estaba caído. Lo estoy levantando; "
                                        "en un momento te respondo — repetí el mensaje si no llega.")
                else:
                    log("bridge arriba pero sin mensajes nuevos; arranco igual (modo vigilante)")
            elif health:
                log(f"bridge responde pero status={health.get('status')!r}; arranco igual")

            if spawned is not None:
                # el gateway va a levantar su propio bridge: libero el puerto primero
                try:
                    spawned.terminate()
                    spawned.wait(timeout=10)
                    log("bridge suelto detenido para dejar libre el puerto")
                except Exception:
                    log("no pude detener el bridge suelto (revisar puerto)")

        mark_attempt(home / "cache" / "wake-state.json")
        if not start_gateway(home, log, args.dry_run):
            return 1
        if args.dry_run:
            return 0
        return 0 if wait_healthy(home, log, args.wait) else 1
    finally:
        release_lock(home / "cache" / "wake.lock")


# --------------------------------------------------------------------------- #
# Programador de tareas (Windows)
# --------------------------------------------------------------------------- #
TASK_NAME = "HermesGatewayWatchdog"


def install_task(script: Path, interval_minutes: int) -> int:
    if os.name != "nt":
        print("--install-task solo aplica a Windows")
        return 1
    # schtasks no ejecuta .py directamente: preferir el .bat hermano
    target = script
    if target.suffix.lower() == ".py":
        bat = target.with_suffix(".bat")
        if bat.exists():
            target = bat
    tr = f'"{target}"'
    cmd = ["schtasks", "/Create", "/SC", "MINUTE", "/MO", str(interval_minutes),
           "/TN", TASK_NAME, "/TR", tr, "/F"]
    proc = subprocess.run(cmd, capture_output=True, text=True)  # noqa: S603
    print((proc.stdout or proc.stderr).strip())
    if proc.returncode == 0:
        print(f"Tarea '{TASK_NAME}' creada: cada {interval_minutes} min.")
    return proc.returncode


def uninstall_task() -> int:
    proc = subprocess.run(["schtasks", "/Delete", "/TN", TASK_NAME, "/F"],  # noqa: S603
                          capture_output=True, text=True)
    print((proc.stdout or proc.stderr).strip())
    return proc.returncode


# --------------------------------------------------------------------------- #
def main() -> int:
    ap = argparse.ArgumentParser(description="Levanta el gateway de Hermes si está caído.")
    ap.add_argument("--hermes-home", default=str(default_home()))
    ap.add_argument("--once", action="store_true", help="un solo chequeo (default)")
    ap.add_argument("--watch", action="store_true", help="bucle residente")
    ap.add_argument("--message", action="store_true", help="intentar despertar leyendo WhatsApp")
    ap.add_argument("--bridge-port", type=int, default=3000)
    ap.add_argument("--interval", type=int, default=30, help="segundos entre ciclos en --watch")
    ap.add_argument("--cooldown", type=int, default=120, help="segundos mínimos entre intentos")
    ap.add_argument("--wait", type=int, default=120, help="segundos a esperar el arranque")
    ap.add_argument("--dry-run", action="store_true", help="no ejecuta nada, solo registra")
    ap.add_argument("--quiet", action="store_true", help="sin salida por consola (solo log)")
    ap.add_argument("--install-task", action="store_true", help="registra tarea cada N minutos")
    ap.add_argument("--uninstall-task", action="store_true")
    ap.add_argument("--task-interval", type=int, default=1)
    args = ap.parse_args()

    if args.install_task:
        return install_task(Path(sys.argv[0]).resolve(), args.task_interval)
    if args.uninstall_task:
        return uninstall_task()

    home = Path(args.hermes_home).expanduser()
    log = Log(home / "cache" / "wake.log", echo=not args.quiet)

    if args.watch:
        log(f"vigilante iniciado (cada {args.interval}s) home={home}")
        while True:
            try:
                cycle(home, args, log)
            except KeyboardInterrupt:
                log("vigilante detenido por el usuario")
                return 0
            except Exception as exc:  # nunca morir por una excepción puntual
                log(f"ERROR en ciclo: {exc.__class__.__name__}: {exc}")
            time.sleep(max(5, args.interval))

    return cycle(home, args, log)


if __name__ == "__main__":
    raise SystemExit(main())
