#!/usr/bin/env python3
"""Write a temporary, internally bound schema-3 evidence fixture for tests."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


SOURCE_COMMIT = "547cfe605940005173eb0372238339384102faa0"
VERSION = "0.0.0-external-slot.kap.5"
PRIVATE = "europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/kagent"
STAGING = "europe-west3-docker.pkg.dev/yourown-chat/kagent-staging/kagent"


def digest(label: str) -> str:
    return f"sha256:{hashlib.sha256(label.encode()).hexdigest()}"


def sha(label: str) -> str:
    return hashlib.sha256(label.encode()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--controller", required=True)
    parser.add_argument("--ui", required=True)
    parser.add_argument("--application", required=True)
    parser.add_argument("--crds", required=True)
    parser.add_argument("--kagent-harness", required=True)
    parser.add_argument("--codex-harness", required=True)
    args = parser.parse_args()

    evaluator = sha("test-only-evaluator")
    components = ("controller", "ui", "golang-adk", "codex-harness")
    platforms = {
        component: {
            "linux_amd64": digest(f"test-only-{component}-amd64"),
            "linux_arm64": digest(f"test-only-{component}-arm64"),
        }
        for component in components
    }
    targets = {}
    counter = 1
    for component in components:
        for architecture in ("amd64", "arm64"):
            key = f"{component}-linux-{architecture}"
            targets[key] = {
                "component": component,
                "os": "linux",
                "architecture": architecture,
                "imageReference": f"{STAGING}/{component}@{platforms[component][f'linux_{architecture}']}",
                "scanId": f"projects/yourown-chat/locations/europe/scans/00000000-0000-4000-8000-{counter:012d}",
                "decision": "pass",
                "evaluatorSha256": evaluator,
                "highCriticalFindingCount": 0,
                "suppressedHighCriticalFindingCount": 0,
                "blockingHighCriticalFindingCount": 0,
                "evidence": {
                    "scanIdSha256": sha(f"{key}-scan-id"),
                    "vulnerabilitiesSha256": sha(f"{key}-vulnerabilities"),
                    "severitiesSha256": sha(f"{key}-severities"),
                    "policyDecisionSha256": sha(f"{key}-policy"),
                },
            }
            counter += 1

    manifest = {
        "schemaVersion": 3,
        "channel": "preview",
        "tag": f"v{VERSION}",
        "source_repository": "https://github.com/pilprod/kagent",
        "source_commit": SOURCE_COMMIT,
        "chart_source": {
            "path": "helm/kagent",
            "tree": "1" * 40,
            "skills_init_removal_commit": "059c01b68584dea113ccdf80f2e356c2d051e02a",
        },
        "image_refs": {
            "controller": f"{PRIVATE}/controller@{args.controller}",
            "ui": f"{PRIVATE}/ui@{args.ui}",
        },
        "runtime_images": {
            "kagentHarness": f"{PRIVATE}/golang-adk@{args.kagent_harness}",
            "codexHarness": f"{PRIVATE}/codex-harness@{args.codex_harness}",
        },
        "platform_image_digests": platforms,
        "build_toolchain": {"buildkit": f"moby/buildkit@{digest('test-only-buildkit')}"},
        "security_scans": {
            "schema": "yourown.chat/kagent-platform-scan-evidence/v1",
            "scanner": "Google Artifact Analysis On-Demand Scanning",
            "decision": "pass",
            "policy": {
                "id": "kagent-istio-pseudoversion-google-scanner-v1",
                "evaluatorSha256": evaluator,
                "blockedEffectiveSeverities": ["HIGH", "CRITICAL"],
            },
            "evidenceManifestSha256": sha("test-only-scan-evidence"),
            "releaseLock": {
                "uri": (
                    "gs://yourown-chat-kagent-preview-evidence-europe-west3/"
                    f"kagent/{VERSION}/release.lock#1"
                ),
                "sha256": sha("test-only-release-lock"),
            },
            "targets": targets,
        },
        "charts": {
            "application": {
                "ref": f"oci://{PRIVATE}/helm/kagent@{args.application}",
                "version": VERSION,
            },
            "crds": {
                "ref": f"oci://{PRIVATE}/helm/kagent-crds@{args.crds}",
                "version": VERSION,
            },
        },
    }
    args.output.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
