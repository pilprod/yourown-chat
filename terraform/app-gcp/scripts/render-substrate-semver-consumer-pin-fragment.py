#!/usr/bin/env python3
"""Validate checked-in Substrate semver consumer evidence and render HCL pins."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys


def fail(message: str) -> int:
    print(f"substrate semver consumer pin fragment: {message}", file=sys.stderr)
    return 2


def hcl_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def main() -> int:
    if len(sys.argv) != 2:
        print(
            "usage: render-substrate-semver-consumer-pin-fragment.py "
            "helm/kagent/evidence/substrate/<tag>/substrate-<tag>.consumer-evidence.json",
            file=sys.stderr,
        )
        return 2
    script_dir = Path(__file__).resolve().parent
    try:
        repository_root = Path(
            subprocess.run(
                ["git", "-C", str(script_dir), "rev-parse", "--show-toplevel"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
        ).resolve()
    except (OSError, subprocess.CalledProcessError) as error:
        return fail(f"the renderer must run from a Git checkout: {error}")
    module_dir = repository_root / "helm/kagent"
    sys.path.insert(0, str(module_dir))
    try:
        from substrate_consumer_evidence import (  # pylint: disable=import-outside-toplevel
            expected_artifact,
            load_evidence,
        )

        source_root = repository_root / "helm"
        manifest, digest, relative = load_evidence(Path(sys.argv[1]), source_root)
        artifact = expected_artifact(manifest, digest, relative)
    except (ImportError, OSError, ValueError) as error:
        return fail(str(error))

    print("# INCOMPLETE Substrate-only handoff; this is not a full kagent_substrate_delivery value.")
    print("# Consumer-owned public semver evidence; this was not emitted as a producer release asset.")
    print(f"# evidence_path: helm/{relative}")
    print(f"# evidence_sha256: {digest}")
    print(f"# release_url: {manifest['source']['release_url']}")
    for image_name in ("atelet", "ateom-gvisor", "ateom-microvm", "podcertcontroller"):
        print(f"# provenance_image.{image_name}: {manifest['images'][image_name]['ref']}")
    print("substrate_artifact = {")
    for field in (
        "source_repository",
        "source_commit",
        "artifact_manifest_sha256",
        "artifact_schema_version",
        "artifact_manifest_path",
    ):
        print(f"  {field:<24} = {hcl_string(artifact[field])}")
    print("  charts = {")
    for kind in ("application", "crds"):
        chart = artifact["charts"][kind]
        print(f"    {kind} = {{")
        print(f"      ref     = {hcl_string(chart['ref'])}")
        print(f"      version = {hcl_string(chart['version'])}")
        print("    }")
    print("  }")
    print("  image_refs = {")
    for name, ref in artifact["image_refs"].items():
        print(f"    {name:<15} = {hcl_string(ref)}")
    print("  }")
    print("}")
    print("")
    print("substrate_helm_set_values = {")
    quoted_keys = {key: hcl_string(key) for key in manifest["helm_set_values"]}
    key_width = max(len(key) for key in quoted_keys.values())
    for key in sorted(manifest["helm_set_values"]):
        print(f"  {quoted_keys[key]:<{key_width}} = {hcl_string(manifest['helm_set_values'][key])}")
    print("}")
    print(
        "substrate semver consumer pin fragment: rendered Substrate pins only; "
        "independent reviewed kagent evidence and all bootstrap gates remain required.",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
