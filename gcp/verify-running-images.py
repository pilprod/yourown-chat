#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
import time
import urllib.request


def run(command):
    return subprocess.check_output(command, text=True).strip()


def gcloud_image_digest(image_ref):
    return run([
        "gcloud", "artifacts", "docker", "images", "describe", image_ref,
        "--format=value(image_summary.digest)",
    ])


def registry_manifest_digests(image_ref):
    image_without_tag, tag = image_ref.rsplit(":", 1)
    host, image_path = image_without_tag.split("/", 1)
    token = run(["gcloud", "auth", "print-access-token"])
    request = urllib.request.Request(
        f"https://{host}/v2/{image_path}/manifests/{tag}",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": ", ".join([
                "application/vnd.oci.image.index.v1+json",
                "application/vnd.docker.distribution.manifest.list.v2+json",
                "application/vnd.oci.image.manifest.v1+json",
                "application/vnd.docker.distribution.manifest.v2+json",
            ]),
        },
    )

    with urllib.request.urlopen(request) as response:
        digest_header = response.headers.get("Docker-Content-Digest", "")
        manifest = json.loads(response.read().decode("utf-8"))

    digests = {digest_header} if digest_header else set()
    digests.update(
        item.get("digest", "")
        for item in manifest.get("manifests", [])
        if item.get("digest")
    )
    return {digest for digest in digests if digest}


def image_digests(image_ref):
    digests = registry_manifest_digests(image_ref)
    gcloud_digest = gcloud_image_digest(image_ref)
    if gcloud_digest:
        digests.add(gcloud_digest)
    return digests


def pod_items(namespace):
    output = run(["kubectl", "-n", namespace, "get", "pods", "-o", "json"])
    return json.loads(output).get("items", [])


def check_image(namespace, label, image_ref, expected_digests):
    matches = []
    mismatches = []

    for pod in pod_items(namespace):
        pod_name = pod.get("metadata", {}).get("name", "unknown-pod")
        spec_containers = {
            container.get("name"): container.get("image", "")
            for container in pod.get("spec", {}).get("containers", [])
        }
        statuses = {
            status.get("name"): status
            for status in pod.get("status", {}).get("containerStatuses", [])
        }

        for container_name, container_image in spec_containers.items():
            if container_image != image_ref:
                continue

            status = statuses.get(container_name, {})
            image_id = status.get("imageID", "")
            ready = status.get("ready", False)
            entry = f"{pod_name}/{container_name}: {image_id or 'missing imageID'}"
            if any(digest in image_id for digest in expected_digests) and ready:
                matches.append(entry)
            else:
                mismatches.append(entry)

    return matches, mismatches


def parse_image(value):
    if "=" not in value:
        raise argparse.ArgumentTypeError("expected LABEL=IMAGE_REF")
    label, image_ref = value.split("=", 1)
    if not label or not image_ref:
        raise argparse.ArgumentTypeError("expected LABEL=IMAGE_REF")
    return label, image_ref


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--namespace", default="mattermost")
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--interval", type=int, default=10)
    parser.add_argument("--image", action="append", type=parse_image, required=True)
    args = parser.parse_args()

    expected = []
    for label, image_ref in args.image:
        digests = image_digests(image_ref)
        if not digests:
            print(f"Could not resolve digest for {label}: {image_ref}", file=sys.stderr)
            return 1
        expected.append((label, image_ref, digests))

    deadline = time.time() + args.timeout
    last_errors = []
    while True:
        last_errors = []
        for label, image_ref, digests in expected:
            matches, mismatches = check_image(args.namespace, label, image_ref, digests)
            if not matches or mismatches:
                digest_text = ", ".join(sorted(digests))
                details = [f"{label} expected {image_ref} with digest in [{digest_text}]"]
                if not matches:
                    details.append("no ready pod is running this digest")
                details.extend(f"mismatch: {item}" for item in mismatches)
                last_errors.extend(details)

        if not last_errors:
            for label, image_ref, digests in expected:
                digest_text = ", ".join(sorted(digests))
                print(f"{label} running expected digest: {image_ref} [{digest_text}]")
            return 0

        if time.time() >= deadline:
            print("Running image digest verification failed", file=sys.stderr)
            for error in last_errors:
                print(f"- {error}", file=sys.stderr)
            return 1

        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())