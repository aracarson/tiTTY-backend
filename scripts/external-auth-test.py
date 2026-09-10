#!/usr/bin/env python3
"""Exercise the public GraphQL authentication flow as an external client."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import secrets
import sys
import urllib.error
import urllib.request
from typing import Any

try:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
except ImportError as error:
    raise SystemExit(
        "Missing dependency: install it with "
        "python -m pip install cryptography"
    ) from error


DEFAULT_ENDPOINT = "https://iden.titty.app/graphql"


def graphql(
    endpoint: str,
    query: str,
    variables: dict[str, Any] | None = None,
    token: str | None = None,
) -> dict[str, Any]:
    payload = {"query": query}
    if variables is not None:
        payload["variables"] = variables

    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    request = urllib.request.Request(
        endpoint,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {error.code}: {body}") from error
    except urllib.error.URLError as error:
        raise RuntimeError(f"Request failed: {error.reason}") from error

    if result.get("errors"):
        raise RuntimeError(json.dumps(result["errors"], indent=2))
    return result["data"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", default=DEFAULT_ENDPOINT)
    parser.add_argument(
        "--username",
        help="Use this identiTTY; otherwise generate a fresh disposable username.",
    )
    args = parser.parse_args()

    private_key = Ed25519PrivateKey.generate()
    public_key = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    account_id = "acct_" + hashlib.sha256(public_key).hexdigest()
    username = args.username or f"curltest_{secrets.token_hex(5)}"
    public_key_b64 = base64.b64encode(public_key).decode("ascii")

    register_query = """
        mutation Register($input: RegisterAccountInput!) {
          registerAccount(input: $input) {
            accountID
            identiTTY
            publicKey
          }
        }
    """
    registered = graphql(
        args.endpoint,
        register_query,
        {
            "input": {
                "identiTTY": username,
                "accountID": account_id,
                "publicKey": public_key_b64,
            }
        },
    )["registerAccount"]
    print(f"Registered identiTTY: {registered['identiTTY']}")
    print(f"Account ID: {registered['accountID']}")

    challenge_query = """
        mutation Challenge($accountID: String!) {
          requestChallenge(accountID: $accountID) {
            challengeID
            challenge
            expiresAt
          }
        }
    """
    challenge = graphql(
        args.endpoint,
        challenge_query,
        {"accountID": account_id},
    )["requestChallenge"]

    challenge_bytes = base64.b64decode(challenge["challenge"], validate=True)
    signature = private_key.sign(challenge_bytes)
    signature_b64 = base64.b64encode(signature).decode("ascii")

    authenticate_query = """
        mutation Authenticate($input: AuthenticateInput!) {
          authenticate(input: $input) {
            token
            expiresAt
          }
        }
    """
    session = graphql(
        args.endpoint,
        authenticate_query,
        {
            "input": {
                "accountID": account_id,
                "challengeID": challenge["challengeID"],
                "signature": signature_b64,
            }
        },
    )["authenticate"]
    print(f"JWT expires at: {session['expiresAt']}")

    blocked_query = """
        query BlockedIdentities {
          blockedIdentities {
            accountID
            identiTTY
            blockedAt
          }
        }
    """
    blocked = graphql(args.endpoint, blocked_query, token=session["token"])
    print("blockedIdentities response:")
    print(json.dumps(blocked, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
