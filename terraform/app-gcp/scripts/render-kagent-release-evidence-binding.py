#!/usr/bin/env python3
"""Validate one private schema-3 kagent handoff and render exact HCL pins."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys


def fail(message: str) -> int:
    print(f"kagent release evidence binding: {message}", file=sys.stderr)
    return 2


def hcl_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--evidence-uri", required=True)
    parser.add_argument("--evidence-sha256", required=True)
    parser.add_argument("--gcloud", default="gcloud")
    args = parser.parse_args()

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
        module_dir = repository_root / "helm/kagent"
        sys.path.insert(0, str(module_dir))
        from kagent_release_evidence import (  # pylint: disable=import-outside-toplevel
            EVIDENCE_URI,
            expected_artifact,
            expected_helm_set_values,
            parse_manifest,
            validate_binding,
        )

        if args.evidence.is_symlink():
            raise ValueError("evidence must be a regular non-symlink file")
        evidence_path = args.evidence.resolve(strict=True)
        if not evidence_path.is_file():
            raise ValueError("evidence must be a regular non-symlink file")
        if not EVIDENCE_URI.fullmatch(args.evidence_uri):
            raise ValueError(
                "kagent release evidence URI must be the exact generation-qualified private .kap.5 object"
            )
        evidence_bytes = evidence_path.read_bytes()
        try:
            remote_evidence = subprocess.run(
                [args.gcloud, "storage", "cat", args.evidence_uri],
                check=True,
                capture_output=True,
            ).stdout
        except (OSError, subprocess.CalledProcessError) as error:
            raise ValueError(
                "gcloud storage cat could not read the exact evidence generation"
            ) from error
        if remote_evidence != evidence_bytes:
            raise ValueError("remote evidence generation bytes do not match local evidence")
        manifest_json = evidence_bytes.decode("utf-8")
        manifest, digest = parse_manifest(manifest_json)
        if digest != args.evidence_sha256:
            raise ValueError("evidence bytes do not match --evidence-sha256")
        artifact = expected_artifact(manifest, digest)
        helm_values = expected_helm_set_values(manifest)
        validate_binding(
            {"uri": args.evidence_uri, "manifest_json": manifest_json},
            artifact,
            helm_values,
        )
    except (OSError, UnicodeError, subprocess.CalledProcessError, ValueError) as error:
        return fail(str(error))

    print("# Fill these three fields into kagent_substrate_delivery after the successful build.")
    print("# The manifest is an exact string, not a reconstructed digest list.")
    print("kagent_release_evidence = {")
    print(f"  uri           = {hcl_string(args.evidence_uri)}")
    print(f"  manifest_json = {hcl_string(manifest_json)}")
    print("}")
    print("")
    print("kagent_artifact = {")
    for field in (
        "source_repository",
        "source_commit",
        "artifact_manifest_sha256",
        "artifact_schema_version",
        "artifact_manifest_path",
    ):
        print(f"  {field:<24} = {hcl_string(artifact[field])}")
    print("  charts = {")
    for name in ("application", "crds"):
        chart = artifact["charts"][name]
        print(f"    {name} = {{")
        print(f"      ref     = {hcl_string(chart['ref'])}")
        print(f"      version = {hcl_string(chart['version'])}")
        print("    }")
    print("  }")
    for field in ("image_refs", "runtime_images"):
        print(f"  {field} = {{")
        width = max(len(name) for name in artifact[field])
        for name, ref in artifact[field].items():
            print(f"    {name:<{width}} = {hcl_string(ref)}")
        print("  }")
    print("}")
    print("")
    print("kagent_helm_set_values = {")
    width = max(len(hcl_string(key)) for key in helm_values)
    for key in sorted(helm_values):
        print(f"  {hcl_string(key):<{width}} = {hcl_string(helm_values[key])}")
    print("}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
