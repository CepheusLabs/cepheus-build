"""Upload an Android App Bundle to Google Play."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Upload an AAB to Google Play.")
    parser.add_argument("--aab", required=True, help="Path to the .aab file.")
    parser.add_argument("--package", required=True, dest="package_name", help="Android package name.")
    parser.add_argument("--track", default="internal", help="Play track: internal, alpha, beta, production.")
    parser.add_argument("--service-account", required=True, help="Google service account JSON path.")
    parser.add_argument("--status", default="completed", help="Release status: completed, draft, halted.")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    aab = Path(args.aab).expanduser().resolve()
    service_account = Path(args.service_account).expanduser().resolve()
    if not aab.exists():
        print(f"error: AAB not found: {aab}", file=sys.stderr)
        return 2
    if not service_account.exists():
        print(f"error: service account JSON not found: {service_account}", file=sys.stderr)
        return 2

    try:
        from google.oauth2 import service_account as google_service_account
        from googleapiclient.discovery import build as build_service
        from googleapiclient.http import MediaFileUpload
    except ImportError:
        print("error: install google-api-python-client and google-auth", file=sys.stderr)
        return 2

    credentials = google_service_account.Credentials.from_service_account_file(
        str(service_account),
        scopes=["https://www.googleapis.com/auth/androidpublisher"],
    )
    service = build_service("androidpublisher", "v3", credentials=credentials)

    print(f"Creating Google Play edit for {args.package_name}...")
    edit = service.edits().insert(body={}, packageName=args.package_name).execute()
    edit_id = edit["id"]

    try:
        print(f"Uploading {aab}...")
        media = MediaFileUpload(str(aab), mimetype="application/octet-stream", resumable=True)
        bundle = (
            service.edits()
            .bundles()
            .upload(packageName=args.package_name, editId=edit_id, media_body=media)
            .execute()
        )
        version_code = str(bundle["versionCode"])

        print(f"Assigning version {version_code} to {args.track}...")
        (
            service.edits()
            .tracks()
            .update(
                packageName=args.package_name,
                editId=edit_id,
                track=args.track,
                body={
                    "track": args.track,
                    "releases": [
                        {
                            "versionCodes": [version_code],
                            "status": args.status,
                        }
                    ],
                },
            )
            .execute()
        )

        print("Committing edit...")
        service.edits().commit(packageName=args.package_name, editId=edit_id).execute()
        print(f"Uploaded {args.package_name} {version_code} to {args.track}.")
        return 0
    except Exception:
        try:
            service.edits().delete(packageName=args.package_name, editId=edit_id).execute()
        except Exception:
            pass
        raise


if __name__ == "__main__":
    raise SystemExit(main())
