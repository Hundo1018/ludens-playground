"""The native archives the [native] section of wasm.toml links: musl sinf/cosf (ludens-wasm-rt) and miniaudio's shim.

The engine builds the same two (its scripts/native_libs.py); this package does too, so a clean checkout can run the native
reference build. Run after `scripts/deps.sh`: it needs build/deps/miniaudio-mojo."""
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MA = ROOT / "build/deps/miniaudio-mojo"


def native_env() -> dict[str, str]:
    """The environment without a pixi wasm environment's toolchain on PATH (its conda cc does not link on this system)."""
    env = dict(os.environ)
    env["PATH"] = os.pathsep.join(p for p in env.get("PATH", "").split(os.pathsep) if "/envs/wasm" not in p)
    return env


def build_all() -> None:
    from ludens_wasm_rt import native_math
    (ROOT / "build").mkdir(exist_ok=True)
    native_math.build(ROOT / "build/libwasmrt_math.a")
    subprocess.run(["python3", "tools/build_shim_static.py"], cwd=MA, check=True, env=native_env(), capture_output=True)
    # The build driver resolves each library manifest's [native] paths against that library's own root: the engine's
    # manifest (read as a lib) names build/libwasmrt_math.a relative to build/deps/ludens-engine/. Put copies there too.
    engine = ROOT / "build/deps/ludens-engine"
    for src, dst in [(ROOT / "build/libwasmrt_math.a", engine / "build/libwasmrt_math.a"),
                     (MA / "build/libma_shim.a", engine / "build/deps/miniaudio-mojo/build/libma_shim.a")]:
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(src.read_bytes())


if __name__ == "__main__":
    build_all()
    print("native_libs: build/libwasmrt_math.a and miniaudio's shim built")
