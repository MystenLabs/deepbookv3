from __future__ import annotations

_B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


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


def boolean(value: bool) -> bytes:
    return b"\x01" if value else b"\x00"


def length_prefixed(raw: bytes) -> bytes:
    return uleb(len(raw)) + raw


def string(value: str) -> bytes:
    return length_prefixed(value.encode("utf-8"))


def sequence(items: list[bytes]) -> bytes:
    return uleb(len(items)) + b"".join(items)


def normalize_address(addr: str) -> bytes:
    h = addr[2:] if addr.startswith("0x") else addr
    if len(h) > 64:
        raise ValueError(f"address too long: {addr}")
    return bytes.fromhex(h.rjust(64, "0"))


def base58_decode(value: str) -> bytes:
    num = 0
    for ch in value:
        num = num * 58 + _B58.index(ch)
    body = num.to_bytes((num.bit_length() + 7) // 8, "big") if num else b""
    pad = len(value) - len(value.lstrip("1"))
    return b"\x00" * pad + body


_PRIMITIVE_TAGS = {
    "bool": b"\x00",
    "u8": b"\x01",
    "u64": b"\x02",
    "u128": b"\x03",
    "address": b"\x04",
    "signer": b"\x05",
    "u16": b"\x08",
    "u32": b"\x09",
    "u256": b"\x0a",
}


def type_tag(type_str: str) -> bytes:
    type_str = type_str.strip()
    if type_str in _PRIMITIVE_TAGS:
        return _PRIMITIVE_TAGS[type_str]
    if type_str.startswith("vector<") and type_str.endswith(">"):
        return b"\x06" + type_tag(type_str[7:-1])
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
            return type_str[:i], _split_type_params(type_str[i + 1:-1])
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


def arg_input(index: int) -> bytes:
    return b"\x01" + u16(index)


class Ptb:
    def __init__(self) -> None:
        self._inputs: list[dict] = []
        self._keys: dict[tuple, int] = {}
        self._commands: list[bytes] = []

    def pure(self, raw: bytes) -> bytes:
        return self._intern(("pure", raw), {"kind": "pure", "raw": raw})

    def pure_u64(self, value: int) -> bytes:
        return self.pure(u64(value))

    def shared_object(
        self,
        object_id: str,
        initial_shared_version: int,
        mutable: bool,
    ) -> bytes:
        key = ("obj", normalize_address(object_id))
        arg = self._intern(
            key,
            {
                "kind": "shared",
                "id": object_id,
                "isv": initial_shared_version,
                "mutable": mutable,
            },
        )
        if mutable:
            self._inputs[self._keys[key]]["mutable"] = True
        return arg

    def _intern(self, key: tuple, descriptor: dict) -> bytes:
        if key not in self._keys:
            self._keys[key] = len(self._inputs)
            self._inputs.append(descriptor)
        return arg_input(self._keys[key])

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
        self._commands.append(b"\x00" + body)
        return len(self._commands) - 1

    def _serialize_input(self, descriptor: dict) -> bytes:
        if descriptor["kind"] == "pure":
            return b"\x00" + length_prefixed(descriptor["raw"])
        obj = (
            b"\x01"
            + normalize_address(descriptor["id"])
            + u64(descriptor["isv"])
            + boolean(descriptor["mutable"])
        )
        return b"\x01" + obj

    def serialize(self) -> bytes:
        return (
            sequence([self._serialize_input(d) for d in self._inputs])
            + sequence(self._commands)
        )


def build_transaction_kind(ptb: Ptb) -> bytes:
    return b"\x00" + ptb.serialize()
