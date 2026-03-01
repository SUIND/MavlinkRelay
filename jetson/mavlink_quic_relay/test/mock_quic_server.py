#!/usr/bin/env python3
import argparse
import asyncio
import logging
import struct
import sys

try:
    from aioquic.asyncio import QuicConnectionProtocol, serve
    from aioquic.quic.configuration import QuicConfiguration
    from aioquic.quic.events import QuicEvent, StreamDataReceived, StreamReset

    AIOQUIC_AVAILABLE = True
except ImportError:
    AIOQUIC_AVAILABLE = False
    print(
        "WARNING: aioquic not installed — mock server will not start", file=sys.stderr
    )

logger = logging.getLogger("mock_quic_server")

ALPN = "mavlink-quic-v1"
TEST_TOKEN = b"TESTTOKEN"

CBOR_AUTH_OK = bytes([0x62, 0x6F, 0x6B])
CBOR_AUTH_FAIL = bytes([0x62, 0x6E, 0x6F])

STREAM_CONTROL = 0
STREAM_PRIORITY = 4
STREAM_BULK = 8


def _decode_length_prefix(buf: bytearray):
    frames = []
    while len(buf) >= 2:
        length = struct.unpack_from("<H", buf, 0)[0]
        if length == 0:
            del buf[:2]
            continue
        if len(buf) < 2 + length:
            break
        payload = bytes(buf[2 : 2 + length])
        frames.append(payload)
        del buf[: 2 + length]
    return frames


def _encode_length_prefix(payload: bytes) -> bytes:
    return struct.pack("<H", len(payload)) + payload


class MockQuicServerProtocol(QuicConnectionProtocol):
    def __init__(self, *args, auth_fail: bool = False, **kwargs):
        super().__init__(*args, **kwargs)
        self._stream_buffers: dict = {}
        self._authenticated = False
        self._frames_received = 0
        self._auth_fail_mode = auth_fail

    def quic_event_received(self, event: QuicEvent) -> None:
        if isinstance(event, StreamDataReceived):
            sid = event.stream_id
            if sid not in self._stream_buffers:
                self._stream_buffers[sid] = bytearray()
            self._stream_buffers[sid].extend(event.data)
            frames = _decode_length_prefix(self._stream_buffers[sid])

            for frame in frames:
                if sid == STREAM_CONTROL:
                    self._handle_control(frame)
                elif sid in (STREAM_PRIORITY, STREAM_BULK):
                    self._handle_mavlink(sid, frame)

        elif isinstance(event, StreamReset):
            logger.warning("Stream %d reset by peer", event.stream_id)

    def _handle_control(self, frame: bytes) -> None:
        if not self._authenticated:
            if self._auth_fail_mode:
                logger.info("AUTH REJECTED — auth-fail mode enabled")
                print("AUTH_REJECTED", flush=True)
                self._quic.send_stream_data(
                    STREAM_CONTROL, _encode_length_prefix(CBOR_AUTH_FAIL)
                )
                self.transmit()
            elif TEST_TOKEN in frame:
                self._authenticated = True
                logger.info("AUTH OK — client authenticated")
                self._quic.send_stream_data(
                    STREAM_CONTROL, _encode_length_prefix(CBOR_AUTH_OK)
                )
                self.transmit()
            else:
                logger.warning("AUTH FAILED — token not found in frame")
        else:
            logger.debug("Control frame (post-auth): %s", frame.hex())

    def _handle_mavlink(self, stream_id: int, frame: bytes) -> None:
        self._frames_received += 1
        logger.info(
            "MAVLink frame on stream %d: %d bytes (total=%d)",
            stream_id,
            len(frame),
            self._frames_received,
        )
        print(
            f"FRAME_RECEIVED stream={stream_id} len={len(frame)} total={self._frames_received}",
            flush=True,
        )
        self._quic.send_stream_data(stream_id, _encode_length_prefix(frame))
        self.transmit()


def _build_quic_config(cert: str, key: str) -> "QuicConfiguration":
    config = QuicConfiguration(is_client=False, alpn_protocols=[ALPN])
    config.load_cert_chain(cert, key)
    return config


async def _run_server(
    host: str, port: int, cert: str, key: str, auth_fail: bool = False
) -> None:
    config = _build_quic_config(cert, key)
    logger.info("Mock QUIC server listening on %s:%d", host, port)

    def make_protocol(*args, **kwargs):
        return MockQuicServerProtocol(*args, auth_fail=auth_fail, **kwargs)

    async with await serve(
        host, port, configuration=config, create_protocol=make_protocol
    ):
        await asyncio.sleep(3600)


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )

    parser = argparse.ArgumentParser(
        description="Mock QUIC server for integration tests"
    )
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=15551)
    parser.add_argument("--cert", default="/tmp/mock_quic_cert.pem")
    parser.add_argument("--key", default="/tmp/mock_quic_key.pem")
    parser.add_argument(
        "--auth-fail",
        action="store_true",
        help="Reject all authentication attempts",
    )
    args = parser.parse_args()

    if not AIOQUIC_AVAILABLE:
        logger.error("aioquic is not installed. Install with: pip install aioquic")
        sys.exit(1)

    import os

    if not os.path.exists(args.cert) or not os.path.exists(args.key):
        logger.info(
            "Generating self-signed test cert/key at %s / %s", args.cert, args.key
        )
        _generate_self_signed_cert(args.cert, args.key)

    asyncio.run(_run_server(args.host, args.port, args.cert, args.key, args.auth_fail))


def _generate_self_signed_cert(cert_path: str, key_path: str) -> None:
    try:
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import ec
        from cryptography.x509.oid import NameOID
        import datetime

        key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "mock-quic-test")])
        now = datetime.datetime.utcnow()
        cert = (
            x509.CertificateBuilder()
            .subject_name(name)
            .issuer_name(name)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now)
            .not_valid_after(now + datetime.timedelta(days=1))
            .add_extension(
                x509.BasicConstraints(ca=True, path_length=None), critical=True
            )
            .sign(key, hashes.SHA256())
        )

        with open(cert_path, "wb") as f:
            f.write(cert.public_bytes(serialization.Encoding.PEM))
        with open(key_path, "wb") as f:
            f.write(
                key.private_bytes(
                    serialization.Encoding.PEM,
                    serialization.PrivateFormat.TraditionalOpenSSL,
                    serialization.NoEncryption(),
                )
            )
        logger.info("Self-signed cert generated successfully")
    except ImportError:
        logger.error(
            "cryptography package not available — cannot generate cert. "
            "Install with: pip install cryptography"
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
