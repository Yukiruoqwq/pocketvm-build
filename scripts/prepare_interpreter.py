#!/usr/bin/env python3
"""Namespace UTM SE's runtime so dyld cannot substitute JIT dependencies."""
import pathlib
import plistlib
import shutil
import subprocess
import sys

source = pathlib.Path(sys.argv[1]) / "Frameworks"
target = pathlib.Path(sys.argv[2]) / "Frameworks"
target.mkdir(parents=True, exist_ok=True)
mapping = {}
binaries = []
for framework in sorted(source.glob("*.framework")):
    old = framework.stem
    new = "tci-" + old
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
for binary in binaries:
    subprocess.run(["codesign", "--remove-signature", str(binary)], check=False, capture_output=True)
    # Mach-O load commands are structured linker metadata, not runtime output.
    loads = subprocess.check_output(["otool", "-L", str(binary)], text=True).splitlines()[1:]
    changes = []
    for line in loads:
        old_path = line.strip().split(" (", 1)[0]
        for suffix, new_path in mapping.items():
            if old_path.endswith("/" + suffix):
                changes += ["-change", old_path, new_path]
                break
        else:
            if old_path.startswith("@"):
                raise RuntimeError(f"Unresolved runtime dependency: {old_path}")
    identity = f"@rpath/{binary.parent.name}/{binary.name}"
    subprocess.run(["install_name_tool", "-id", identity, *changes, str(binary)], check=True)
    subprocess.run(["xcrun", "lipo", str(binary), "-verify_arch", "arm64"], check=True)

root = target / "tci-qemu-aarch64-softmmu.framework/tci-qemu-aarch64-softmmu"
symbols = subprocess.check_output(["xcrun", "nm", "-g", str(root)], text=True)
for required in ("_qemu_init", "_qemu_main_loop", "_qemu_cleanup", "_tcg_qemu_tb_exec"):
    if not any(line.split()[-1:] == [required] and " U " not in line for line in symbols.splitlines()):
        raise RuntimeError(f"Interpreter symbol missing: {required}")
print(f"Prepared {len(binaries)} isolated interpreter frameworks")
