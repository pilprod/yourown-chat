#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
import time


def run(command):
    return subprocess.check_output(command, text=True).strip()


def image_digest(image_ref):
    return run([
        "gcloud", "artifacts", "docker", "images", "describe", image_ref,
        "--format=value(image_summary.digest)",
    ])


def pod_items(namespace):
    output = run(["kubectl", "-n", namespace, "get", "pods", "-o", "json"])
    return json.loads(output).get("items", [])


def check_image(namespace, label, image_ref, expected_digest):
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
            if expected_digest in image_id and ready:
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
        digest = image_digest(image_ref)
        if not digest:
            print(f"Could not resolve digest for {label}: {image_ref}", file=sys.stderr)
            return 1
        expected.append((label, image_ref, digest))

    deadline = time.time() + args.timeout
    last_errors = []
    while True:
        last_errors = []
        for label, image_ref, digest in expected:
            matches, mismatches = check_image(args.namespace, label, image_ref, digest)
            if not matches or mismatches:
                details = [f"{label} expected {image_ref}@{digest}"]
                if not matches:
                    details.append("no ready pod is running this digest")
                details.extend(f"mismatch: {item}" for item in mismatches)
                last_errors.extend(details)

        if not last_errors:
            for label, image_ref, digest in expected:
                print(f"{label} running expected digest: {image_ref}@{digest}")
            return 0

        if time.time() >= deadline:
            print("Running image digest verification failed", file=sys.stderr)
            for error in last_errors:
                print(f"- {error}", file=sys.stderr)
            return 1

        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())