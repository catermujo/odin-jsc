from __future__ import annotations

import argparse
import platform
import shlex
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WEBKIT_ROOT = ROOT / "WebKit"


def _host_os() -> str:
    return platform.system()


def _run(args: list[str], *, cwd: Path) -> None:
    cmd = " ".join(shlex.quote(part) for part in args)
    print(f"[build_cjsc] $ {cmd}  (cwd={cwd})")
    subprocess.run(args, cwd=cwd, check=True)


def _normalize_configuration(raw: str) -> str:
    lowered = raw.strip().lower()
    if lowered == "release":
        return "Release"
    if lowered == "debug":
        return "Debug"
    msg = f"Unsupported configuration `{raw}`. Expected `release` or `debug`."
    raise ValueError(msg)


def _as_build_jsc_flag(configuration: str) -> str:
    return "--release" if configuration == "Release" else "--debug"


def _resolve_build_root(configuration: str, build_dir: Path | None) -> Path:
    if build_dir is not None:
        # DUMBAI: keep custom build-dir behavior aligned with WebKit's --build-dir by matching the per-port layout.
        if _host_os() == "Windows":
            return build_dir / configuration
        return build_dir / "GTK" / configuration

    if _host_os() == "Windows":
        return WEBKIT_ROOT / "WebKitBuild" / configuration
    return WEBKIT_ROOT / "WebKitBuild" / "GTK" / configuration


def _copy_linux_artifacts(build_root: Path) -> None:
    lib_dir = build_root / "lib"
    if not lib_dir.exists():
        msg = (
            "Expected Linux JavaScriptCore output directory missing: "
            f"{lib_dir}\n"
            "Run the script again after a successful WebKit GTK build."
        )
        raise FileNotFoundError(msg)

    # DUMBAI: copy both linker name and SONAME-versioned artifacts so local runtime loading stays consistent.
    matches = sorted(lib_dir.glob("libjavascriptcoregtk-4.1.so*"))
    if not matches:
        msg = (
            "Could not find `libjavascriptcoregtk-4.1.so*` under "
            f"{lib_dir}. Verify the WebKit GTK build succeeded."
        )
        raise FileNotFoundError(msg)

    for src in matches:
        resolved = src.resolve() if src.is_symlink() else src
        dst = ROOT / src.name
        shutil.copy2(resolved, dst)
        print(f"[build_cjsc] copied {src} -> {dst}")

    # DUMBAI: ensure non-versioned linker name exists even if upstream only emitted versioned files.
    linker_name = ROOT / "libjavascriptcoregtk-4.1.so"
    if not linker_name.exists():
        chosen = max(matches, key=lambda path: path.stat().st_mtime_ns)
        resolved = chosen.resolve() if chosen.is_symlink() else chosen
        shutil.copy2(resolved, linker_name)
        print(f"[build_cjsc] synthesized linker name from {chosen} -> {linker_name}")


def _latest_by_mtime(paths: list[Path]) -> Path:
    return max(paths, key=lambda path: path.stat().st_mtime_ns)


def _copy_windows_artifacts(build_root: Path) -> None:
    if not build_root.exists():
        msg = (
            "Expected Windows JavaScriptCore build root missing: "
            f"{build_root}\n"
            "Run the script again after a successful WebKit Windows build."
        )
        raise FileNotFoundError(msg)

    dll_candidates = [
        path for path in build_root.rglob("JavaScriptCore.dll") if path.is_file()
    ]
    lib_candidates = [
        path for path in build_root.rglob("JavaScriptCore.lib") if path.is_file()
    ]
    if not dll_candidates or not lib_candidates:
        msg = (
            "Could not locate `JavaScriptCore.dll` and `JavaScriptCore.lib` under "
            f"{build_root}. Verify the WebKit Windows build succeeded."
        )
        raise FileNotFoundError(msg)

    chosen_dll = _latest_by_mtime(dll_candidates)
    chosen_lib = _latest_by_mtime(lib_candidates)

    dst_dll = ROOT / "JavaScriptCore.dll"
    dst_lib = ROOT / "JavaScriptCore.lib"
    shutil.copy2(chosen_dll, dst_dll)
    shutil.copy2(chosen_lib, dst_lib)
    print(f"[build_cjsc] copied {chosen_dll} -> {dst_dll}")
    print(f"[build_cjsc] copied {chosen_lib} -> {dst_lib}")


def parse_args() -> tuple[argparse.Namespace, list[str]]:
    parser = argparse.ArgumentParser(
        prog="build_cjsc.py",
        description=(
            "Build JavaScriptCore from the vendored WebKit checkout and copy "
            "Linux/Windows runtime artifacts into vendor/jsc."
        ),
    )
    parser.add_argument(
        "--configuration",
        default="release",
        choices=("release", "debug"),
        help="Build configuration to request from WebKit (default: release).",
    )
    parser.add_argument(
        "--build-dir",
        type=Path,
        help="Optional build output root passed to WebKit's --build-dir.",
    )
    parser.add_argument(
        "--skip-build",
        action="store_true",
        help="Skip invoking build-jsc and only copy artifacts from an existing build tree.",
    )
    args, passthrough = parser.parse_known_args()
    return args, passthrough


def main() -> int:
    args, passthrough = parse_args()
    host = _host_os()
    if host not in {"Linux", "Windows"}:
        msg = (
            f"build_cjsc.py supports Linux and Windows only. Current host is `{host}`."
        )
        raise RuntimeError(msg)

    if not WEBKIT_ROOT.exists():
        msg = (
            "Missing vendored WebKit checkout at "
            f"{WEBKIT_ROOT}. Clone WebKit there before running this script."
        )
        raise FileNotFoundError(msg)

    configuration = _normalize_configuration(args.configuration)
    build_dir = args.build_dir.resolve() if args.build_dir else None

    if not args.skip_build:
        command = [
            "perl",
            "Tools/Scripts/build-jsc",
            _as_build_jsc_flag(configuration),
            "--win" if host == "Windows" else "--gtk",
        ]
        if build_dir is not None:
            command.append(f"--build-dir={build_dir}")
        # DUMBAI: keep passthrough args so callers can inject port-specific cmake flags without editing this script.
        command.extend(passthrough)
        _run(command, cwd=WEBKIT_ROOT)

    build_root = _resolve_build_root(configuration, build_dir)
    print(f"[build_cjsc] using build root: {build_root}")
    if host == "Windows":
        _copy_windows_artifacts(build_root)
    else:
        _copy_linux_artifacts(build_root)
    print("[build_cjsc] done")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
