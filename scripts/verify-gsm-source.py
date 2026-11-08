#!/usr/bin/env python3
"""verify-gsm-source.py — prueba el source GSM de Hermes sin exponer valores.

Carga el plugin `gsm` desde <HERMES_HOME>/plugins/gsm, lo registra en el
registry de secret sources y corre `apply_all()` con la sección `secrets:` de
<HERMES_HOME>/config.yaml sobre un entorno vacío. Solo imprime nombres de
variables, estado, warnings y el binario usado — nunca los valores.

Uso (Windows, venv de Hermes):
    cd C:/Users/<user>/AppData/Local/hermes/hermes-agent
    PYTHONPATH="C:/Users/<user>/AppData/Local/hermes/hermes-agent" \
      venv/Scripts/python.exe C:/workspace/hermes/scripts/verify-gsm-source.py

Código de salida: 0 si todos los sources leyeron sus secretos, 1 si alguno falló.
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import sys
from pathlib import Path


def _default_home() -> Path:
    env = os.environ.get("HERMES_HOME")
    if env:
        return Path(env).expanduser()
    return Path.home() / ".hermes"


def main() -> int:
    ap = argparse.ArgumentParser(description="Verifica el secret source GSM de Hermes.")
    ap.add_argument("--home", default=str(_default_home()), help="HERMES_HOME (default: %(default)s)")
    args = ap.parse_args()

    home = Path(args.home).expanduser()
    agent_dir = home / "hermes-agent"
    plugin = home / "plugins" / "gsm" / "__init__.py"
    if not plugin.exists():
        print(f"ERROR: no existe el plugin GSM en {plugin}")
        return 1

    sys.path.insert(0, str(agent_dir))
    import yaml  # noqa: E402  (viene con el venv de Hermes)
    from agent.secret_sources.registry import apply_all, list_sources  # noqa: E402

    spec = importlib.util.spec_from_file_location("gsm_plugin", plugin)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)  # type: ignore[union-attr]

    class _Context:
        def register_secret_source(self, source):
            from agent.secret_sources.registry import register_source

            register_source(source)

    module.register(_Context())
    print("sources registrados:", [s.name for s in list_sources()])

    config = yaml.safe_load((home / "config.yaml").read_text(encoding="utf-8")) or {}
    report = apply_all(config.get("secrets", {}), home, environ={})

    failures = 0
    for src in report.sources:
        ok = src.result.ok
        failures += 0 if ok else 1
        print(f"[{'OK' if ok else 'FAIL'}] {src.name}: applied={src.applied} skipped_existing={src.skipped_existing}")
        for warning in src.result.warnings:
            print("  warning:", warning)
        if src.result.error:
            print("  error:", src.result.error_kind, "-", src.result.error)
        if src.result.binary_path:
            print("  binario:", src.result.binary_path)

    print("variables aplicadas (solo nombres):", sorted(report.provenance))
    if report.conflicts:
        print("conflictos:", report.conflicts)
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
