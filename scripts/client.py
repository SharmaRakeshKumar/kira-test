#!/usr/bin/env python3
"""
Programmatic API client for external scripts/agents.

Usage:
  # Submit a transfer
  python scripts/client.py transfer --amount 100 --vendor vendorA --txhash 0x123abc

  # Deploy a new vendor via IaC (requires terraform)
  python scripts/client.py deploy-vendor --name vendorC --image vendorC:latest
"""
import argparse
import json
import subprocess
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


def deploy_vendor(vendor_name: str, image: str, tf_dir: str):
    """
    Update Terraform vars and apply to register a new vendor.
    In practice, this would also update main.py via a config map or plugin registry.
    """
    print(f"Deploying vendor '{vendor_name}' with image '{image}'...")
    result = subprocess.run(
        [
            "terraform", "apply", "-auto-approve",
            f"-var=new_vendor_name={vendor_name}",
            f"-var=new_vendor_image={image}",
        ],
        cwd=tf_dir,
        capture_output=True,
        text=True,
    )
    print(result.stdout)
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        sys.exit(1)
    print(f"Vendor '{vendor_name}' deployed successfully.")


def main():
    parser = argparse.ArgumentParser(description="Payments API client")
    parser.add_argument("--base-url", default="http://localhost:8000")
    parser.add_argument("--tf-dir", default="infra/terraform")
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
        deploy_vendor(args.name, args.image, args.tf_dir)


if __name__ == "__main__":
    main()
