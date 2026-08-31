#!/usr/bin/env python3
"""Render one immutable kagent candidate through dev then approved prod."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
from typing import NoReturn

from substrate_consumer_evidence import (
    SCHEMA_VERSION as SUBSTRATE_CONSUMER_EVIDENCE_SCHEMA,
    validate_artifact as validate_substrate_consumer_artifact,
)


CHART_REF = re.compile(r"^oci://[^\s@]+@sha256:[0-9a-f]{64}$")
IMAGE_REF = re.compile(r"^[^\s@:]+(?:/[^\s@:]+)+@sha256:[0-9a-f]{64}$")
VERSION = re.compile(r"^v?[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")
HELM_KEY = re.compile(r"^[A-Za-z0-9_.\-/\[\]]+$")
EXPECTED_ARTIFACTS = {"kagent", "substrate"}
EXPECTED_VALUES = {
    "kagent/kagent.values.yaml",
    "kagent/kagent-dev.values.yaml",
    "kagent/kagent-prod.values.yaml",
    "kagent/substrate.values.yaml",
}
EXPECTED_REPOSITORIES = {
    "kagent": "https://github.com/pilprod/kagent",
    "substrate": "https://github.com/pilprod/substrate",
}
KAGENT_IMAGE_PATHS = {
    "controller": "controller.image",
    "ui": "ui.image",
}
KAGENT_RUNTIME_IMAGES = {"kagentHarness", "codexHarness"}
SUBSTRATE_COMPONENT_IMAGES = {"ateapi", "atecontroller", "atenet"}
SUBSTRATE_ARTIFACT_IMAGES = SUBSTRATE_COMPONENT_IMAGES | {"agentgateway", "releaseVerifier"}
SUBSTRATE_PRIVATE_PRODUCER_EVIDENCE_SCHEMA = "yourown.chat/substrate-private-gar-release/v2"
SUBSTRATE_PRIVATE_REGISTRY = "europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/substrate"
SUBSTRATE_PRIVATE_IMAGE_REPOSITORIES = {
    "agentgateway": "agentgateway",
    "ateapi": "ateapi",
    "atecontroller": "atecontroller",
    "atenet": "atenet",
    "releaseVerifier": "substrate-release-verify",
}
SUBSTRATE_PRIVATE_CHART_REPOSITORIES = {
    "application": "substrate",
    "crds": "substrate-crds",
}
KAGENT_SET_KEYS = {
    f"{path}.{field}"
    for path in KAGENT_IMAGE_PATHS.values()
    for field in ("registry", "repository", "tag")
}
SUBSTRATE_SET_KEYS = {
    "image.registry",
    *(f"image.digests.{name}" for name in SUBSTRATE_COMPONENT_IMAGES),
    "images.agentgateway",
}
KAGENT_DISABLED_SUBCHARTS = {
    "kmcp",
    "substrate",
    "kagent-tools",
    "grafana-mcp",
    "querydoc",
    "oauth2-proxy",
    "k8s-agent",
    "kgateway-agent",
    "istio-agent",
    "promql-agent",
    "observability-agent",
    "argo-rollouts-agent",
    "helm-agent",
    "cilium-policy-agent",
    "cilium-manager-agent",
    "cilium-debug-agent",
}


def fail(message: str) -> NoReturn:
    raise ValueError(message)


def quoted(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def load_contract() -> dict:
    raw = os.environ.get("KAGENT_SUBSTRATE_RELEASE_JSON", "")
    if not raw:
        fail("KAGENT_SUBSTRATE_RELEASE_JSON is required")
    try:
        contract = json.loads(raw)
    except json.JSONDecodeError as error:
        fail(f"release contract is not valid JSON: {error}")
    if not isinstance(contract, dict):
        fail("release contract must be a JSON object")
    return contract


def validate_artifact(name: str, artifact: object, source_root: Path) -> None:
    if not isinstance(artifact, dict):
        fail(f"artifact {name} must be an object")
    if artifact.get("source_repository") != EXPECTED_REPOSITORIES[name]:
        fail(f"artifact {name} source_repository is not the reviewed repository")
    if not re.fullmatch(r"[0-9a-f]{40}", str(artifact.get("source_commit", ""))):
        fail(f"artifact {name} source_commit must be a full lowercase Git SHA")
    if not re.fullmatch(r"[0-9a-f]{64}", str(artifact.get("artifact_manifest_sha256", ""))):
        fail(f"artifact {name} manifest checksum must be a lowercase SHA-256")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", str(artifact.get("artifact_schema_version", ""))):
        fail(f"artifact {name} schema version is invalid")
    if name == "kagent" and artifact.get("artifact_schema_version") != "3":
        fail("kagent artifact must use release evidence schema 3")
    if name == "kagent" and artifact.get("artifact_manifest_path", ""):
        fail("kagent producer evidence must not use an app-gcp artifact_manifest_path")
    if name == "substrate":
        schema = artifact.get("artifact_schema_version")
        manifest_path = artifact.get("artifact_manifest_path", "")
        if schema == SUBSTRATE_CONSUMER_EVIDENCE_SCHEMA:
            validate_substrate_consumer_artifact(artifact, source_root)
        elif schema == SUBSTRATE_PRIVATE_PRODUCER_EVIDENCE_SCHEMA:
            if manifest_path:
                fail("private Substrate producer evidence must not use an app-gcp artifact_manifest_path")
        else:
            fail("substrate artifact must use private GAR release schema v2 or checked-in semver consumer evidence")
    charts = artifact.get("charts")
    if not isinstance(charts, dict) or set(charts) != {"application", "crds"}:
        fail(f"artifact {name} must pin application and CRD charts")
    for chart_kind, chart in charts.items():
        if not isinstance(chart, dict):
            fail(f"artifact {name} chart {chart_kind} must be an object")
        if not CHART_REF.fullmatch(str(chart.get("ref", ""))):
            fail(f"artifact {name} chart {chart_kind} must use an OCI digest reference")
        if not VERSION.fullmatch(str(chart.get("version", ""))):
            fail(f"artifact {name} chart {chart_kind} needs an explicit semantic version")
    images = artifact.get("image_refs")
    if not isinstance(images, dict) or not images:
        fail(f"artifact {name} image_refs must be non-empty")
    for image_name, ref in images.items():
        if not IMAGE_REF.fullmatch(str(ref)):
            fail(f"image {name}/{image_name} must be registry/repository@sha256")
    if name == "substrate" and artifact.get("artifact_schema_version") == SUBSTRATE_PRIVATE_PRODUCER_EVIDENCE_SCHEMA:
        application_version = str(charts["application"]["version"])
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+-private\.[0-9]+", application_version):
            fail("private Substrate charts must use a private immutable release version")
        for chart_kind, repository in SUBSTRATE_PRIVATE_CHART_REPOSITORIES.items():
            chart = charts[chart_kind]
            if chart["version"] != application_version:
                fail("private Substrate application and CRD charts must use the same release version")
            expected_prefix = f"oci://{SUBSTRATE_PRIVATE_REGISTRY}/helm/{repository}@"
            if not str(chart["ref"]).startswith(expected_prefix):
                fail(f"private Substrate chart {chart_kind} must come from the reviewed private GAR registry")
        for image_name, repository in SUBSTRATE_PRIVATE_IMAGE_REPOSITORIES.items():
            expected_prefix = f"{SUBSTRATE_PRIVATE_REGISTRY}/{repository}@"
            if not str(images.get(image_name, "")).startswith(expected_prefix):
                fail(f"private Substrate image {image_name} must come from the reviewed private GAR registry")
    runtime_images = artifact.get("runtime_images", {})
    if not isinstance(runtime_images, dict):
        fail(f"artifact {name} runtime_images must be an object")
    for image_name, ref in runtime_images.items():
        if not IMAGE_REF.fullmatch(str(ref)):
            fail(f"runtime image {name}/{image_name} must be registry/repository@sha256")


def split_image_ref(ref: str) -> tuple[str, str, str]:
    repository_ref, digest = ref.split("@", 1)
    registry, repository = repository_ref.rsplit("/", 1)
    return registry, repository, digest


def validate_image_overrides(contract: dict) -> None:
    artifacts = contract["artifacts"]
    helm_values = contract["helm_set_values"]
    kagent_images = artifacts["kagent"]["image_refs"]
    kagent_runtime_images = artifacts["kagent"]["runtime_images"]
    substrate_images = artifacts["substrate"]["image_refs"]
    if set(kagent_images) != set(KAGENT_IMAGE_PATHS):
        fail("kagent image_refs must contain exactly controller and ui")
    if set(kagent_runtime_images) != KAGENT_RUNTIME_IMAGES:
        fail("kagent runtime_images must contain exactly kagentHarness and codexHarness")
    if artifacts["substrate"].get("runtime_images", {}):
        fail("substrate artifact must not declare kagent runtime_images")
    if set(substrate_images) != SUBSTRATE_ARTIFACT_IMAGES:
        fail("substrate image_refs must contain exactly ateapi, atecontroller, atenet, agentgateway and releaseVerifier")

    kagent_values = helm_values["kagent"]
    if set(kagent_values) != KAGENT_SET_KEYS:
        fail("helm_set_values.kagent may contain only the exact immutable image registry/repository/tag keys")
    chart_version = artifacts["kagent"]["charts"]["application"]["version"]
    for image_name, path in KAGENT_IMAGE_PATHS.items():
        registry, repository, digest = split_image_ref(kagent_images[image_name])
        expected = {
            f"{path}.registry": registry,
            f"{path}.repository": repository,
            f"{path}.tag": f"{chart_version}@{digest}",
        }
        for key, value in expected.items():
            if kagent_values.get(key) != value:
                fail(f"helm_set_values.kagent.{key} must map {image_name} as chart-version@digest")

    substrate_values = helm_values["substrate"]
    if set(substrate_values) != SUBSTRATE_SET_KEYS:
        fail("helm_set_values.substrate may contain only the exact external-profile image keys")
    component_registries = set()
    for image_name in SUBSTRATE_COMPONENT_IMAGES:
        registry, repository, digest = split_image_ref(substrate_images[image_name])
        if repository != image_name:
            fail(f"substrate image {image_name} must use the matching component repository")
        component_registries.add(registry)
        if substrate_values.get(f"image.digests.{image_name}") != digest:
            fail(f"helm_set_values.substrate.image.digests.{image_name} must match the artifact")
    if len(component_registries) != 1 or substrate_values.get("image.registry") not in component_registries:
        fail("substrate component images must share the explicitly mapped registry")
    if substrate_values.get("images.agentgateway") != substrate_images["agentgateway"]:
        fail("helm_set_values.substrate.images.agentgateway must match the artifact")
    verifier_registry, verifier_repository, _ = split_image_ref(substrate_images["releaseVerifier"])
    if verifier_registry not in component_registries or verifier_repository != "substrate-release-verify":
        fail("substrate releaseVerifier must be the immutable substrate-release-verify image from the artifact registry")


def yaml_scalar(source: str, path: tuple[str, ...]) -> str | None:
    stack: list[tuple[int, str]] = []
    for line in source.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or stripped.startswith("-"):
            continue
        indentation = len(line) - len(line.lstrip(" "))
        match = re.fullmatch(r"([A-Za-z0-9_.-]+):(?:[ \t]*(.*))?", stripped)
        if not match:
            continue
        while stack and indentation <= stack[-1][0]:
            stack.pop()
        key, value = match.group(1), (match.group(2) or "").strip()
        current = tuple(item[1] for item in stack) + (key,)
        if current == path:
            return value
        if not value:
            stack.append((indentation, key))
    return None


def validate_tracked_kagent_shape(source_root: Path) -> None:
    path = source_root / "kagent/kagent.values.yaml"
    source = path.read_text(encoding="utf-8")
    if yaml_scalar(source, ("controller", "agentImage")) is not None:
        fail("tracked kagent values must not define removed controller.agentImage")
    for subchart in KAGENT_DISABLED_SUBCHARTS:
        if yaml_scalar(source, (subchart, "enabled")) != "false":
            fail(f"tracked kagent values must keep optional subchart {subchart}.enabled=false")
    if yaml_scalar(source, ("substrateWorkerPool", "create")) != "false":
        fail("tracked kagent values must keep substrateWorkerPool.create=false")
    if yaml_scalar(source, ("rbac", "create")) != "false":
        fail("tracked kagent values must keep rbac.create=false")
    expected_scalars = {
        ("fullnameOverride",): "kagent",
        ("controller", "auth", "mode"): "unsecure",
        ("database", "postgres", "urlFile"): "/var/run/secrets/kagent-database/database-url",
        ("database", "postgres", "vectorEnabled"): "false",
        ("database", "postgres", "bundled", "enabled"): "false",
        ("providers", "default"): "ollama",
    }
    for setting_path, expected in expected_scalars.items():
        if yaml_scalar(source, setting_path) != expected:
            fail(f"tracked kagent values must preserve {'.'.join(setting_path)}={expected}")
    for required in ("driver: secrets-store-gke.csi.k8s.io", "failureThreshold: 20"):
        if required not in source:
            fail(f"tracked kagent values must preserve the shared setting: {required}")
    if "namespaceOverride:" in source or "secretProviderClass:" in source or "host: http://model-fixture." in source:
        fail("base kagent values must remain environment-neutral")
    overlays = {
        "dev": {
            "path": source_root / "kagent/kagent-dev.values.yaml",
            "required": (
                "namespaceOverride: kagent-dev",
                "- agent-codex-dev",
                "secretProviderClass: kagent-dev-database-gcp",
                "name: kagent-dev-ate-client-tls",
                "host: http://model-fixture.agent-codex-dev.svc.cluster.local:11434",
            ),
        },
        "prod": {
            "path": source_root / "kagent/kagent-prod.values.yaml",
            "required": (
                "namespaceOverride: kagent-system",
                "- agent-codex",
                "secretProviderClass: kagent-database-gcp",
                "name: kagent-ate-client-tls",
                "host: http://model-fixture.agent-codex.svc.cluster.local:11434",
            ),
        },
    }
    for environment, overlay in overlays.items():
        overlay_source = overlay["path"].read_text(encoding="utf-8")
        for required in overlay["required"]:
            if required not in overlay_source:
                fail(f"tracked {environment} kagent values must preserve: {required}")
    if "skillsInitImage:" in source:
        fail("tracked kagent values must not restore the obsolete skills-init image")


def validate_contract(contract: dict, source_root: Path) -> None:
    if contract.get("production_eligible") is not True:
        fail("dev-to-prod promotion requires production_eligible=true")
    if not isinstance(contract.get("external_broker_smoke_ready"), bool):
        fail("external_broker_smoke_ready must be an explicit boolean attestation")
    artifacts = contract.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != EXPECTED_ARTIFACTS:
        fail("artifacts must contain exactly kagent and substrate")
    for name, artifact in artifacts.items():
        validate_artifact(name, artifact, source_root)

    compatibility = contract.get("compatibility")
    if not isinstance(compatibility, dict):
        fail("compatibility contract is required")
    if compatibility.get("kagent_rbac_create_false") is not True:
        fail("kagent artifact must prove rbac.create=false support")
    if compatibility.get("kagent_obsolete_skills_init_removed") is not True:
        fail("kagent artifact must prove the obsolete skills-init image is removed")
    if compatibility.get("substrate_rbac_create_false") is not True:
        fail("substrate artifact must prove rbac.create=false support")
    if compatibility.get("substrate_gateway_api_v1") is not True:
        fail("substrate artifact must prove Gateway and TLSRoute gateway.networking.k8s.io/v1 support")
    if compatibility.get("substrate_go_module_commit") != artifacts["substrate"]["source_commit"]:
        fail("kagent Substrate Go dependency must match the deployed Substrate source commit")

    helm_set_values = contract.get("helm_set_values")
    if not isinstance(helm_set_values, dict) or set(helm_set_values) != EXPECTED_ARTIFACTS:
        fail("helm_set_values must contain exactly kagent and substrate")
    for artifact_name, values in helm_set_values.items():
        if not isinstance(values, dict) or not values:
            fail(f"helm_set_values.{artifact_name} must be a non-empty object")
        for key, value in values.items():
            if not HELM_KEY.fullmatch(str(key)) or not isinstance(value, str):
                fail(f"helm_set_values.{artifact_name} entries must be string keys and values")
    validate_image_overrides(contract)

    values_sha256 = contract.get("values_sha256")
    if not isinstance(values_sha256, dict) or set(values_sha256) != EXPECTED_VALUES:
        fail("values_sha256 must checksum exactly the tracked base, dev, prod and Substrate values files")
    for relative_path, expected in values_sha256.items():
        if not re.fullmatch(r"[0-9a-f]{64}", str(expected)):
            fail(f"values checksum for {relative_path} is invalid")
        path = source_root / relative_path
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            fail(f"tracked values checksum mismatch: {relative_path}")
    validate_tracked_kagent_shape(source_root)

    if contract.get("kagent_health_url") != (
        "http://kagent-controller.kagent-system.svc.cluster.local:8083/health"
    ):
        fail("kagent_health_url must use the controller HTTP /health endpoint on 8083")
    if not re.fullmatch(r"api\.ate-system\.svc\.cluster\.local:[0-9]+", str(contract.get("substrate_endpoint", ""))):
        fail("substrate_endpoint must be the canonical internal host:port api.ate-system")
    if contract.get("broker_server_name") != "api.ate-system.svc":
        fail("broker_server_name must preserve the canonical TLS SNI api.ate-system.svc")


def set_values_lines(values: dict[str, str], indent: str) -> list[str]:
    lines = [f"{indent}setValues:"]
    for key in sorted(values):
        lines.append(f"{indent}  {quoted(key)}: {quoted(values[key])}")
    return lines


def render_profile(
    *,
    name: str,
    release_name: str,
    namespace: str,
    health_url: str,
    kagent: dict,
    contract: dict,
) -> list[str]:
    lines = [
        f"  - name: {name}",
        "    manifests:",
        "      helm:",
        "        releases:",
        f"          - name: {release_name}",
        f"            remoteChart: {quoted(kagent['ref'])}",
        f"            version: {quoted(kagent['version'])}",
        f"            namespace: {namespace}",
        "            createNamespace: false",
        "            valuesFiles:",
        "              - kagent/kagent.values.yaml",
        f"              - kagent/{name}.values.yaml",
    ]
    lines.extend(set_values_lines(contract["helm_set_values"]["kagent"], "            "))
    lines.extend(
        [
            "    verify:",
            f"      - name: {name}-health",
            "        container:",
            "          name: smoke-test",
            f"          image: {quoted(contract['artifacts']['substrate']['image_refs']['releaseVerifier'])}",
            '          command: ["/ko-app/substrate-release-verify"]',
            "          args:",
            "            - --kagent-health-url",
            f"            - {quoted(health_url)}",
            "            - --substrate-endpoint",
            f"            - {quoted(contract['substrate_endpoint'])}",
            "            - --substrate-ca-file",
            "            - /var/run/secrets/substrate/server-ca.pem",
            "            - --substrate-server-name",
            "            - api.ate-system.svc",
            "            - --token-file",
            "            - /var/run/secrets/tokens/substrate-token",
            "            - --expected-audience",
            "            - api.ate-system.svc",
            "            - --kubernetes-token-file",
            "            - /var/run/secrets/tokens/kubernetes-token",
            "            - --kubernetes-ca-file",
            "            - /var/run/secrets/tokens/kubernetes-ca.crt",
            "            - --gateway-namespace",
            "            - ate-system",
            "            - --gateway-name",
            "            - external-provider-broker",
            "            - --tls-route-name",
            "            - external-provider-broker",
            "            - --require-gateway-programmed",
            "        executionMode:",
            "          kubernetesCluster:",
            "            jobManifestPath: kagent/verify/promotion-job.yaml",
        ]
    )
    return lines


def render_gate_action(source_root: Path) -> list[str]:
    gate_script_path = source_root / "kagent/verify/require-external-broker-smoke.sh"
    if not gate_script_path.is_file():
        fail("production promotion gate script is missing")
    gate_script = gate_script_path.read_text(encoding="utf-8")
    if "configmap/kagent-production-promotion-gate" not in gate_script:
        fail("production promotion gate must read the Terraform-managed ConfigMap")
    if 'attestation}" != "true|${CLOUD_DEPLOY_RELEASE}"' not in gate_script:
        fail("production promotion gate must bind the smoke attestation to this Cloud Deploy release")
    return [
        "customActions:",
        "  - name: require-external-broker-smoke",
        "    containers:",
        "      - name: require-external-broker-smoke",
        "        image: gcr.io/cloud-builders/kubectl@sha256:3744bfd3765ac2a09133a164fcd74c8468fac192af8accadbdfbccbb20643961",
        '        command: ["/bin/sh", "-ceu"]',
        "        args:",
        "          - |",
        *[f"            {line}" for line in gate_script.splitlines()],
    ]


def render(contract: dict, source_root: Path) -> str:
    kagent = contract["artifacts"]["kagent"]["charts"]["application"]
    substrate_consumer_evidence = (
        contract["artifacts"]["substrate"]["artifact_schema_version"]
        == SUBSTRATE_CONSUMER_EVIDENCE_SCHEMA
    )
    lines = [
        "# Generated from reviewed immutable artifact evidence.",
        *(
            ["# Substrate pins use app-gcp consumer evidence; this was not a producer release asset."]
            if substrate_consumer_evidence
            else []
        ),
        "# production_eligible=true: one immutable digest set is promoted dev -> approved prod.",
        "# Production PREDEPLOY reads a release-bound Terraform smoke attestation; dev remains deployable while it is false.",
        "# Shared Substrate in ate-system remains a Terraform-owned prerequisite and is not redeployed per stage.",
        "# Runtime images are evidence only; installing this release does not create a Harness.",
        f"# runtime_images.kagentHarness={contract['artifacts']['kagent']['runtime_images']['kagentHarness']}",
        f"# runtime_images.codexHarness={contract['artifacts']['kagent']['runtime_images']['codexHarness']}",
        "apiVersion: skaffold/v4beta11",
        "kind: Config",
        "metadata:",
        "  name: kagent-promotion",
        "deploy:",
        "  kubectl: {}",
        "profiles:",
    ]
    lines.extend(
        render_profile(
            name="kagent-dev",
            release_name="kagent-dev",
            namespace="kagent-dev",
            health_url="http://kagent-controller.kagent-dev.svc.cluster.local:8083/health",
            kagent=kagent,
            contract=contract,
        )
    )
    lines.extend(
        render_profile(
            name="kagent-prod",
            release_name="kagent",
            namespace="kagent-system",
            health_url=contract["kagent_health_url"],
            kagent=kagent,
            contract=contract,
        )
    )
    lines.extend(render_gate_action(source_root))
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, default=Path("."))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        contract = load_contract()
        validate_contract(contract, args.source_root)
        rendered = render(contract, args.source_root)
    except ValueError as error:
        print(f"render-release: {error}", file=sys.stderr)
        return 2
    args.output.write_text(rendered, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
