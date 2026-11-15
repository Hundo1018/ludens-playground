#!/usr/bin/env python3
"""Write the base colour image of a glTF material to a file (for scripts/convert_texture.py).

    python3 scripts/extract_glb_texture.py <model.glb> <material-index> <out.png>

Follows material -> pbrMetallicRoughness.baseColorTexture -> texture -> image; the image is read from its bufferView
in the binary chunk (embedded images only; an external URI is an error). Standard library only.
"""
import json
import pathlib
import struct
import sys


def read_glb(path: pathlib.Path):
    data = path.read_bytes()
    if data[:4] != b"glTF":
        raise SystemExit("extract_glb_texture: not a GLB file")
    off = 12
    doc = None
    binchunk = None
    while off < len(data):
        length, kind = struct.unpack_from("<II", data, off)
        body = data[off + 8: off + 8 + length]
        if kind == 0x4E4F534A:  # JSON
            doc = json.loads(body.decode("utf-8"))
        elif kind == 0x004E4942:  # BIN
            binchunk = body
        off += 8 + length
    if doc is None or binchunk is None:
        raise SystemExit("extract_glb_texture: missing JSON or BIN chunk")
    return doc, binchunk


def base_colour_image(doc, binchunk, material_index: int) -> bytes:
    material = doc["materials"][material_index]
    info = material.get("pbrMetallicRoughness", {}).get("baseColorTexture")
    if info is None:
        raise SystemExit(f"extract_glb_texture: material {material_index} has no baseColorTexture")
    texture = doc["textures"][info["index"]]
    image = doc["images"][texture["source"]]
    if "bufferView" not in image:
        raise SystemExit("extract_glb_texture: the image is external; only embedded images are supported")
    view = doc["bufferViews"][image["bufferView"]]
    start = view.get("byteOffset", 0)
    return bytes(binchunk[start: start + view["byteLength"]])


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    doc, binchunk = read_glb(pathlib.Path(sys.argv[1]))
    out = pathlib.Path(sys.argv[3])
    out.write_bytes(base_colour_image(doc, binchunk, int(sys.argv[2])))
    print(f"extract_glb_texture: {out} ({out.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
