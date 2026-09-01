"""Validate and bind the private kagent schema-3 release evidence."""

from __future__ import annotations

import hashlib
import json
import re
from typing import NoReturn


SCHEMA_VERSION = 3
SOURCE_REPOSITORY = "https://github.com/pilprod/kagent"
SOURCE_COMMIT = "547cfe605940005173eb0372238339384102faa0"
RELEASE_VERSION = "0.0.0-external-slot.kap.5"
PRIVATE_REGISTRY = "europe-west3-docker.pkg.dev/yourown-chat/kagent-preview/kagent"
STAGING_REGISTRY = "europe-west3-docker.pkg.dev/yourown-chat/kagent-staging/kagent"
EVIDENCE_URI = re.compile(
    r"^gs://yourown-chat-kagent-preview-evidence-europe-west3/"
    r"kagent/0\.0\.0-external-slot\.kap\.5/"
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/"
    r"release-evidence\.json#[1-9][0-9]*$"
)
SHA256 = re.compile(r"^[0-9a-f]{64}$")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
SCAN_ID = re.compile(
    r"^projects/yourown-chat/locations/europe/scans/"
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
)
IMAGE_REPOSITORIES = {
    "controller": "controller",
    "ui": "ui",
}
RUNTIME_REPOSITORIES = {
    "kagentHarness": "golang-adk",
    "codexHarness": "codex-harness",
}
CHART_REPOSITORIES = {
    "application": "kagent",
    "crds": "kagent-crds",
}
PLATFORM_COMPONENTS = {"controller", "ui", "golang-adk", "codex-harness"}
TARGETS = {
    f"{component}-linux-{architecture}"
    for component in PLATFORM_COMPONENTS
    for architecture in ("amd64", "arm64")
}
SCAN_POLICY_EVALUATOR_SHA256 = "661f3833e61ddf815b71427d93dc120d20e787fe1ff974395bff13091824b108"


def fail(message: str) -> NoReturn:
    raise ValueError(message)


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _exact_object(value: object, keys: set[str], label: str) -> dict:
    if not isinstance(value, dict) or set(value) != keys:
        fail(f"{label} must contain exactly {', '.join(sorted(keys))}")
    return value


def _sha256(value: object, label: str) -> str:
    if not isinstance(value, str) or not SHA256.fullmatch(value):
        fail(f"{label} must be a lowercase SHA-256")
    return value


def _digest(value: object, label: str) -> str:
    if not isinstance(value, str) or not DIGEST.fullmatch(value):
        fail(f"{label} must be a sha256 digest")
    return value


def _positive_count(value: object, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        fail(f"{label} must be a non-negative integer")
    return value


def parse_manifest(manifest_json: object) -> tuple[dict, str]:
    """Parse exact producer bytes and validate the complete schema-3 envelope."""

    if not isinstance(manifest_json, str) or not manifest_json:
        fail("kagent release evidence manifest_json must be a non-empty string")
    if not manifest_json.endswith("\n"):
        fail("kagent release evidence manifest_json must preserve the producer trailing newline")
    try:
        manifest = json.loads(manifest_json, object_pairs_hook=_unique_object)
    except json.JSONDecodeError as error:
        fail(f"kagent release evidence is not valid JSON: {error}")
    root = _exact_object(
        manifest,
        {
            "schemaVersion",
            "channel",
            "tag",
            "source_repository",
            "source_commit",
            "chart_source",
            "image_refs",
            "runtime_images",
            "platform_image_digests",
            "build_toolchain",
            "security_scans",
            "charts",
        },
        "kagent release evidence",
    )
    if root["schemaVersion"] != SCHEMA_VERSION:
        fail("kagent release evidence must use schemaVersion 3")
    if root["channel"] != "preview" or root["tag"] != f"v{RELEASE_VERSION}":
        fail("kagent release evidence must identify the reviewed .kap.5 preview")
    if root["source_repository"] != SOURCE_REPOSITORY or root["source_commit"] != SOURCE_COMMIT:
        fail("kagent release evidence must identify the reviewed repository and source commit")

    chart_source = _exact_object(
        root["chart_source"],
        {"path", "tree", "skills_init_removal_commit"},
        "kagent release evidence chart_source",
    )
    if chart_source["path"] != "helm/kagent":
        fail("kagent release evidence chart_source.path must be helm/kagent")
    if not re.fullmatch(r"[0-9a-f]{40}", str(chart_source["tree"])):
        fail("kagent release evidence chart_source.tree must be a Git tree SHA")
    if chart_source["skills_init_removal_commit"] != "059c01b68584dea113ccdf80f2e356c2d051e02a":
        fail("kagent release evidence must retain the reviewed skills-init removal commit")

    image_refs = _exact_object(root["image_refs"], set(IMAGE_REPOSITORIES), "kagent release evidence image_refs")
    for name, repository in IMAGE_REPOSITORIES.items():
        if not re.fullmatch(
            rf"{re.escape(PRIVATE_REGISTRY)}/{repository}@sha256:[0-9a-f]{{64}}",
            str(image_refs[name]),
        ):
            fail(f"kagent release evidence image_refs.{name} is not the reviewed private GAR reference")

    runtime_images = _exact_object(
        root["runtime_images"], set(RUNTIME_REPOSITORIES), "kagent release evidence runtime_images"
    )
    for name, repository in RUNTIME_REPOSITORIES.items():
        if not re.fullmatch(
            rf"{re.escape(PRIVATE_REGISTRY)}/{repository}@sha256:[0-9a-f]{{64}}",
            str(runtime_images[name]),
        ):
            fail(f"kagent release evidence runtime_images.{name} is not the reviewed private GAR reference")

    charts = _exact_object(root["charts"], set(CHART_REPOSITORIES), "kagent release evidence charts")
    for name, repository in CHART_REPOSITORIES.items():
        chart = _exact_object(charts[name], {"ref", "version"}, f"kagent release evidence charts.{name}")
        if chart["version"] != RELEASE_VERSION:
            fail(f"kagent release evidence charts.{name}.version must be the reviewed .kap.5 version")
        if not re.fullmatch(
            rf"oci://{re.escape(PRIVATE_REGISTRY)}/helm/{repository}@sha256:[0-9a-f]{{64}}",
            str(chart["ref"]),
        ):
            fail(f"kagent release evidence charts.{name}.ref is not the reviewed private GAR reference")

    platform_digests = _exact_object(
        root["platform_image_digests"], PLATFORM_COMPONENTS, "kagent release evidence platform_image_digests"
    )
    for component, platforms_value in platform_digests.items():
        platforms = _exact_object(
            platforms_value,
            {"linux_amd64", "linux_arm64"},
            f"kagent release evidence platform_image_digests.{component}",
        )
        for architecture, digest in platforms.items():
            _digest(digest, f"kagent release evidence platform_image_digests.{component}.{architecture}")

    toolchain = _exact_object(root["build_toolchain"], {"buildkit"}, "kagent release evidence build_toolchain")
    if not re.fullmatch(r"[^\s@]+@sha256:[0-9a-f]{64}", str(toolchain["buildkit"])):
        fail("kagent release evidence build_toolchain.buildkit must be digest-pinned")

    scans = _exact_object(
        root["security_scans"],
        {"schema", "scanner", "decision", "policy", "evidenceManifestSha256", "releaseLock", "targets"},
        "kagent release evidence security_scans",
    )
    if scans["schema"] != "yourown.chat/kagent-platform-scan-evidence/v1":
        fail("kagent release evidence security scan schema is not reviewed")
    if scans["scanner"] != "Google Artifact Analysis On-Demand Scanning" or scans["decision"] != "pass":
        fail("kagent release evidence security scans must record the reviewed passing scanner")
    policy = _exact_object(
        scans["policy"], {"id", "evaluatorSha256", "blockedEffectiveSeverities"}, "security scan policy"
    )
    if policy["id"] != "kagent-istio-pseudoversion-google-scanner-v1":
        fail("kagent release evidence security scan policy is not reviewed")
    evaluator = _sha256(policy["evaluatorSha256"], "security scan evaluatorSha256")
    if evaluator != SCAN_POLICY_EVALUATOR_SHA256:
        fail("kagent release evidence security scan evaluator is not the reviewed policy implementation")
    if policy["blockedEffectiveSeverities"] != ["HIGH", "CRITICAL"]:
        fail("kagent release evidence must block HIGH and CRITICAL findings")
    _sha256(scans["evidenceManifestSha256"], "security scan evidenceManifestSha256")
    release_lock = _exact_object(scans["releaseLock"], {"uri", "sha256"}, "security scan releaseLock")
    if not re.fullmatch(
        r"gs://yourown-chat-kagent-preview-evidence-europe-west3/"
        r"kagent/0\.0\.0-external-slot\.kap\.5/release\.lock#[1-9][0-9]*",
        str(release_lock["uri"]),
    ):
        fail("kagent release evidence release lock URI is not the immutable .kap.5 lock")
    _sha256(release_lock["sha256"], "security scan releaseLock.sha256")

    targets = _exact_object(scans["targets"], TARGETS, "kagent release evidence security scan targets")
    target_keys = {
        "component",
        "os",
        "architecture",
        "imageReference",
        "scanId",
        "decision",
        "evaluatorSha256",
        "highCriticalFindingCount",
        "suppressedHighCriticalFindingCount",
        "blockingHighCriticalFindingCount",
        "evidence",
    }
    for key, target_value in targets.items():
        target = _exact_object(target_value, target_keys, f"security scan target {key}")
        component = str(target["component"])
        architecture = str(target["architecture"])
        if key != f"{component}-linux-{architecture}" or component not in PLATFORM_COMPONENTS:
            fail(f"security scan target {key} identity is inconsistent")
        if target["os"] != "linux" or architecture not in {"amd64", "arm64"}:
            fail(f"security scan target {key} platform is not reviewed")
        image_reference = str(target["imageReference"])
        if not re.fullmatch(
            rf"{re.escape(STAGING_REGISTRY)}/{re.escape(component)}@sha256:[0-9a-f]{{64}}",
            image_reference,
        ):
            fail(f"security scan target {key} imageReference is invalid")
        platform_digest = platform_digests[component][f"linux_{architecture}"]
        if image_reference.rsplit("@", 1)[1] != platform_digest:
            fail(f"security scan target {key} image digest does not match platform_image_digests")
        if not isinstance(target["scanId"], str) or not SCAN_ID.fullmatch(target["scanId"]):
            fail(f"security scan target {key} scanId is invalid")
        if target["decision"] != "pass" or target["evaluatorSha256"] != evaluator:
            fail(f"security scan target {key} did not pass the reviewed evaluator")
        high = _positive_count(target["highCriticalFindingCount"], f"security scan target {key} high count")
        suppressed = _positive_count(
            target["suppressedHighCriticalFindingCount"], f"security scan target {key} suppressed count"
        )
        blocking = _positive_count(
            target["blockingHighCriticalFindingCount"], f"security scan target {key} blocking count"
        )
        if blocking != 0 or high != suppressed + blocking:
            fail(f"security scan target {key} contains blocking findings")
        evidence = _exact_object(
            target["evidence"],
            {"scanIdSha256", "vulnerabilitiesSha256", "severitiesSha256", "policyDecisionSha256"},
            f"security scan target {key} evidence",
        )
        for evidence_name, evidence_sha in evidence.items():
            _sha256(evidence_sha, f"security scan target {key} evidence.{evidence_name}")

    return root, hashlib.sha256(manifest_json.encode("utf-8")).hexdigest()


def expected_artifact(manifest: dict, digest: str) -> dict:
    """Project producer evidence into the exact app-gcp artifact contract."""

    return {
        "source_repository": manifest["source_repository"],
        "source_commit": manifest["source_commit"],
        "artifact_manifest_sha256": digest,
        "artifact_schema_version": str(manifest["schemaVersion"]),
        "artifact_manifest_path": "",
        "charts": manifest["charts"],
        "image_refs": manifest["image_refs"],
        "runtime_images": manifest["runtime_images"],
    }


def expected_helm_set_values(manifest: dict) -> dict[str, str]:
    """Project evidence image refs into the only accepted chart overrides."""

    values: dict[str, str] = {}
    for image_name, path in (("controller", "controller.image"), ("ui", "ui.image")):
        repository_ref, digest = manifest["image_refs"][image_name].split("@", 1)
        registry, repository = repository_ref.rsplit("/", 1)
        values[f"{path}.registry"] = registry
        values[f"{path}.repository"] = repository
        values[f"{path}.tag"] = f"{RELEASE_VERSION}@{digest}"
    return values


def validate_binding(binding: object, artifact: dict, helm_set_values: object) -> tuple[dict, str]:
    """Bind every consumer field to exact bytes at a generation-qualified URI."""

    binding_object = _exact_object(binding, {"uri", "manifest_json"}, "kagent_release_evidence")
    uri = binding_object["uri"]
    if not isinstance(uri, str) or not EVIDENCE_URI.fullmatch(uri):
        fail("kagent release evidence URI must be the exact generation-qualified private .kap.5 object")
    manifest, digest = parse_manifest(binding_object["manifest_json"])
    expected = expected_artifact(manifest, digest)
    actual = {
        "source_repository": artifact.get("source_repository"),
        "source_commit": artifact.get("source_commit"),
        "artifact_manifest_sha256": artifact.get("artifact_manifest_sha256"),
        "artifact_schema_version": artifact.get("artifact_schema_version"),
        "artifact_manifest_path": artifact.get("artifact_manifest_path", ""),
        "charts": artifact.get("charts"),
        "image_refs": artifact.get("image_refs"),
        "runtime_images": artifact.get("runtime_images", {}),
    }
    if actual != expected:
        fail("kagent artifact fields must exactly match the checksum-bound schema-3 release evidence")
    expected_values = expected_helm_set_values(manifest)
    if helm_set_values != expected_values:
        fail("helm_set_values.kagent must exactly match the checksum-bound schema-3 release evidence")
    return manifest, digest
