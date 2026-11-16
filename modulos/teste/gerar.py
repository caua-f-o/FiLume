"""Gera os arquivos usados para testar os módulos depois de montados.

Uso: python gerar.py <pasta>
"""
import os
import sys

import fitz
from docx import Document
from openpyxl import Workbook
from pptx import Presentation

out = sys.argv[1]
os.makedirs(out, exist_ok=True)

# PDF com título, parágrafo de várias linhas e tabela.
doc = fitz.open()
page = doc.new_page()
page.insert_text((72, 90), "Relatório de teste", fontsize=20, fontname="helv")
page.insert_textbox(
    fitz.Rect(72, 110, 520, 200),
    "Primeiro parágrafo com ação e coração, comprido o bastante para ocupar mais de uma linha "
    "na página e mostrar se o conversor junta as linhas num parágrafo só.",
    fontsize=11, fontname="helv",
)
rows = [("Produto", "Quantidade"), ("Maçã", "12"), ("Pão", "30")]
y = 220
for a, b in rows:
    for x, text in ((72, a), (252, b)):
        page.draw_rect(fitz.Rect(x, y, x + 180, y + 22), color=(0, 0, 0), width=0.7)
        page.insert_text((x + 6, y + 15), text, fontsize=11, fontname="helv")
    y += 22
doc.save(os.path.join(out, "relatório.pdf"))

d = Document()
d.add_heading("Carta", 1)
d.add_paragraph("Primeiro parágrafo com ação e coração.")
d.save(os.path.join(out, "carta.docx"))

wb = Workbook()
ws = wb.active
ws.append(["Produto", "Quantidade"])
ws.append(["Maçã", 12])
ws.append(["Pão", 30])
wb.save(os.path.join(out, "planilha.xlsx"))

pr = Presentation()
slide = pr.slides.add_slide(pr.slide_layouts[0])
slide.shapes.title.text = "Apresentação de teste"
pr.save(os.path.join(out, "slides.pptx"))
print("arquivos de teste em", out)
