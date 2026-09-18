#!/usr/bin/env python3
"""Namespace UTM SE's runtime so dyld cannot substitute JIT dependencies."""
import pathlib
import plistlib
import shutil
import subprocess
import struct
import sys

source = pathlib.Path(sys.argv[1]) / "Frameworks"
target = pathlib.Path(sys.argv[2]) / "Frameworks"
target.mkdir(parents=True, exist_ok=True)
mapping = {}
binaries = []
for framework in sorted(source.glob("*.framework")):
    old = framework.stem
    new = "tci" + old[3:]
    if len(old) < 3 or new == old or new in [p.name for p in binaries]:
        raise RuntimeError(f"Runtime name collision: {old}")
    dest = target / (new + ".framework")
    if dest.exists():
        raise RuntimeError(f"Refusing to overwrite {dest}")
    shutil.copytree(framework, dest)
    binary = dest / new
    (dest / old).rename(binary)
    signature = dest / "_CodeSignature"
    if signature.exists():
        shutil.rmtree(signature)
    with (dest / "Info.plist").open("rb") as f:
        info = plistlib.load(f)
    info["CFBundleExecutable"] = new
    info["CFBundleName"] = new
    info["CFBundleIdentifier"] = "com.pocketvm.tci." + old
    with (dest / "Info.plist").open("wb") as f:
        plistlib.dump(info, f)
    mapping[f"{old}.framework/{old}"] = f"@rpath/{new}.framework/{new}"
    binaries.append(binary)

if list(source.glob("*.dylib")):
    raise RuntimeError("Unbundled dependencies require explicit namespacing")
def macho_commands(data):
    # UTM SE's iOS asset contains thin ARM64 images. Refuse any other layout.
    if data[:4] != bytes.fromhex("cffaedfe") or struct.unpack_from("<I", data, 4)[0] != 0x0100000C:
        raise RuntimeError("Expected a thin ARM64 Mach-O image")
    count, total = struct.unpack_from("<II", data, 16)
    cursor = 32
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, cursor)
        if size < 8 or cursor + size > 32 + total:
            raise RuntimeError("Invalid Mach-O command bounds")
        yield command, cursor, size
        cursor += size


for binary in binaries:
    data = bytearray(binary.read_bytes())
    for command, cursor, size in macho_commands(data):
        if command not in (0xC, 0xD, 0x80000018, 0x8000001F, 0x80000023):
            continue
        offset = struct.unpack_from("<I", data, cursor + 8)[0]
        start = cursor + offset
        end = data.index(0, start, cursor + size)
        old_path = data[start:end].decode()
        for suffix, new_path in mapping.items():
            if old_path.endswith("/" + suffix):
                # Preserve the original prefix as well as every segment offset.
                replacement = old_path[:-len(suffix)] + new_path[len("@rpath/"):]
                encoded = replacement.encode()
                if len(encoded) != end - start:
                    raise RuntimeError("Runtime rename changed load-command size")
                data[start:end] = encoded
                break
        else:
            if old_path.startswith("@"):
                raise RuntimeError(f"Unresolved runtime dependency: {old_path}")
    binary.write_bytes(data)
    # Re-sign after editing. No load-command or LINKEDIT resizing is needed.
    subprocess.run(["codesign", "--force", "--sign", "-", str(binary.parent)], check=True)
    subprocess.run(["codesign", "--verify", str(binary.parent)], check=True)

root = target / "tciu-aarch64-softmmu.framework/tciu-aarch64-softmmu"
data = root.read_bytes()
defined = set()
for command, cursor, size in macho_commands(data):
    if command != 2:
        continue
    symoff, count, stroff, strsize = struct.unpack_from("<IIII", data, cursor + 8)
    for index in range(count):
        string_index, kind, section, description, value = struct.unpack_from("<IBBHQ", data, symoff + index * 16)
        if kind & 0x0E == 0 or string_index >= strsize:
            continue
        start = stroff + string_index
        end = data.index(0, start, stroff + strsize)
        defined.add(data[start:end].decode())
for required in ("_qemu_init", "_qemu_main_loop", "_qemu_cleanup", "_tcg_qemu_tb_exec"):
    if required not in defined:
        raise RuntimeError(f"Interpreter symbol missing: {required}")
print(f"Prepared {len(binaries)} isolated interpreter frameworks")
