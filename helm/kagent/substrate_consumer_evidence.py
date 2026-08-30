"""Closed validation for app-gcp's consumer-owned Substrate semver evidence."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path, PurePosixPath
import re
from typing import Any, NoReturn


SCHEMA_VERSION = "yourown.chat/substrate-semver-consumer-evidence/v1"
SOURCE_REPOSITORY = "https://github.com/pilprod/substrate"
OWNER_REPOSITORY = "https://github.com/pilprod/yourown-chat"
IMAGE_REGISTRY = "ghcr.io/pilprod/substrate"
IMAGE_REPOSITORIES = {
    "ateapi": "ateapi",
    "atecontroller": "atecontroller",
    "atelet": "atelet",
    "ateom-gvisor": "ateom-gvisor",
    "ateom-microvm": "ateom-microvm",
    "atenet": "atenet",
    "podcertcontroller": "podcertcontroller",
    "releaseVerifier": "substrate-release-verify",
}
DEPENDENCY_IMAGE_REF_PREFIX = "ghcr.io/kagent-dev/substrate/agentgateway@"
HELM_SET_KEYS = {
    "image.registry",
    "image.digests.ateapi",
    "image.digests.atecontroller",
    "image.digests.atenet",
    "images.agentgateway",
}
SHA256 = re.compile(r"^sha256:[0-9a-f]{64}$")
SHA256_HEX = re.compile(r"^[0-9a-f]{64}$")
GIT_SHA = re.compile(r"^[0-9a-f]{40}$")
RELEASE_TAG = re.compile(
    r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?$"
)
EVIDENCE_PATH = re.compile(
    r"^kagent/evidence/substrate/(v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)/"
    r"substrate-\1\.consumer-evidence\.json$"
)


def fail(message: str) -> NoReturn:
    raise ValueError(message)


def _exact_keys(value: object, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != expected:
        fail(f"{label} must contain exactly {', '.join(sorted(expected))}")
    return value


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"consumer evidence contains duplicate JSON key: {key}")
        result[key] = value
    return result


def _load_unique_json(raw: bytes) -> dict[str, Any]:
    try:
        value = json.loads(raw, object_pairs_hook=_unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"consumer evidence is not valid UTF-8 JSON: {error}")
    if not isinstance(value, dict):
        fail("consumer evidence must be one JSON object")
    return value


def _regular_file(path: Path, label: str) -> Path:
    if path.is_symlink():
        fail(f"{label} must not be a symbolic link")
    if not path.is_file():
        fail(f"{label} must be a regular file")
    return path.resolve()


def evidence_relative_path(path: Path, source_root: Path) -> str:
    source_root = source_root.resolve()
    path = _regular_file(path, "consumer evidence")
    try:
        relative = path.relative_to(source_root).as_posix()
    except ValueError:
        fail("consumer evidence must be below the Helm source root")
    if not EVIDENCE_PATH.fullmatch(relative):
        fail("consumer evidence path must match kagent/evidence/substrate/<tag>/substrate-<tag>.consumer-evidence.json")
    return relative


def validate_evidence(value: object) -> dict[str, Any]:
    manifest = _exact_keys(
        value,
        {
            "schema_version",
            "evidence",
            "deployment_class",
            "production_eligible",
            "source",
            "image_registry",
            "images",
            "dependency_images",
            "charts",
            "helm_set_values",
        },
        "consumer evidence",
    )
    if manifest["schema_version"] != SCHEMA_VERSION:
        fail(f"consumer evidence schema must be {SCHEMA_VERSION}")
    if manifest["deployment_class"] != "testbed" or manifest["production_eligible"] is not False:
        fail("consumer evidence must be production-ineligible testbed evidence")

    evidence = _exact_keys(
        manifest["evidence"],
        {"owner_repository", "origin", "producer_release_asset", "visibility"},
        "consumer evidence.evidence",
    )
    if evidence != {
        "owner_repository": OWNER_REPOSITORY,
        "origin": "consumer-observed-public-release",
        "producer_release_asset": False,
        "visibility": "public",
    }:
        fail("evidence must identify a public consumer observation, not a producer release asset")

    source = _exact_keys(
        manifest["source"],
        {"repository", "commit", "release_tag", "release_url"},
        "consumer evidence.source",
    )
    if source["repository"] != SOURCE_REPOSITORY:
        fail("consumer evidence source repository is not the reviewed fork")
    if not isinstance(source["commit"], str) or not GIT_SHA.fullmatch(source["commit"]):
        fail("consumer evidence source commit must be a full lowercase Git SHA")
    if not isinstance(source["release_tag"], str) or not RELEASE_TAG.fullmatch(source["release_tag"]):
        fail("consumer evidence release_tag must be a v-prefixed semantic version")
    expected_release_url = f"{SOURCE_REPOSITORY}/releases/tag/{source['release_tag']}"
    if source["release_url"] != expected_release_url:
        fail("consumer evidence release_url must match the reviewed repository and tag")
    version = source["release_tag"][1:]

    if manifest["image_registry"] != IMAGE_REGISTRY:
        fail("consumer evidence image_registry must be the reviewed public fork registry")
    images = _exact_keys(manifest["images"], set(IMAGE_REPOSITORIES), "consumer evidence.images")
    for name, repository in IMAGE_REPOSITORIES.items():
        image = _exact_keys(images[name], {"ref", "digest"}, f"consumer evidence.images.{name}")
        digest = image["digest"]
        if not isinstance(digest, str) or not SHA256.fullmatch(digest):
            fail(f"consumer evidence image {name} digest must be sha256-qualified")
        if image["ref"] != f"{IMAGE_REGISTRY}/{repository}@{digest}":
            fail(f"consumer evidence image {name} ref must exactly match its registry, repository and digest")

    dependencies = _exact_keys(
        manifest["dependency_images"], {"agentgateway"}, "consumer evidence.dependency_images"
    )
    agentgateway = _exact_keys(
        dependencies["agentgateway"], {"ref", "digest"}, "consumer evidence.dependency_images.agentgateway"
    )
    if not isinstance(agentgateway["digest"], str) or not SHA256.fullmatch(agentgateway["digest"]):
        fail("consumer evidence agentgateway digest must be sha256-qualified")
    if agentgateway["ref"] != DEPENDENCY_IMAGE_REF_PREFIX + agentgateway["digest"]:
        fail("consumer evidence agentgateway ref must match the reviewed upstream dependency and digest")

    charts = _exact_keys(manifest["charts"], {"application", "crds"}, "consumer evidence.charts")
    chart_contract = {
        "application": ("substrate", "substrate"),
        "crds": ("substrate-crds", "substrate-crds"),
    }
    for kind, (release_name, repository) in chart_contract.items():
        chart = _exact_keys(
            charts[kind], {"release_name", "ref", "version", "digest"}, f"consumer evidence.charts.{kind}"
        )
        if chart["release_name"] != release_name or chart["version"] != version:
            fail(f"consumer evidence chart {kind} release name and version must match release_tag")
        if not isinstance(chart["digest"], str) or not SHA256.fullmatch(chart["digest"]):
            fail(f"consumer evidence chart {kind} digest must be sha256-qualified")
        expected_ref = f"oci://{IMAGE_REGISTRY}/helm/{repository}@{chart['digest']}"
        if chart["ref"] != expected_ref:
            fail(f"consumer evidence chart {kind} ref must exactly match its registry, repository and digest")

    helm_values = _exact_keys(manifest["helm_set_values"], HELM_SET_KEYS, "consumer evidence.helm_set_values")
    expected_values = {
        "image.registry": IMAGE_REGISTRY,
        "image.digests.ateapi": images["ateapi"]["digest"],
        "image.digests.atecontroller": images["atecontroller"]["digest"],
        "image.digests.atenet": images["atenet"]["digest"],
        "images.agentgateway": agentgateway["ref"],
    }
    if helm_values != expected_values:
        fail("consumer evidence Helm set values must exactly map the chart-consumed image pins")
    return manifest


def load_evidence(
    path: Path,
    source_root: Path,
    expected_sha256: str | None = None,
) -> tuple[dict[str, Any], str, str]:
    relative = evidence_relative_path(path, source_root)
    path = path.resolve()
    checksum_path = _regular_file(Path(f"{path}.sha256"), "consumer evidence checksum")
    if path.stat().st_size > 1024 * 1024:
        fail("consumer evidence exceeds 1048576 bytes")
    if checksum_path.stat().st_size > 256:
        fail("consumer evidence checksum exceeds 256 bytes")
    raw = path.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    expected_checksum = f"{digest}  {path.name}\n"
    try:
        checksum = checksum_path.read_text(encoding="ascii")
    except UnicodeDecodeError as error:
        fail(f"consumer evidence checksum is not ASCII: {error}")
    if checksum != expected_checksum:
        fail("consumer evidence does not match its checked-in checksum")
    if expected_sha256 is not None and (not SHA256_HEX.fullmatch(expected_sha256) or digest != expected_sha256):
        fail("consumer evidence does not match artifact_manifest_sha256")
    manifest = validate_evidence(_load_unique_json(raw))
    tag = manifest["source"]["release_tag"]
    match = EVIDENCE_PATH.fullmatch(relative)
    if match is None or match.group(1) != tag:
        fail("consumer evidence filename and directory must match source.release_tag")
    if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        fail("consumer evidence changed while it was being validated")
    return manifest, digest, relative


def expected_artifact(manifest: dict[str, Any], digest: str, relative_path: str) -> dict[str, Any]:
    return {
        "source_repository": manifest["source"]["repository"],
        "source_commit": manifest["source"]["commit"],
        "artifact_manifest_sha256": digest,
        "artifact_schema_version": manifest["schema_version"],
        "artifact_manifest_path": relative_path,
        "charts": {
            kind: {"ref": manifest["charts"][kind]["ref"], "version": manifest["charts"][kind]["version"]}
            for kind in ("application", "crds")
        },
        "image_refs": {
            "ateapi": manifest["images"]["ateapi"]["ref"],
            "atecontroller": manifest["images"]["atecontroller"]["ref"],
            "atenet": manifest["images"]["atenet"]["ref"],
            "agentgateway": manifest["dependency_images"]["agentgateway"]["ref"],
            "releaseVerifier": manifest["images"]["releaseVerifier"]["ref"],
        },
    }


def validate_artifact(artifact: dict[str, Any], source_root: Path) -> None:
    path_value = artifact.get("artifact_manifest_path")
    if not isinstance(path_value, str) or not EVIDENCE_PATH.fullmatch(path_value):
        fail("Substrate consumer evidence requires a canonical artifact_manifest_path")
    pure_path = PurePosixPath(path_value)
    if pure_path.is_absolute() or ".." in pure_path.parts:
        fail("Substrate consumer evidence artifact_manifest_path must be repository-relative")
    manifest, digest, relative = load_evidence(
        source_root / pure_path,
        source_root,
        str(artifact.get("artifact_manifest_sha256", "")),
    )
    expected = expected_artifact(manifest, digest, relative)
    comparable = dict(artifact)
    if comparable.get("runtime_images") == {}:
        comparable.pop("runtime_images")
    if comparable != expected:
        fail("Substrate artifact fields must exactly match the checked-in consumer evidence")
