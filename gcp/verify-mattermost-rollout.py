#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
import time


def run(command):
    return subprocess.check_output(command, text=True).strip()


def kubectl_json(namespace, resource):
    return json.loads(run(["kubectl", "-n", namespace, "get", resource, "-o", "json"]))


def parse_instance(value):
    if "=" not in value:
        raise argparse.ArgumentTypeError("expected MATTERMOST_NAME=IMAGE_REF")
    name, image_ref = value.split("=", 1)
    if ":" not in image_ref:
        raise argparse.ArgumentTypeError("image ref must include a tag")
    return name, image_ref, image_ref.rsplit(":", 1)[1]


def deployment_images(namespace, name):
    try:
        deployment = kubectl_json(namespace, f"deployment/{name}")
    except subprocess.CalledProcessError:
        return []
    return [
        container.get("image", "")
        for container in deployment.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
    ]


def check_instance(namespace, name, image_ref, image_tag):
    errors = []
    mattermost = kubectl_json(namespace, f"mattermost/{name}")
    spec_version = mattermost.get("spec", {}).get("version", "")
    status_version = mattermost.get("status", {}).get("version", "")
    state = mattermost.get("status", {}).get("state", "")
    images = deployment_images(namespace, name)

    if spec_version != image_tag:
        errors.append(f"{name} spec.version is {spec_version or '<empty>'}, expected {image_tag}")
    if status_version != image_tag:
        errors.append(f"{name} status.version is {status_version or '<empty>'}, expected {image_tag} (state={state or '<empty>'})")
    if image_ref not in images:
        rendered_images = ", ".join(images) if images else "<deployment missing or no images>"
        errors.append(f"{name} deployment image is {rendered_images}, expected {image_ref}")

    return errors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--namespace", default="mattermost")
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--interval", type=int, default=10)
    parser.add_argument("--instance", action="append", type=parse_instance, required=True)
    args = parser.parse_args()

    deadline = time.time() + args.timeout
    last_errors = []
    while True:
        last_errors = []
        for name, image_ref, image_tag in args.instance:
            last_errors.extend(check_instance(args.namespace, name, image_ref, image_tag))

        if not last_errors:
            for name, image_ref, _ in args.instance:
                print(f"{name} operator rollout matches expected image: {image_ref}")
            return 0

        if time.time() >= deadline:
            print("Mattermost operator rollout did not reach expected versions", file=sys.stderr)
            for error in last_errors:
                print(f"- {error}", file=sys.stderr)
            return 1

        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())