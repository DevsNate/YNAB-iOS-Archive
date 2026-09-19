#!/usr/bin/env python3
"""Independently verify the YNAB 26.35 V10 signer-neutral carrier."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import plistlib
import struct
import subprocess
import sys
import tempfile
import zipfile


EXPECTED_STOCK_SHA256 = "f6aff1df27ce87c21c60b16133c5be958ab3c20ec6c1a2be3be212064a4d1bde"
EXPECTED_IDENTITY = (
    "com.youneedabudget.evergreen.YNAB-Evergreen",
    "26.35",
    "744",
)
EXPECTED_FILE_COUNT = 387
EXPECTED_MACHO_CONTAINERS = 11
EXPECTED_MACHO_SLICES = 12
EXPECTED_SIGNATURE_DIRS = 10
EXPECTED_RESOLVER_SIZE = 750
PAGE_SIZE = 0x4000

MH_MAGIC_64_LE = b"\xcf\xfa\xed\xfe"
FAT_MAGIC_BE = b"\xca\xfe\xba\xbe"
LC_SEGMENT_64 = 0x19
LC_UUID = 0x1B
LC_CODE_SIGNATURE = 0x1D
DYLIB_COMMANDS = {0xC, 0xD, 0x20, 0x80000018, 0x8000001F, 0x80000023}

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
RESOLVER_SOURCE = PROJECT_ROOT / "patches/signer-neutral/YNABAppGroupResolver.S"

TARGETS = {
    "Payload/YNAB Evergreen.app/YNAB Evergreen": {
        "sha256": "d1cc306b4f026747cffb4c04103129c8addfa69e307635ca8545af7f3b23da13",
        "uuid": "7fce917f673f36c2b26d5b25f480eb03",
        "patch_vm": 0x100262900,
        "patch_bytes": bytes.fromhex(
            "889900d008410191088100d1801b0091010141b2f17b4794"
        ),
        "resolver_vm": 0x1019B00A0,
        "dlopen_vm": 0x101445A9C,
        "dlsym_vm": 0x101445AA8,
    },
    "Payload/YNAB Evergreen.app/PlugIns/YNABWidgetExtension.appex/YNABWidgetExtension": {
        "sha256": "dd64ce41e1e04b94628f2aa8f255105e92223fc5681a617ed47216adf62c0cb3",
        "uuid": "07b9cb20414d322b974529845a0c295b",
        "patch_vm": 0x100005C88,
        "patch_bytes": bytes.fromhex(
            "681700f008c11591088100d1801b0091010141b260970a94"
        ),
        "resolver_vm": 0x10033C088,
        "dlopen_vm": 0x1002AD744,
        "dlsym_vm": 0x1002AD750,
    },
    "Payload/YNAB Evergreen.app/PlugIns/YNABWidgetIntentHandler.appex/YNABWidgetIntentHandler": {
        "sha256": "e7bdd7de3cf0792ddf6cd25a29bf2cfba154be7e243261930a8876eb067cda08",
        "uuid": "bccd4075a6583ba78ff5da20bff2bdf4",
        "patch_vm": 0x100005990,
        "patch_bytes": bytes.fromhex(
            "c80b00b008c11c91088100d1801b0091010141b2f9600594"
        ),
        "resolver_vm": 0x100196210,
        "dlopen_vm": 0x10015F318,
        "dlsym_vm": 0x10015F324,
    },
}


def fail(message: str) -> "NoReturn":
    raise RuntimeError(message)


def sha256_bytes(data: bytes | bytearray) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_path(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_macho(data: bytes | bytearray, label: str) -> dict:
    if len(data) < 32 or bytes(data[:4]) != MH_MAGIC_64_LE:
        fail(f"not a thin little-endian Mach-O 64 image: {label}")
    ncmds, sizeofcmds = struct.unpack_from("<II", data, 16)
    offset = 32
    segments = []
    code_signature = None
    uuid = None
    dylibs = []
    for _ in range(ncmds):
        if offset + 8 > len(data):
            fail(f"truncated load-command table: {label}")
        command, command_size = struct.unpack_from("<II", data, offset)
        if command_size < 8 or offset + command_size > len(data):
            fail(f"invalid load command at {offset:#x}: {label}")
        if command == LC_SEGMENT_64:
            name = bytes(data[offset + 8 : offset + 24]).split(b"\0", 1)[0].decode()
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from(
                "<QQQQ", data, offset + 24
            )
            maxprot, initprot = struct.unpack_from("<ii", data, offset + 56)
            segments.append(
                {
                    "name": name,
                    "command_offset": offset,
                    "vmaddr": vmaddr,
                    "vmsize": vmsize,
                    "fileoff": fileoff,
                    "filesize": filesize,
                    "maxprot": maxprot,
                    "initprot": initprot,
                }
            )
        elif command == LC_CODE_SIGNATURE:
            if code_signature is not None:
                fail(f"multiple LC_CODE_SIGNATURE commands: {label}")
            dataoff, datasize = struct.unpack_from("<II", data, offset + 8)
            code_signature = {
                "command_offset": offset,
                "dataoff": dataoff,
                "datasize": datasize,
            }
        elif command == LC_UUID:
            uuid = bytes(data[offset + 8 : offset + 24]).hex()
        elif command in DYLIB_COMMANDS:
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            if name_offset >= command_size:
                fail(f"invalid dylib name offset: {label}")
            end = bytes(data[offset + name_offset : offset + command_size]).find(b"\0")
            if end < 0:
                fail(f"unterminated dylib name: {label}")
            name = bytes(
                data[offset + name_offset : offset + name_offset + end]
            ).decode("utf-8")
            dylibs.append((command, name))
        offset += command_size
    if offset != 32 + sizeofcmds:
        fail(f"load-command size mismatch: {label}")
    return {
        "ncmds": ncmds,
        "sizeofcmds": sizeofcmds,
        "segments": segments,
        "code_signature": code_signature,
        "uuid": uuid,
        "dylibs": dylibs,
    }


def parse_container(data: bytes, label: str) -> tuple[list[dict], list[bytes], str]:
    if data[:4] == MH_MAGIC_64_LE:
        return ([{"cpu_type": None, "cpu_subtype": None, "offset": 0, "align": None}], [data], "thin")
    if data[:4] != FAT_MAGIC_BE or len(data) < 8:
        fail(f"unsupported Mach-O container: {label}")
    count = struct.unpack_from(">I", data, 4)[0]
    if count <= 0 or 8 + 20 * count > len(data):
        fail(f"invalid fat header: {label}")
    arches = []
    slices = []
    previous_end = 0
    for index in range(count):
        cpu_type, cpu_subtype, offset, size, align_power = struct.unpack_from(
            ">iiIII", data, 8 + 20 * index
        )
        if offset % (1 << align_power) or offset < previous_end or offset + size > len(data):
            fail(f"invalid fat slice {index}: {label}")
        arches.append(
            {
                "cpu_type": cpu_type,
                "cpu_subtype": cpu_subtype,
                "offset": offset,
                "align": align_power,
            }
        )
        slices.append(data[offset : offset + size])
        previous_end = offset + size
    return arches, slices, "fat32"


def vm_to_file(parsed: dict, vmaddr: int, size: int, label: str) -> tuple[int, dict]:
    for segment in parsed["segments"]:
        start = segment["vmaddr"]
        if start <= vmaddr and vmaddr + size <= start + segment["filesize"]:
            return segment["fileoff"] + vmaddr - start, segment
    fail(f"VM range {vmaddr:#x}+{size:#x} is not file-backed: {label}")


def encode_bl(pc: int, target: int) -> bytes:
    delta = target - pc
    if delta % 4:
        fail(f"unaligned branch {pc:#x} -> {target:#x}")
    immediate = delta // 4
    if not -(1 << 25) <= immediate < (1 << 25):
        fail(f"branch out of range {pc:#x} -> {target:#x}")
    return struct.pack("<I", 0x94000000 | (immediate & 0x03FFFFFF))


def strip_expected(data: bytes, label: str) -> tuple[bytes, dict]:
    result = bytearray(data)
    parsed = parse_macho(result, label)
    signature = parsed["code_signature"]
    linkedit = [segment for segment in parsed["segments"] if segment["name"] == "__LINKEDIT"]
    if signature is None or len(linkedit) != 1:
        fail(f"missing signature or __LINKEDIT: {label}")
    linkedit = linkedit[0]
    dataoff, datasize = signature["dataoff"], signature["datasize"]
    if datasize <= 0 or dataoff + datasize != len(result):
        fail(f"stock signature is not an EOF payload: {label}")
    new_filesize = dataoff - linkedit["fileoff"]
    new_vmsize = (new_filesize + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1)
    struct.pack_into("<II", result, signature["command_offset"] + 8, dataoff, 0)
    struct.pack_into(
        "<QQQQ",
        result,
        linkedit["command_offset"] + 24,
        linkedit["vmaddr"],
        new_vmsize,
        linkedit["fileoff"],
        new_filesize,
    )
    return bytes(result[:dataoff]), {
        "signature_dataoff": dataoff,
        "removed_signature_bytes": datasize,
    }


def extract_resolver_text(object_path: pathlib.Path) -> bytes:
    data = object_path.read_bytes()
    parsed = parse_macho(data, str(object_path))
    offset = 32
    matches = []
    for _ in range(parsed["ncmds"]):
        command, command_size = struct.unpack_from("<II", data, offset)
        if command == LC_SEGMENT_64:
            section_count = struct.unpack_from("<I", data, offset + 64)[0]
            section_offset = offset + 72
            for _ in range(section_count):
                section_name = bytes(data[section_offset : section_offset + 16]).split(b"\0", 1)[0]
                segment_name = bytes(data[section_offset + 16 : section_offset + 32]).split(b"\0", 1)[0]
                section_size = struct.unpack_from("<Q", data, section_offset + 40)[0]
                file_offset = struct.unpack_from("<I", data, section_offset + 48)[0]
                relocation_offset, relocation_count = struct.unpack_from(
                    "<II", data, section_offset + 56
                )
                if section_name == b"__text" and segment_name == b"__TEXT":
                    if relocation_offset or relocation_count:
                        fail("resolver object unexpectedly contains relocations")
                    matches.append(data[file_offset : file_offset + section_size])
                section_offset += 80
        offset += command_size
    if len(matches) != 1 or len(matches[0]) != EXPECTED_RESOLVER_SIZE:
        fail("resolver payload shape mismatch")
    return matches[0]


def compile_resolver() -> bytes:
    with tempfile.TemporaryDirectory(prefix="ynab-v10-verify-resolver-") as temporary:
        object_path = pathlib.Path(temporary) / "resolver.o"
        subprocess.run(
            [
                "xcrun",
                "--sdk",
                "iphoneos",
                "clang",
                "-arch",
                "arm64",
                "-c",
                "-x",
                "assembler-with-cpp",
                str(RESOLVER_SOURCE),
                "-o",
                str(object_path),
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return extract_resolver_text(object_path)


def patch_expected_runtime(stock: bytes, target: dict, template: bytes, label: str) -> bytes:
    result = bytearray(stock)
    parsed = parse_macho(result, label)
    if sha256_bytes(stock) != target["sha256"] or parsed["uuid"] != target["uuid"]:
        fail(f"stock target identity mismatch: {label}")
    patch_offset, patch_segment = vm_to_file(
        parsed, target["patch_vm"], len(target["patch_bytes"]), label
    )
    cave_offset, cave_segment = vm_to_file(
        parsed, target["resolver_vm"], len(template), label
    )
    if bytes(result[patch_offset : patch_offset + len(target["patch_bytes"])]) != target["patch_bytes"]:
        fail(f"stock patch bytes mismatch: {label}")
    if any(result[cave_offset : cave_offset + len(template)]):
        fail(f"stock resolver cave is not zero: {label}")
    if not (patch_segment["initprot"] & 0x4 and cave_segment["initprot"] & 0x4):
        fail(f"runtime patch is not within executable storage: {label}")

    resolver = bytearray(template)
    offsets = []
    for index in range(1, 10):
        marker = struct.pack("<I", 0xFEED3000 + index)
        marker_offset = resolver.find(marker)
        if marker_offset < 0 or resolver.find(marker, marker_offset + 4) >= 0:
            fail(f"resolver marker mismatch: {index}")
        offsets.append(marker_offset)
        destination = target["dlopen_vm"] if index == 1 else target["dlsym_vm"]
        resolver[marker_offset : marker_offset + 4] = encode_bl(
            target["resolver_vm"] + marker_offset, destination
        )
    if offsets != [0x24, 0x38, 0x4C, 0x60, 0x74, 0x88, 0x9C, 0xB0, 0xC4]:
        fail(f"resolver marker layout mismatch: {label}")
    result[cave_offset : cave_offset + len(resolver)] = resolver
    call_patch = encode_bl(target["patch_vm"], target["resolver_vm"])
    call_patch += struct.pack("<I", 0xD503201F) * 5
    result[patch_offset : patch_offset + len(call_patch)] = call_patch
    return bytes(result)


def expected_container(stock: bytes, target: dict | None, template: bytes, label: str) -> tuple[bytes, int]:
    arches, slices, kind = parse_container(stock, label)
    if target is not None and kind != "thin":
        fail(f"runtime patch target unexpectedly uses a fat container: {label}")
    stripped_slices = []
    for index, stock_slice in enumerate(slices):
        runtime_input = (
            patch_expected_runtime(stock_slice, target, template, label)
            if target is not None
            else stock_slice
        )
        stripped, _ = strip_expected(runtime_input, f"{label}[{index}]")
        stripped_slices.append(stripped)
    if kind == "thin":
        return stripped_slices[0], 1

    result = bytearray(stock)
    final_size = 8 + 20 * len(arches)
    for index, (arch, old_slice, stripped) in enumerate(
        zip(arches, slices, stripped_slices)
    ):
        offset = arch["offset"]
        result[offset : offset + len(old_slice)] = b"\0" * len(old_slice)
        result[offset : offset + len(stripped)] = stripped
        struct.pack_into(">I", result, 8 + 20 * index + 12, len(stripped))
        final_size = max(final_size, offset + len(stripped))
    return bytes(result[:final_size]), len(arches)


def excluded(name: str) -> bool:
    parts = pathlib.PurePosixPath(name).parts
    return "_CodeSignature" in parts or (parts and parts[-1] == "embedded.mobileprovision")


def verify(stock_ipa: pathlib.Path, candidate_ipa: pathlib.Path, receipt_path: pathlib.Path | None) -> dict:
    if sha256_path(stock_ipa) != EXPECTED_STOCK_SHA256:
        fail("stock IPA SHA-256 mismatch")
    candidate_hash = sha256_path(candidate_ipa)
    if receipt_path is not None:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        if receipt.get("source", {}).get("sha256") != EXPECTED_STOCK_SHA256:
            fail("receipt stock hash mismatch")
        if receipt.get("output", {}).get("sha256") != candidate_hash:
            fail("receipt output hash mismatch")

    resolver_template = compile_resolver()
    with zipfile.ZipFile(stock_ipa, "r") as stock_zip, zipfile.ZipFile(
        candidate_ipa, "r"
    ) as candidate_zip:
        stock_names = [info.filename for info in stock_zip.infolist()]
        candidate_names = [info.filename for info in candidate_zip.infolist()]
        if len(stock_names) != len(set(stock_names)) or len(candidate_names) != len(
            set(candidate_names)
        ):
            fail("duplicate ZIP entry detected")
        expected_files = sorted(
            name
            for name in stock_names
            if not name.endswith("/") and not excluded(name)
        )
        candidate_files = sorted(
            name for name in candidate_names if not name.endswith("/")
        )
        if candidate_files != expected_files or len(candidate_files) != EXPECTED_FILE_COUNT:
            fail("candidate file surface differs beyond signing resources")
        removed_signature_dirs = {
            str(pathlib.PurePosixPath(name).parent)
            for name in stock_names
            if not name.endswith("/") and "_CodeSignature" in pathlib.PurePosixPath(name).parts
        }
        if len(removed_signature_dirs) != EXPECTED_SIGNATURE_DIRS:
            fail("stock signature-directory count mismatch")

        app_root = "Payload/YNAB Evergreen.app/"
        info = plistlib.loads(candidate_zip.read(app_root + "Info.plist"))
        identity = (
            info.get("CFBundleIdentifier"),
            info.get("CFBundleShortVersionString"),
            info.get("CFBundleVersion"),
        )
        if identity != EXPECTED_IDENTITY:
            fail(f"candidate product identity mismatch: {identity}")

        macho_containers = 0
        macho_slices = 0
        runtime_patched = 0
        for name in candidate_files:
            stock_data = stock_zip.read(name)
            candidate_data = candidate_zip.read(name)
            if stock_data[:4] not in (MH_MAGIC_64_LE, FAT_MAGIC_BE):
                if candidate_data != stock_data:
                    fail(f"non-Mach-O payload changed: {name}")
                continue
            macho_containers += 1
            target = TARGETS.get(name)
            expected_data, slice_count = expected_container(
                stock_data, target, resolver_template, name
            )
            macho_slices += slice_count
            if candidate_data != expected_data:
                fail(f"Mach-O differs from independently reconstructed output: {name}")
            stock_arches, stock_slices, _ = parse_container(stock_data, name)
            candidate_arches, candidate_slices, _ = parse_container(candidate_data, name)
            if [
                (item["cpu_type"], item["cpu_subtype"], item["align"])
                for item in stock_arches
            ] != [
                (item["cpu_type"], item["cpu_subtype"], item["align"])
                for item in candidate_arches
            ]:
                fail(f"Mach-O architecture set changed: {name}")
            for index, (stock_slice, candidate_slice) in enumerate(
                zip(stock_slices, candidate_slices)
            ):
                stock_parsed = parse_macho(stock_slice, f"{name}[stock:{index}]")
                candidate_parsed = parse_macho(
                    candidate_slice, f"{name}[candidate:{index}]"
                )
                signature = candidate_parsed["code_signature"]
                if signature is None or signature["datasize"] != 0:
                    fail(f"candidate signature command is not empty: {name}[{index}]")
                if len(candidate_slice) != signature["dataoff"]:
                    fail(f"candidate signature payload was not physically removed: {name}[{index}]")
                if stock_parsed["uuid"] != candidate_parsed["uuid"]:
                    fail(f"Mach-O UUID changed: {name}[{index}]")
                if stock_parsed["dylibs"] != candidate_parsed["dylibs"]:
                    fail(f"Mach-O dylib dependencies changed: {name}[{index}]")
                if any(segment["name"] == "__NEUTRAL" for segment in candidate_parsed["segments"]):
                    fail(f"unexpected injected segment: {name}[{index}]")
            if target is not None:
                runtime_patched += 1

        if macho_containers != EXPECTED_MACHO_CONTAINERS:
            fail(f"Mach-O container count mismatch: {macho_containers}")
        if macho_slices != EXPECTED_MACHO_SLICES:
            fail(f"Mach-O slice count mismatch: {macho_slices}")
        if runtime_patched != len(TARGETS):
            fail(f"runtime patch count mismatch: {runtime_patched}")

        forbidden = (
            b"YNABServerURLBridge",
            b"YNABOffline",
            b"OrpheusPrivateService",
            b"ynabSelectServerURL",
        )
        for name in candidate_files:
            data = candidate_zip.read(name)
            if any(marker in data for marker in forbidden):
                fail(f"functional/private-server marker present: {name}")

    with tempfile.TemporaryDirectory(prefix="ynab-v10-verify-codesign-") as temporary:
        root = pathlib.Path(temporary)
        with zipfile.ZipFile(candidate_ipa, "r") as candidate_zip:
            candidate_zip.extractall(root)
        app = root / "Payload/YNAB Evergreen.app"
        verification = subprocess.run(
            ["codesign", "--verify", "--deep", "--strict", str(app)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if verification.returncode == 0:
            fail("candidate unexpectedly verifies as signed")

    return {
        "stock_sha256": EXPECTED_STOCK_SHA256,
        "candidate_sha256": candidate_hash,
        "regular_files": EXPECTED_FILE_COUNT,
        "signature_directories_removed": EXPECTED_SIGNATURE_DIRS,
        "macho_containers": macho_containers,
        "macho_slices": macho_slices,
        "runtime_patches": runtime_patched,
        "codesign_verify": "expected failure: resign-required",
        "result": "VALID",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("stock_ipa", type=pathlib.Path)
    parser.add_argument("candidate_ipa", type=pathlib.Path)
    parser.add_argument("--receipt", type=pathlib.Path)
    arguments = parser.parse_args()
    try:
        result = verify(
            arguments.stock_ipa.resolve(),
            arguments.candidate_ipa.resolve(),
            arguments.receipt.resolve() if arguments.receipt else None,
        )
    except (OSError, RuntimeError, subprocess.CalledProcessError, zipfile.BadZipFile, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
