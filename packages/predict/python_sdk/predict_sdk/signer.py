from __future__ import annotations

import base64
import hashlib
import os
from dataclasses import dataclass

import nacl.signing

# Ed25519 transaction signer for Sui. Loads a bech32 `suiprivkey1…` key (the Sui
# CLI export format) from the environment or a .env file, derives the address, and
# signs transaction bytes with Sui's intent + blake2b scheme.
#
# This is the one module that needs PyNaCl; the CLI imports it only on the write path.

_BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
_ED25519_FLAG = 0x00
# Sui intent for a user transaction: scope=TransactionData(0), version=V0(0), app=Sui(0).
_INTENT = bytes([0, 0, 0])


@dataclass(frozen=True)
class Signer:
    private_key: bytes  # 32-byte Ed25519 seed
    public_key: bytes   # 32-byte Ed25519 public key
    address: str        # 0x-prefixed Sui address

    def sign_transaction(self, tx_bytes: bytes) -> str:
        """Return the base64 serialized signature for BCS-encoded TransactionData."""
        digest = hashlib.blake2b(_INTENT + tx_bytes, digest_size=32).digest()
        signature = nacl.signing.SigningKey(self.private_key).sign(digest).signature
        serialized = bytes([_ED25519_FLAG]) + signature + self.public_key
        return base64.b64encode(serialized).decode("ascii")


def signer_from_private_key(bech32_key: str) -> Signer:
    flag, seed = _decode_suiprivkey(bech32_key)
    if flag != _ED25519_FLAG:
        raise ValueError(f"unsupported key scheme flag {flag}; only Ed25519 (0x00) is supported")
    public_key = nacl.signing.SigningKey(seed).verify_key.encode()
    address = "0x" + hashlib.blake2b(bytes([flag]) + public_key, digest_size=32).hexdigest()
    return Signer(private_key=seed, public_key=public_key, address=address)


def load_signer(env_path: str | None = None, var: str = "SUI_PRIVATE_KEY") -> Signer:
    """Load the signer from `var` in the process env, else from a .env file."""
    key = os.environ.get(var) or _read_env_file(env_path).get(var)
    if not key:
        raise RuntimeError(f"{var} not found in environment or .env")
    return signer_from_private_key(key.strip())


def _read_env_file(env_path: str | None) -> dict[str, str]:
    candidates = [env_path] if env_path else [
        os.path.join(os.getcwd(), ".env"),
        os.path.join(os.path.dirname(os.path.dirname(__file__)), ".env"),
    ]
    for path in candidates:
        if path and os.path.exists(path):
            values: dict[str, str] = {}
            with open(path) as handle:
                for line in handle:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    name, _, value = line.partition("=")
                    values[name.strip()] = value.strip().strip('"').strip("'")
            return values
    return {}


def _decode_suiprivkey(key: str) -> tuple[int, bytes]:
    hrp, data = _bech32_decode(key)
    if hrp != "suiprivkey":
        raise ValueError(f"expected suiprivkey bech32, got hrp={hrp!r}")
    payload = _convertbits(data, 5, 8, pad=False)
    if len(payload) != 33:
        raise ValueError(f"expected 33-byte flag+seed payload, got {len(payload)}")
    return payload[0], bytes(payload[1:])


def _bech32_decode(value: str) -> tuple[str, list[int]]:
    value = value.strip()
    pos = value.rfind("1")
    if pos < 1 or pos + 7 > len(value):
        raise ValueError("invalid bech32 string")
    hrp = value[:pos]
    data = [_BECH32_CHARSET.find(c) for c in value[pos + 1:]]
    if any(d == -1 for d in data):
        raise ValueError("invalid bech32 character")
    if _bech32_polymod(_bech32_hrp_expand(hrp) + data) != 1:
        raise ValueError("invalid bech32 checksum")
    return hrp, data[:-6]


def _bech32_polymod(values: list[int]) -> int:
    generators = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]
    chk = 1
    for value in values:
        top = chk >> 25
        chk = ((chk & 0x1FFFFFF) << 5) ^ value
        for i in range(5):
            chk ^= generators[i] if ((top >> i) & 1) else 0
    return chk


def _bech32_hrp_expand(hrp: str) -> list[int]:
    return [ord(c) >> 5 for c in hrp] + [0] + [ord(c) & 31 for c in hrp]


def _convertbits(data: list[int], frm: int, to: int, pad: bool = True) -> list[int]:
    acc = bits = 0
    result: list[int] = []
    maxv = (1 << to) - 1
    for value in data:
        acc = (acc << frm) | value
        bits += frm
        while bits >= to:
            bits -= to
            result.append((acc >> bits) & maxv)
    if pad and bits:
        result.append((acc << (to - bits)) & maxv)
    return result
