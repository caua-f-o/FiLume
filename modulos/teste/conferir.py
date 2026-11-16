"""Confere o que um módulo gerou.

  python conferir.py docx <arquivo.docx>          (o relatório de teste convertido)
  python conferir.py pdf <arquivo.pdf> <trecho>   (o PDF tem esse trecho de texto)
"""
import sys

kind, path = sys.argv[1], sys.argv[2]
if kind == "docx":
    from docx import Document

    d = Document(path)
    text = "\n".join(p.text for p in d.paragraphs)
    cells = [c.text.strip() for t in d.tables for r in t.rows for c in r.cells]
    problems = []
    if "Relatório de teste" not in text:
        problems.append("sem o título")
    # O parágrafo de várias linhas tem de sair como um parágrafo só.
    if not any("ação e coração" in p.text and "parágrafo só" in p.text for p in d.paragraphs):
        problems.append("o parágrafo foi quebrado em pedaços")
    if not ("Maçã" in cells and "30" in cells):
        problems.append(f"a tabela não virou tabela (células: {cells})")
    if problems:
        print("FALHA:", "; ".join(problems))
        print(text)
        sys.exit(1)
    print(f"OK docx: {len(d.paragraphs)} parágrafos, {len(d.tables)} tabela(s)")
else:
    import fitz

    text = "".join(page.get_text() for page in fitz.open(path))
    if sys.argv[3] not in text:
        print(f"FALHA: o PDF não tem {sys.argv[3]!r}")
        print(text[:500])
        sys.exit(1)
    print("OK pdf:", sys.argv[3])
