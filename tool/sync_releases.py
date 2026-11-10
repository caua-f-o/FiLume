"""Mantém as releases do GitHub em dia com o CHANGELOG.md.

Uso (no GitHub Actions, com GH_TOKEN):
  python tool/sync_releases.py sync          # renomeia tags antigas e atualiza notas/títulos
  python tool/sync_releases.py notes 1.3.1 notes.md   # grava as notas de uma versão
"""
import json
import re
import subprocess
import sys

REPO_FOOTER = (
    "\n\n---\n**Instalação:** baixe o `FiLume-windows-x64.zip`, extraia e abra o `FiLume.exe`. "
    "FFmpeg, qpdf e Ghostscript já vão juntos."
)

# Releases publicadas antes de as tags seguirem a versão do app.
LEGACY = {"v1.0.1": "v1.0.0", "v1.0.2": "v1.3.0", "v1.0.3": "v1.3.1"}


def changelog():
    text = open("CHANGELOG.md", encoding="utf-8").read()
    out = {}
    for m in re.finditer(r"^## \[([0-9.]+)\][^\n]*\n(.*?)(?=^## \[|^\[[0-9.]+\]:|\Z)", text, re.S | re.M):
        out[m.group(1)] = m.group(2).strip()
    return out


def notes(version, sections):
    body = sections.get(version, "").strip()
    return (body or "Veja o CHANGELOG.md.") + REPO_FOOTER


def gh(*args, check=True):
    r = subprocess.run(["gh", *args], capture_output=True, text=True, encoding="utf-8")
    if check and r.returncode != 0:
        raise SystemExit(f"gh {' '.join(args)} falhou:\n{r.stderr}")
    return r


def releases():
    r = gh("api", "repos/{owner}/{repo}/releases?per_page=100")
    return json.loads(r.stdout)


def sync():
    sections = changelog()
    rels = releases()
    tags = {r["tag_name"]: r for r in rels}

    for old, new in LEGACY.items():
        if old in tags and new not in tags:
            rel = tags[old]
            sha = gh("api", f"repos/{{owner}}/{{repo}}/git/ref/tags/{old}", "--jq", ".object.sha").stdout.strip()
            r = gh("api", "-X", "PATCH", f"repos/{{owner}}/{{repo}}/releases/{rel['id']}",
                   "-f", f"tag_name={new}", "-f", f"target_commitish={sha}", check=False)
            if r.returncode != 0:
                # O token do Actions não cria tags em commits que alteram workflows;
                # a release fica com a tag antiga, mas com título e notas da versão certa.
                print(f"aviso: {old} mantida ({r.stderr.strip()})")
                continue
            gh("api", "-X", "DELETE", f"repos/{{owner}}/{{repo}}/git/refs/tags/{old}", check=False)
            print(f"tag {old} -> {new} ({sha[:7]})")

    rels = releases()
    versions = []
    for rel in rels:
        v = LEGACY.get(rel["tag_name"], rel["tag_name"]).lstrip("v")
        if v not in sections:
            continue
        versions.append((tuple(int(x) for x in v.split(".")), rel))
        title = f"FiLume {v}"
        body = notes(v, sections)
        if rel["name"] != title or (rel["body"] or "").strip() != body.strip():
            gh("api", "-X", "PATCH", f"repos/{{owner}}/{{repo}}/releases/{rel['id']}",
               "-f", f"name={title}", "-f", f"body={body}")
            print(f"notas atualizadas: {v}")
    if versions:
        newest = max(versions, key=lambda x: x[0])[1]
        gh("api", "-X", "PATCH", f"repos/{{owner}}/{{repo}}/releases/{newest['id']}", "-f", "make_latest=true")


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "notes":
        with open(sys.argv[3], "w", encoding="utf-8") as f:
            f.write(notes(sys.argv[2], changelog()))
    elif len(sys.argv) >= 2 and sys.argv[1] == "sync":
        sync()
    else:
        print(__doc__)
