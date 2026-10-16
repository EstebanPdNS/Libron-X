#!/usr/bin/env python3
"""Build and test the public C compression interface without Swift or AppKit.

Uses only a supplied C compiler and an explicitly supplied zlib source tree.
Downloads nothing and never reads original Libronix resources.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
from datetime import datetime, timezone


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cc", default="clang" if os.name == "nt" else "cc",
                        help="Compiler executable; GCC/Clang command syntax.")
    parser.add_argument("--cc-arg", action="append", default=[],
                        help="Repeated compiler-prefix argument; for Zig use --cc-arg=cc.")
    parser.add_argument("--zlib-source", type=Path, required=True,
                        help="Existing zlib >= 1.2.9 source directory (with zconf.h).")
    parser.add_argument("--output-dir", type=Path,
                        default=Path(__file__).resolve().parents[1] / ".build" / "compression-contract")
    parser.add_argument("--threading", choices=("windows", "posix"),
                        default="windows" if os.name == "nt" else "posix",
                        help="Thread/link ABI of the target, not necessarily the host.")
    parser.add_argument("--compile-only", action="store_true",
                        help="Do not run a cross-compiled executable; records build evidence only.")
    args = parser.parse_args()

    package = Path(__file__).resolve().parents[1]
    compression = package / "Sources" / "CLibronxCompression"
    test = package / "Tests" / "CompressionContract" / "compression_contract.c"
    zlib_source = args.zlib_source.resolve()
    zlib_names = ["adler32.c", "crc32.c", "inffast.c", "inflate.c",
                  "inftrees.c", "uncompr.c", "zutil.c"]
    zlib_files = [zlib_source / name for name in zlib_names]
    required = zlib_files + [zlib_source / "zlib.h", zlib_source / "zconf.h"]
    for path in required:
        if not path.is_file():
            parser.error(f"Required zlib source file not found: {path}")
    version_match = re.search(r'#define ZLIB_VERSION "([^"]+)"',
                              (zlib_source / "zlib.h").read_text(encoding="utf-8"))
    if version_match is None:
        parser.error("The supplied zlib.h has no ZLIB_VERSION declaration.")
    components = re.match(r"(\d+)\.(\d+)\.(\d+)", version_match.group(1))
    if components is None or tuple(map(int, components.groups())) < (1, 2, 9):
        parser.error("zlib >= 1.2.9 is required for uncompress2().")

    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    executable = output_dir / ("compression-contract.exe" if args.threading == "windows"
                               else "compression-contract")
    compiler = [args.cc] + args.cc_arg
    command = compiler + ["-std=c99", "-O2", "-Wall", "-Wextra", "-Werror",
                           "-I", str(compression / "include"), "-I", str(zlib_source),
                           str(compression / "wrapper.c"), str(compression / "blast.c"),
                           str(test)] + [str(path) for path in zlib_files]
    command += ["-o", str(executable)]
    if args.threading == "posix":
        command += ["-pthread"]
    evidence = {
        "schemaVersion": 1,
        "startedAtUTC": datetime.now(timezone.utc).isoformat(),
        "scope": "CLibronxCompression public C ABI; synthetic fixtures only",
        "host": {"system": platform.system(), "machine": platform.machine()},
        "targetThreading": args.threading,
        "compileOnly": args.compile_only,
        "zlibVersion": version_match.group(1),
        "command": command,
        "sourceSHA256": {
            str(path.relative_to(package)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in [compression / "wrapper.c", compression / "blast.c",
                         compression / "blast.h", compression / "include" / "LibronxCompression.h",
                         test, Path(__file__).resolve()]
        },
        "dependencySHA256": {
            path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in required
        },
    }
    report = output_dir / "compression-contract-report.json"
    exit_code = 1
    try:
        version = subprocess.run(compiler + ["--version"], check=True, capture_output=True,
                                 text=True, timeout=60)
        evidence["compilerVersion"] = version.stdout.strip()
        build = subprocess.run(command, capture_output=True, text=True, timeout=300)
        evidence["build"] = {"exitCode": build.returncode, "stdout": build.stdout,
                             "stderr": build.stderr}
        if build.returncode == 0:
            evidence["executableSHA256"] = hashlib.sha256(executable.read_bytes()).hexdigest()
            if args.compile_only:
                exit_code = 0
            else:
                run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=60)
                evidence["run"] = {"exitCode": run.returncode, "stdout": run.stdout,
                                   "stderr": run.stderr}
                if run.returncode == 0:
                    evidence["results"] = json.loads(run.stdout)
                    exit_code = 0
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        evidence["error"] = str(error)
    evidence["finishedAtUTC"] = datetime.now(timezone.utc).isoformat()
    evidence["status"] = "passed" if exit_code == 0 else "failed"
    report.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"status": evidence["status"], "report": str(report),
                      "results": evidence.get("results"), "compileOnly": args.compile_only}))
    if exit_code != 0:
        print(evidence.get("error") or evidence.get("run", evidence.get("build", {})).get("stderr", ""),
              file=sys.stderr)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
