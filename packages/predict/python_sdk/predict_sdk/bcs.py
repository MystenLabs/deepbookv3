from __future__ import annotations

# Minimal hand-rolled BCS encoder for Sui programmable transactions. Covers exactly
# the TransactionData schema the SDK builds (pure/object inputs, MoveCall + coin
# commands, gas data) — not a general BCS library. Correctness is validated against
# the fullnode's dryRun, which rejects malformed bytes.

_B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


# === primitives ===

def uleb(n: int) -> bytes:
    out = bytearray()
    while True:
        byte = n & 0x7F
        n >>= 7
        out.append(byte | (0x80 if n else 0))
        if not n:
            return bytes(out)


def u8(n: int) -> bytes:
    return n.to_bytes(1, "little")


def u16(n: int) -> bytes:
    return n.to_bytes(2, "little")


def u64(n: int) -> bytes:
    return n.to_bytes(8, "little")


def u128(n: int) -> bytes:
    return n.to_bytes(16, "little")


def u256(n: int) -> bytes:
    return n.to_bytes(32, "little")


def boolean(b: bool) -> bytes:
    return b"\x01" if b else b"\x00"


def length_prefixed(b: bytes) -> bytes:
    return uleb(len(b)) + b


def string(s: str) -> bytes:
    return length_prefixed(s.encode("utf-8"))


def sequence(items: list[bytes]) -> bytes:
    return uleb(len(items)) + b"".join(items)


def option(inner: bytes | None) -> bytes:
    return b"\x00" if inner is None else b"\x01" + inner


def normalize_address(addr: str) -> bytes:
    h = addr[2:] if addr.startswith("0x") else addr
    if len(h) > 64:
        raise ValueError(f"address too long: {addr}")
    return bytes.fromhex(h.rjust(64, "0"))


def base58_decode(s: str) -> bytes:
    num = 0
    for ch in s:
        num = num * 58 + _B58.index(ch)
    body = num.to_bytes((num.bit_length() + 7) // 8, "big") if num else b""
    pad = len(s) - len(s.lstrip("1"))
    return b"\x00" * pad + body


# === type tags ===

_PRIMITIVE_TAGS = {
    "bool": b"\x00", "u8": b"\x01", "u64": b"\x02", "u128": b"\x03",
    "address": b"\x04", "signer": b"\x05", "u16": b"\x08", "u32": b"\x09", "u256": b"\x0a",
}


def type_tag(type_str: str) -> bytes:
    type_str = type_str.strip()
    if type_str in _PRIMITIVE_TAGS:
        return _PRIMITIVE_TAGS[type_str]
    if type_str.startswith("vector<") and type_str.endswith(">"):
        return b"\x06" + type_tag(type_str[7:-1])
    # struct tag: 0xADDR::module::Name<T0, T1, ...>
    addr_mod_name, params = _split_struct(type_str)
    addr, module, name = addr_mod_name.split("::", 2)
    return (
        b"\x07"
        + normalize_address(addr)
        + string(module)
        + string(name)
        + sequence([type_tag(p) for p in params])
    )


def _split_struct(type_str: str) -> tuple[str, list[str]]:
    depth = 0
    for i, ch in enumerate(type_str):
        if ch == "<" and depth == 0:
            head = type_str[:i]
            params = _split_type_params(type_str[i + 1:-1])
            return head, params
        if ch == "<":
            depth += 1
        elif ch == ">":
            depth -= 1
    return type_str, []


def _split_type_params(inner: str) -> list[str]:
    params, depth, start = [], 0, 0
    for i, ch in enumerate(inner):
        if ch == "<":
            depth += 1
        elif ch == ">":
            depth -= 1
        elif ch == "," and depth == 0:
            params.append(inner[start:i].strip())
            start = i + 1
    if inner.strip():
        params.append(inner[start:].strip())
    return params


# === arguments ===

def arg_gas_coin() -> bytes:
    return b"\x00"


def arg_input(index: int) -> bytes:
    return b"\x01" + u16(index)


def arg_result(index: int) -> bytes:
    return b"\x02" + u16(index)


def arg_nested_result(index: int, sub: int) -> bytes:
    return b"\x03" + u16(index) + u16(sub)


# === programmable transaction builder ===

class Ptb:
    """Accumulates deduped inputs + commands, then serializes the two vectors."""

    def __init__(self) -> None:
        self._inputs: list[dict] = []
        self._keys: dict[tuple, int] = {}
        self._commands: list[bytes] = []

    # -- inputs --
    def pure(self, raw: bytes) -> bytes:
        return self._intern(("pure", raw), {"kind": "pure", "raw": raw})

    def pure_u64(self, value: int) -> bytes:
        return self.pure(u64(value))

    def pure_u256(self, value: int) -> bytes:
        return self.pure(u256(value))

    def pure_address(self, addr: str) -> bytes:
        return self.pure(normalize_address(addr))

    def pure_bool(self, value: bool) -> bytes:
        return self.pure(boolean(value))

    def shared_object(self, object_id: str, initial_shared_version: int, mutable: bool) -> bytes:
        key = ("obj", normalize_address(object_id))
        arg = self._intern(
            key,
            {"kind": "shared", "id": object_id, "isv": initial_shared_version, "mutable": mutable},
        )
        if mutable:  # upgrade to mutable if any use needs it
            self._inputs[self._keys[key]]["mutable"] = True
        return arg

    def owned_object(self, object_id: str, version: int, digest: str) -> bytes:
        return self._intern(
            ("obj", normalize_address(object_id)),
            {"kind": "owned", "id": object_id, "version": version, "digest": digest},
        )

    def _intern(self, key: tuple, descriptor: dict) -> bytes:
        if key not in self._keys:
            self._keys[key] = len(self._inputs)
            self._inputs.append(descriptor)
        return arg_input(self._keys[key])

    # -- commands --
    def move_call(
        self,
        package: str,
        module: str,
        function: str,
        type_arguments: list[str],
        arguments: list[bytes],
    ) -> int:
        body = (
            normalize_address(package)
            + string(module)
            + string(function)
            + sequence([type_tag(t) for t in type_arguments])
            + sequence(arguments)
        )
        return self._command(b"\x00" + body)

    def transfer_objects(self, objects: list[bytes], recipient: bytes) -> int:
        return self._command(b"\x01" + sequence(objects) + recipient)

    def split_coins(self, coin: bytes, amounts: list[bytes]) -> int:
        return self._command(b"\x02" + coin + sequence(amounts))

    def merge_coins(self, coin: bytes, coins: list[bytes]) -> int:
        return self._command(b"\x03" + coin + sequence(coins))

    def _command(self, body: bytes) -> int:
        self._commands.append(body)
        return len(self._commands) - 1

    # -- finalize --
    def _serialize_input(self, descriptor: dict) -> bytes:
        kind = descriptor["kind"]
        if kind == "pure":
            return b"\x00" + length_prefixed(descriptor["raw"])  # CallArg::Pure
        if kind == "shared":
            obj = (
                b"\x01"  # ObjectArg::SharedObject
                + normalize_address(descriptor["id"])
                + u64(descriptor["isv"])
                + boolean(descriptor["mutable"])
            )
            return b"\x01" + obj  # CallArg::Object
        # owned
        obj = (
            b"\x00"  # ObjectArg::ImmOrOwnedObject
            + normalize_address(descriptor["id"])
            + u64(descriptor["version"])
            + length_prefixed(base58_decode(descriptor["digest"]))
        )
        return b"\x01" + obj

    def serialize(self) -> bytes:
        inputs = sequence([self._serialize_input(d) for d in self._inputs])
        commands = sequence(self._commands)
        return inputs + commands


def build_transaction_data(
    sender: str,
    ptb: Ptb,
    gas_payment: list[tuple[str, int, str]],  # (object_id, version, digest)
    gas_owner: str,
    gas_price: int,
    gas_budget: int,
    expiration_epoch: int | None = None,
) -> bytes:
    kind = b"\x00" + ptb.serialize()  # TransactionKind::ProgrammableTransaction
    payment = sequence(
        [normalize_address(oid) + u64(version) + length_prefixed(base58_decode(digest))
         for oid, version, digest in gas_payment]
    )
    gas_data = payment + normalize_address(gas_owner) + u64(gas_price) + u64(gas_budget)
    expiration = b"\x00" if expiration_epoch is None else b"\x01" + u64(expiration_epoch)
    return b"\x00" + kind + normalize_address(sender) + gas_data + expiration  # TransactionData::V1
