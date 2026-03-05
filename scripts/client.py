#!/usr/bin/env python3
"""
Programmatic API client for external scripts/agents.

Usage:
  # Submit a transfer
  python scripts/client.py transfer --amount 100 --vendor vendorA --txhash 0x123abc

  # Trigger a CI/CD deployment via GitHub Actions workflow dispatch
  # Requires: GITHUB_TOKEN env var with repo workflow permissions
  # Requires: GITHUB_REPO env var in "owner/repo" format
  python scripts/client.py deploy-vendor --name vendorC --image vendorC:latest
"""
import argparse
import json
import os
import sys
import httpx


def do_transfer(base_url: str, amount: float, vendor: str, txhash: str):
    resp = httpx.post(
        f"{base_url}/transfer",
        json={"amount": amount, "vendor": vendor, "txhash": txhash},
        timeout=30,
    )
    print(json.dumps(resp.json(), indent=2))
    resp.raise_for_status()


def deploy_vendor(vendor_name: str, image: str):
    """
    Trigger the CI/CD pipeline via GitHub Actions workflow dispatch.

    Requires environment variables:
      GITHUB_TOKEN — personal access token or fine-grained token with
                     Actions: write permission on the target repository
      GITHUB_REPO  — repository in "owner/repo" format
                     (e.g. "myorg/usdc-cop-api")
    """
    token = os.environ.get("GITHUB_TOKEN")
    repo = os.environ.get("GITHUB_REPO")
    if not token:
        print("ERROR: GITHUB_TOKEN environment variable is not set.", file=sys.stderr)
        sys.exit(1)
    if not repo:
        print("ERROR: GITHUB_REPO environment variable is not set (e.g. 'owner/repo').", file=sys.stderr)
        sys.exit(1)

    url = f"https://api.github.com/repos/{repo}/actions/workflows/ci-cd.yml/dispatches"
    payload = {
        "ref": "main",
        "inputs": {
            "reason": f"deploy-vendor: {vendor_name} image={image}",
        },
    }
    print(f"Triggering workflow dispatch for vendor '{vendor_name}' (image={image})...")
    resp = httpx.post(
        url,
        json=payload,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        timeout=30,
    )
    if resp.status_code == 204:
        print(f"Workflow dispatch accepted. Monitor progress at: https://github.com/{repo}/actions")
    else:
        print(f"ERROR: GitHub API returned {resp.status_code}: {resp.text}", file=sys.stderr)
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="Payments API client")
    parser.add_argument("--base-url", default="http://localhost:8000")
    sub = parser.add_subparsers(dest="command", required=True)

    t = sub.add_parser("transfer")
    t.add_argument("--amount", type=float, required=True)
    t.add_argument("--vendor", required=True)
    t.add_argument("--txhash", required=True)

    d = sub.add_parser("deploy-vendor")
    d.add_argument("--name", required=True)
    d.add_argument("--image", required=True)

    args = parser.parse_args()

    if args.command == "transfer":
        do_transfer(args.base_url, args.amount, args.vendor, args.txhash)
    elif args.command == "deploy-vendor":
        deploy_vendor(args.name, args.image)


if __name__ == "__main__":
    main()
