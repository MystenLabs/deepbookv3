import base64
import hashlib
import unittest

import nacl.signing

from predict_sdk import bcs
from predict_sdk.signer import Signer, _convertbits


class BcsPrimitiveTests(unittest.TestCase):
    def test_uleb(self) -> None:
        self.assertEqual(bcs.uleb(0), b"\x00")
        self.assertEqual(bcs.uleb(1), b"\x01")
        self.assertEqual(bcs.uleb(127), b"\x7f")
        self.assertEqual(bcs.uleb(128), b"\x80\x01")
        self.assertEqual(bcs.uleb(300), b"\xac\x02")

    def test_scalars(self) -> None:
        self.assertEqual(bcs.u64(1), b"\x01" + b"\x00" * 7)
        self.assertEqual(bcs.boolean(True), b"\x01")
        self.assertEqual(bcs.string("sui"), b"\x03sui")

    def test_normalize_address(self) -> None:
        self.assertEqual(bcs.normalize_address("0x6"), b"\x00" * 31 + b"\x06")
        self.assertEqual(len(bcs.normalize_address("0x" + "ab" * 32)), 32)

    def test_type_tag_primitives(self) -> None:
        self.assertEqual(bcs.type_tag("bool"), b"\x00")
        self.assertEqual(bcs.type_tag("u64"), b"\x02")
        self.assertEqual(bcs.type_tag("address"), b"\x04")

    def test_type_tag_struct(self) -> None:
        # 0x2::sui::SUI -> Struct(7) + addr(0x2) + "sui" + "SUI" + no type params
        expected = b"\x07" + (b"\x00" * 31 + b"\x02") + b"\x03sui" + b"\x03SUI" + b"\x00"
        self.assertEqual(bcs.type_tag("0x2::sui::SUI"), expected)

    def test_type_tag_vector(self) -> None:
        self.assertEqual(bcs.type_tag("vector<u8>"), b"\x06\x01")


class SignerTests(unittest.TestCase):
    def _signer(self) -> Signer:
        seed = bytes(range(32))  # deterministic throwaway seed
        pub = nacl.signing.SigningKey(seed).verify_key.encode()
        address = "0x" + hashlib.blake2b(b"\x00" + pub, digest_size=32).hexdigest()
        return Signer(private_key=seed, public_key=pub, address=address)

    def test_address_shape(self) -> None:
        signer = self._signer()
        self.assertTrue(signer.address.startswith("0x"))
        self.assertEqual(len(signer.address), 66)

    def test_signature_is_valid_ed25519_over_intent_digest(self) -> None:
        signer = self._signer()
        tx_bytes = b"some transaction bytes"
        serialized = base64.b64decode(signer.sign_transaction(tx_bytes))
        # serialized = flag(1) || signature(64) || pubkey(32)
        self.assertEqual(serialized[0], 0x00)
        self.assertEqual(serialized[1:33].__len__(), 32)
        signature, pubkey = serialized[1:65], serialized[65:]
        self.assertEqual(pubkey, signer.public_key)
        # independently verify the Ed25519 signature is over blake2b(intent || tx)
        digest = hashlib.blake2b(bytes([0, 0, 0]) + tx_bytes, digest_size=32).digest()
        nacl.signing.VerifyKey(pubkey).verify(digest, signature)  # raises on mismatch

    def test_convertbits_roundtrip(self) -> None:
        data = list(b"\x00" + bytes(range(32)))
        five = _convertbits(data, 8, 5, pad=True)
        back = _convertbits(five, 5, 8, pad=False)
        self.assertEqual(bytes(back), bytes(data))


if __name__ == "__main__":
    unittest.main()
