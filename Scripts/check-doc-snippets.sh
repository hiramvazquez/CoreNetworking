#!/usr/bin/env bash
# Scripts/check-doc-snippets.sh — PRD-X-04: los artículos DocC muestran el código de
# `Snippets/` en línea (bloques ```swift precedidos de `<!-- snippet: <name> -->`) en vez
# de `@Snippet(path:)`, que no se resuelve en el PRIMER `xcodebuild docbuild` sobre
# DerivedData limpio (la extracción de símbolos de `Snippets/` termina después de compilar
# la documentación). El bloque en línea siempre está — nada que resolver — pero puede
# pudrirse si alguien edita el snippet y olvida el artículo (o al revés): este script
# compara cada bloque marcado con el contenido "visible" del snippet correspondiente y
# falla si difieren.
#
# Contenido "visible" de un snippet (mismo criterio que PRD-X-04 §1):
#   - si el fichero tiene `// snippet.show` / `// snippet.hide`, la región entre ambos
#     marcadores (sin las líneas de los marcadores);
#   - si no, el fichero entero MENOS la cabecera de comentarios (las líneas `//` iniciales
#     que documentan qué enseña el snippet y por qué), con blancos de sobra recortados.
#
# Uso:
#   Scripts/check-doc-snippets.sh          # comprueba; sale 1 si algo diverge
#   Scripts/check-doc-snippets.sh --fix    # regenera los bloques divergentes in situ
#
# También migra en el sitio cualquier `@Snippet(path: "<Pkg>/Snippets/<name>")` que quede
# (sintaxis vieja, no se resuelve en el primer docbuild) a `<!-- snippet: <name> -->` + el
# bloque ```swift correspondiente — solo con --fix; en modo comprobación, un `@Snippet(`
# que quede es, él mismo, una divergencia.
#
# CI: .github/workflows/ci.yml, job `docs`, antes de `xcodebuild docbuild`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FIX=0
for arg in "$@"; do
    case "$arg" in
        --fix) FIX=1 ;;
        *)
            echo "Uso: $0 [--fix]" >&2
            exit 2
            ;;
    esac
done

python3 - "$REPO_ROOT" "$FIX" <<'PYEOF'
import pathlib
import re
import sys

repo_root = pathlib.Path(sys.argv[1])
fix = sys.argv[2] == "1"

PACKAGES = ["AppFoundation", "CoreNetworking"]

# Modo paquete único: si REPO_ROOT es la raíz de un paquete (repo publicado por subtree
# split), el nombre del paquete es el del directorio y su raíz es REPO_ROOT.
if (repo_root / "Package.swift").exists():
    PACKAGE_ROOTS = {repo_root.name: repo_root}
else:
    PACKAGE_ROOTS = {name: repo_root / name for name in PACKAGES}

LEGACY_RE = re.compile(r'^@Snippet\(path:\s*"([^"]+)/Snippets/([^"]+)"\)\s*$')
MARKER_RE = re.compile(r'^<!-- snippet:\s*(\S+)\s*-->\s*$')


def visible_content(source: str) -> str:
    lines = source.split("\n")

    show_idx = hide_idx = None
    for i, line in enumerate(lines):
        if show_idx is None and "// snippet.show" in line:
            show_idx = i
        elif show_idx is not None and "// snippet.hide" in line:
            hide_idx = i
            break

    if show_idx is not None and hide_idx is not None:
        body = lines[show_idx + 1 : hide_idx]
    else:
        i = 0
        while i < len(lines) and lines[i].lstrip().startswith("//"):
            i += 1
        body = lines[i:]

    while body and body[0].strip() == "":
        body.pop(0)
    while body and body[-1].strip() == "":
        body.pop()

    return "\n".join(body)


def snippet_path(package: str, name: str) -> pathlib.Path:
    return PACKAGE_ROOTS[package] / "Snippets" / f"{name}.swift"


def process_file(md_path: pathlib.Path, package: str, errors: list, fixed_count: list, checked_count: list):
    original = md_path.read_text()
    lines = original.split("\n")
    out = []
    changed = False
    i = 0
    while i < len(lines):
        line = lines[i]

        legacy = LEGACY_RE.match(line)
        marker = MARKER_RE.match(line)

        if legacy:
            snippet_pkg, name = legacy.group(1), legacy.group(2)
            path = snippet_path(snippet_pkg, name)
            if not path.exists():
                errors.append(f"{md_path}: @Snippet(path: \"{snippet_pkg}/Snippets/{name}\") — no existe {path}")
                out.append(line)
                i += 1
                continue
            if fix:
                content = visible_content(path.read_text())
                out.append(f"<!-- snippet: {name} -->")
                out.append("```swift")
                out.extend(content.split("\n"))
                out.append("```")
                changed = True
                fixed_count[0] += 1
                checked_count[0] += 1
            else:
                errors.append(
                    f"{md_path}: sigue usando @Snippet(path:) para «{name}» — "
                    f"ejecuta con --fix para convertirlo a un bloque en línea"
                )
                out.append(line)
            i += 1
            continue

        if marker:
            name = marker.group(1)
            path = snippet_path(package, name)
            out.append(line)
            i += 1

            # El bloque ```swift debe venir justo a continuación.
            if i >= len(lines) or lines[i].strip() != "```swift":
                errors.append(f"{md_path}: <!-- snippet: {name} --> sin un bloque ```swift justo después")
                continue

            fence_open_idx = i
            out.append(lines[i])
            i += 1
            block_lines = []
            while i < len(lines) and lines[i] != "```":
                block_lines.append(lines[i])
                i += 1
            if i >= len(lines):
                errors.append(f"{md_path}: bloque ```swift de «{name}» nunca se cierra")
                out.extend(block_lines)
                continue

            checked_count[0] += 1
            actual = "\n".join(block_lines)

            if not path.exists():
                errors.append(f"{md_path}: <!-- snippet: {name} --> — no existe {path}")
                out.extend(block_lines)
                out.append(lines[i])  # ```
                i += 1
                continue

            expected = visible_content(path.read_text())

            if actual != expected:
                if fix:
                    out.extend(expected.split("\n"))
                    changed = True
                    fixed_count[0] += 1
                else:
                    errors.append(
                        f"{md_path}: el bloque de «{name}» diverge de {path.relative_to(repo_root)} "
                        f"(ejecuta con --fix para regenerarlo)"
                    )
                    out.extend(block_lines)
            else:
                out.extend(block_lines)

            out.append(lines[i])  # ```
            i += 1
            continue

        out.append(line)
        i += 1

    if changed:
        md_path.write_text("\n".join(out))

    return changed


def main() -> int:
    errors: list = []
    fixed_count = [0]
    checked_count = [0]
    per_package = {}

    for package, package_root in PACKAGE_ROOTS.items():
        docc_dir = package_root / "Sources" / package / "Documentation.docc"
        if not docc_dir.is_dir():
            continue
        before = checked_count[0]
        for md_path in sorted(docc_dir.glob("*.md")):
            process_file(md_path, package, errors, fixed_count, checked_count)
        per_package[package] = checked_count[0] - before

    for package, count in per_package.items():
        print(f"{package}: {count} bloques de snippet verificados")

    if fix and fixed_count[0] > 0:
        print(f"--fix: {fixed_count[0]} bloque(s) regenerado(s)")

    if errors:
        print()
        print("Divergencias encontradas:" if not fix else "Quedan errores tras --fix:")
        for error in errors:
            print(f"  - {error}")
        return 1

    print("OK: todos los bloques de snippet en línea coinciden con Snippets/.")
    return 0


sys.exit(main())
PYEOF
