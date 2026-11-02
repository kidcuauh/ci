#!/usr/bin/env python3
"""Convierte CustomResourceDefinitions (JSON, uno o varios documentos por la entrada
estándar) en JSON Schema para kubeconform. Solo biblioteca estándar.

Uso: yq -o=json '.' crd.yaml | crd-to-schema.py --out DIR grupo:Kind:versión...

Escribe DIR/<grupo>/<kind en minúsculas>_<versión>.json. Quita lo que no valida
(description, default, format, x-kubernetes-*) y cierra con additionalProperties:
false todo objeto que define `properties` y no pide preservar campos desconocidos.
Falla si algún grupo:Kind:versión pedido no aparece en la entrada.
"""
import argparse
import json
import os
import sys

DROP = {"description", "default", "format", "example", "examples", "title", "externalDocs"}
SCHEMA_LISTS = ("allOf", "anyOf", "oneOf")


def convert(s):
    if not isinstance(s, dict):
        return s
    out = {}
    preserve = s.get("x-kubernetes-preserve-unknown-fields") is True
    for k, v in s.items():
        if k in DROP or k.startswith("x-kubernetes-"):
            continue
        if k == "properties":
            out[k] = {n: convert(p) for n, p in v.items()}
        elif k in ("items", "not"):
            out[k] = convert(v)
        elif k == "additionalProperties":
            out[k] = convert(v) if isinstance(v, dict) else v
        elif k in SCHEMA_LISTS:
            out[k] = [convert(x) for x in v]
        else:
            out[k] = v
    if s.get("x-kubernetes-int-or-string") is True:
        out.pop("type", None)
        out["anyOf"] = [{"type": "integer"}, {"type": "string"}]
    if s.get("nullable") is True and isinstance(out.get("type"), str):
        out["type"] = [out["type"], "null"]
    out.pop("nullable", None)
    if (
        "properties" in out
        and not preserve
        and "additionalProperties" not in out
        and not any(x in out for x in SCHEMA_LISTS + ("not",))
    ):
        out["additionalProperties"] = False
    return out


def read_docs(text):
    dec = json.JSONDecoder()
    i, n = 0, len(text)
    while True:
        while i < n and text[i].isspace():
            i += 1
        if i >= n:
            return
        doc, i = dec.raw_decode(text, i)
        if isinstance(doc, dict):
            yield doc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("want", nargs="+")
    args = ap.parse_args()
    want = set()
    for w in args.want:
        g, k, v = w.split(":")
        want.add((g, k, v))
    found = set()
    for doc in read_docs(sys.stdin.read()):
        if doc.get("kind") != "CustomResourceDefinition":
            continue
        spec = doc["spec"]
        group, kind = spec["group"], spec["names"]["kind"]
        for ver in spec["versions"]:
            key = (group, kind, ver["name"])
            if key not in want:
                continue
            schema = convert(ver["schema"]["openAPIV3Schema"])
            schema["$schema"] = "http://json-schema.org/draft-07/schema#"
            d = os.path.join(args.out, group)
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, "%s_%s.json" % (kind.lower(), ver["name"])), "w") as f:
                json.dump(schema, f, sort_keys=True, separators=(",", ":"))
                f.write("\n")
            found.add(key)
    missing = want - found
    if missing:
        sys.exit("faltan en la entrada: " + ", ".join(":".join(m) for m in sorted(missing)))


if __name__ == "__main__":
    main()
