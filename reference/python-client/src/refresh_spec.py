"""Refresh the OpenAPI snapshot and regenerate the Pydantic models.

    python -m uku_cli.scripts.refresh_spec [--base-url https://app.getuku.com]

`GET /api/v3/openapi.json` is UNAUTHENTICATED, so this runs in CI with no secret.

Scope: `components.schemas` ONLY — never operations. Operations are hand-written in
`client.py` on purpose. A full client generator (openapi-python-client and friends)
would have to hand-roll our custom `{data, meta, warnings}` envelope, the ETag lift and
the error taxonomy across ~182 operations, and every regeneration would emit a diff far
too large to review — which is exactly how a silent behavior change ships.

The generated models inherit `_base.ExtraAllowModel` (`extra="allow"`), so a spec ahead
of a stale snapshot adds fields rather than dropping them.
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import httpx

GENERATED_DIR = Path(__file__).resolve().parent.parent / "generated"
SNAPSHOT_PATH = GENERATED_DIR / "openapi.json"
MODELS_PATH = GENERATED_DIR / "models.py"
BASE_CLASS = "uku_cli.generated._base.ExtraAllowModel"

HEADER = """# ruff: noqa
# fmt: off
# =============================================================================
# GENERATED FILE — DO NOT EDIT BY HAND.
#
# Regenerate with:   python -m uku_cli.scripts.refresh_spec
# Source of truth:   GET /api/v3/openapi.json  (components.schemas only)
#
# Every model allows extra fields (see _base.ExtraAllowModel), so a live API ahead
# of this snapshot adds keys instead of silently dropping them.
# =============================================================================
"""


def fetch_spec(base_url: str, timeout: float = 60.0) -> dict:
    url = base_url.rstrip("/") + "/api/v3/openapi.json"
    print(f"Fetching {url} …", file=sys.stderr)
    response = httpx.get(url, timeout=timeout, follow_redirects=True)
    response.raise_for_status()
    return response.json()


def _schemas_only(spec: dict) -> dict:
    """A minimal valid OpenAPI doc carrying just the schema components."""
    schemas = (spec.get("components") or {}).get("schemas") or {}
    if not schemas:
        raise SystemExit("The spec contains no components.schemas — refusing to generate.")
    return {
        "openapi": spec.get("openapi", "3.1.0"),
        "info": spec.get("info", {"title": "Uku API v3", "version": "3"}),
        "paths": {},
        "components": {"schemas": schemas},
    }


def _codegen_command(codegen: str | None) -> list[str]:
    if codegen:
        return [codegen]
    if found := shutil.which("datamodel-codegen"):
        return [found]
    # Fall back to the current interpreter, so a venv install with no PATH entry works.
    return [sys.executable, "-m", "datamodel_code_generator"]


def generate_models(spec: dict, codegen: str | None = None) -> None:
    doc = _schemas_only(spec)
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / "schemas.json"
        target = Path(tmp) / "models.py"
        source.write_text(json.dumps(doc), encoding="utf-8")

        command = _codegen_command(codegen) + [
            "--input", str(source),
            "--input-file-type", "openapi",
            "--output", str(target),
            "--output-model-type", "pydantic_v2.BaseModel",
            # The extra="allow" guarantee, via a base class we own.
            "--base-class", BASE_CLASS,
            "--target-python-version", "3.10",
            "--use-union-operator",
            "--use-standard-collections",
            "--use-schema-description",
            "--field-constraints",
            "--snake-case-field",
            "--disable-timestamp",
        ]
        print("Running: " + " ".join(command), file=sys.stderr)
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            raise SystemExit(
                "datamodel-codegen failed. Install it with `pip install "
                f"'uku-cli[dev]'`.\n{result.stdout}\n{result.stderr}"
            )

        body = target.read_text(encoding="utf-8")

    GENERATED_DIR.mkdir(parents=True, exist_ok=True)
    MODELS_PATH.write_text(HEADER + "\n" + body, encoding="utf-8")
    print(f"Wrote {MODELS_PATH} ({len(body.splitlines())} lines)", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="https://app.getuku.com")
    parser.add_argument("--codegen", default=None,
                        help="Path to datamodel-codegen (default: PATH, then -m).")
    parser.add_argument("--skip-fetch", action="store_true",
                        help="Regenerate from the committed snapshot instead of the network.")
    args = parser.parse_args(argv)

    if args.skip_fetch:
        spec = json.loads(SNAPSHOT_PATH.read_text(encoding="utf-8"))
    else:
        spec = fetch_spec(args.base_url)
        GENERATED_DIR.mkdir(parents=True, exist_ok=True)
        SNAPSHOT_PATH.write_text(
            json.dumps(spec, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        print(f"Wrote {SNAPSHOT_PATH}", file=sys.stderr)

    generate_models(spec, codegen=args.codegen)
    print("Done. Review the diff and commit both files.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
