"""Upload an Android App Bundle to Google Play."""

from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Upload an AAB to Google Play.")
    parser.add_argument("--aab", required=True, help="Path to the .aab file.")
    parser.add_argument("--package", required=True, dest="package_name", help="Android package name.")
    parser.add_argument("--track", default="internal", help="Play track: internal, alpha, beta, production.")
    parser.add_argument("--service-account", required=True, help="Google service account JSON file path.")
    parser.add_argument("--status", default="completed", help="Release status: completed, draft, halted.")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=False,
        help="Validate inputs and print planned actions without making API calls.",
    )
    return parser


def _is_dry_run(args: argparse.Namespace) -> bool:
    """Return True if dry-run is requested via flag or CBUILD_DRY_RUN env var."""
    if args.dry_run:
        return True
    env_val = os.environ.get("CBUILD_DRY_RUN", "")
    return env_val.strip() not in ("", "0", "false", "no")


def _call_with_retry(fn, *, max_attempts: int = 3) -> object:
    """Execute *fn()* up to *max_attempts* times, retrying on transient errors.

    Retries on HTTP 5xx and 429 with exponential backoff (1s, 2s, 4s, …).
    Raises immediately on 4xx (except 429).
    Requires google libs to already be imported in the caller's scope.
    """
    from googleapiclient.errors import HttpError  # imported lazily; google libs must be present

    delay = 1
    last_exc: Exception | None = None
    for attempt in range(1, max_attempts + 1):
        try:
            return fn()
        except HttpError as exc:
            status = exc.resp.status if exc.resp is not None else 0
            retryable = status == 429 or status >= 500
            if not retryable or attempt == max_attempts:
                raise
            print(
                f"  transient error (HTTP {status}), retrying in {delay}s "
                f"(attempt {attempt}/{max_attempts})...",
                file=sys.stderr,
            )
            time.sleep(delay)
            delay *= 2
            last_exc = exc
    # Should not reach here, but satisfy type checker.
    raise last_exc  # type: ignore[misc]


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    aab = Path(args.aab).expanduser().resolve()
    dry_run = _is_dry_run(args)

    # --- item #29: reject JSON body passed as --service-account ---
    raw_sa = args.service_account.strip()
    if raw_sa.startswith("{"):
        print(
            "error: --service-account must be a file path, not JSON contents.\n"
            "       Create a file containing the service account JSON and pass its path.",
            file=sys.stderr,
        )
        return 2

    service_account = Path(args.service_account).expanduser().resolve()

    # --- input validation (always runs, even in dry-run) ---
    if not aab.exists():
        print(f"error: AAB not found: {aab}", file=sys.stderr)
        return 2
    if not service_account.exists():
        print(f"error: service account JSON not found: {service_account}", file=sys.stderr)
        return 2

    # --- item #26 / #7: dry-run path (no google imports, no network calls) ---
    if dry_run:
        print("[dry-run] Google Play upload — planned actions:")
        print(f"  Creating edit for package: {args.package_name}")
        print(f"  Uploading AAB: {aab}")
        print(f"  Assigning to track '{args.track}' with status '{args.status}'")
        print("  Committing edit")
        print("[dry-run] No API calls made.")
        return 0

    # --- real path: lazy google imports ---
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
    edit = _call_with_retry(
        lambda: service.edits().insert(body={}, packageName=args.package_name).execute()
    )

    # --- item #7: guard dict access ---
    edit_id = edit.get("id") if isinstance(edit, dict) else None  # type: ignore[union-attr]
    if not edit_id:
        print("error: unexpected response from edits.insert — 'id' missing", file=sys.stderr)
        return 1

    try:
        print(f"Uploading {aab}...")
        media = MediaFileUpload(str(aab), mimetype="application/octet-stream", resumable=True)
        bundle = _call_with_retry(
            lambda: service.edits()
            .bundles()
            .upload(packageName=args.package_name, editId=edit_id, media_body=media)
            .execute()
        )

        # --- item #7: guard dict access ---
        version_code = bundle.get("versionCode") if isinstance(bundle, dict) else None  # type: ignore[union-attr]
        if version_code is None:
            print("error: unexpected response from bundles.upload — 'versionCode' missing", file=sys.stderr)
            return 1
        version_code = str(version_code)

        print(f"Assigning version {version_code} to {args.track}...")
        _call_with_retry(
            lambda: service.edits()
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
        _call_with_retry(
            lambda: service.edits().commit(packageName=args.package_name, editId=edit_id).execute()
        )
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
