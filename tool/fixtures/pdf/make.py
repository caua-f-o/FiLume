"""Gera os PDFs de teste da tarja e dos formulários (python make.py). Precisa do PyMuPDF."""
import fitz

# ---------------------------------------------------------------- tarja.pdf
doc = fitz.open()
p = doc.new_page(width=595, height=842)
p.insert_text((72, 100), "Nome: Maria Souza CPF 123.456.789-00 fim da linha", fontsize=12)
p.insert_text((72, 130), "Linha que fica inteira, sem nada a esconder.", fontsize=12)
p.insert_text((72, 160), "SEGREDO-ALFA", fontsize=12)
p.draw_rect(fitz.Rect(60, 80, 540, 180), color=(0, 0, 0), width=0.8)  # moldura simples
pix = fitz.Pixmap(fitz.csRGB, fitz.IRect(0, 0, 200, 100))
pix.set_rect(pix.irect, (255, 0, 0))
pix.set_rect(fitz.IRect(100, 0, 200, 100), (0, 0, 255))
p.insert_image(fitz.Rect(72, 220, 272, 320), pixmap=pix)  # metade vermelha, metade azul
p.insert_link({"kind": fitz.LINK_URI, "from": fitz.Rect(200, 88, 330, 104), "uri": "https://exemplo.com/123.456.789-00"})
p.add_text_annot((300, 160), "comentário sobre o SEGREDO-ALFA")
# Página deitada (/Rotate 90).
q = doc.new_page(width=595, height=842)
q.insert_text((72, 100), "Página girada com SEGREDO-BETA no meio do texto", fontsize=12)
q.set_rotation(90)
# Página "digitalizada": uma imagem do tamanho da página e texto invisível por cima.
s = doc.new_page(width=595, height=842)
scan = fitz.Pixmap(fitz.csRGB, fitz.IRect(0, 0, 595, 842))
scan.set_rect(scan.irect, (240, 240, 230))
scan.set_rect(fitz.IRect(72, 90, 400, 104), (20, 20, 20))
s.insert_image(s.rect, pixmap=scan)
s.insert_text((72, 100), "SEGREDO-GAMA digitalizado e mais texto", fontsize=12, render_mode=3)
doc.set_metadata({"title": "Ficha de Maria Souza", "author": "Cartório", "subject": "CPF 123.456.789-00"})
doc.save("tarja.pdf", garbage=3, deflate=True)

# ---------------------------------------------------------------- sujo.pdf
doc = fitz.open()
p = doc.new_page(width=595, height=842)
p.insert_text((72, 100), "Documento com bagagem escondida", fontsize=12)
p.insert_link({"kind": fitz.LINK_URI, "from": fitz.Rect(72, 88, 200, 104), "uri": "https://exemplo.com/fica"})
p.add_text_annot((300, 160), "comentario-secreto")
p.add_highlight_annot(fitz.Rect(72, 88, 200, 104))
p.add_file_annot((350, 200), b"conteudo-do-anexo-na-pagina", "na_pagina.txt")
doc.embfile_add("anexo.txt", b"conteudo-do-anexo-solto")
doc.set_toc([[1, "Marcador-secreto", 1]])
doc.set_metadata({"title": "Titulo-secreto", "author": "Autor-secreto", "producer": "Programa-secreto"})
cat = doc.pdf_catalog()
js = doc.get_new_xref()
doc.update_object(js, "<< /S /JavaScript /JS (app.alert\\('script-secreto'\\)) >>")
doc.xref_set_key(cat, "OpenAction", f"{js} 0 R")
doc.xref_set_key(cat, "PieceInfo", "<< /Outro << /Private (dado-privado-secreto) >> >>")
doc.save("sujo.pdf", garbage=3, deflate=True)

# ----------------------------------------------------------- formulario.pdf
doc = fitz.open()
p = doc.new_page(width=595, height=842)
p.insert_text((72, 80), "Ficha de inscrição", fontsize=16)


def field(name, kind, rect, **kw):
    w = fitz.Widget()
    w.field_name = name
    w.field_type = kind
    w.rect = fitz.Rect(*rect)
    w.text_fontsize = 11
    for k, v in kw.items():
        setattr(w, k, v)
    p.add_widget(w)


p.insert_text((72, 118), "Nome:", fontsize=11)
field("nome", fitz.PDF_WIDGET_TYPE_TEXT, (140, 104, 420, 124))
p.insert_text((72, 148), "Cidade:", fontsize=11)
field("cidade", fitz.PDF_WIDGET_TYPE_TEXT, (140, 134, 420, 154), field_value="Canoas")
p.insert_text((72, 178), "Observações:", fontsize=11)
field("obs", fitz.PDF_WIDGET_TYPE_TEXT, (140, 164, 420, 224), field_flags=fitz.PDF_TX_FIELD_IS_MULTILINE)
p.insert_text((72, 248), "Aceito os termos", fontsize=11)
field("aceito", fitz.PDF_WIDGET_TYPE_CHECKBOX, (180, 236, 194, 250))
p.insert_text((72, 278), "Turno:", fontsize=11)
field("turno", fitz.PDF_WIDGET_TYPE_COMBOBOX, (140, 264, 300, 284), choice_values=["Manhã", "Tarde", "Noite"], field_value="Manhã")
p.insert_text((72, 308), "Curso:", fontsize=11)
field("curso", fitz.PDF_WIDGET_TYPE_LISTBOX, (140, 294, 300, 350), choice_values=["Economia", "Direito", "Letras"])
p.insert_text((72, 378), "Pagamento:", fontsize=11)
for i, opt in enumerate(["pix", "boleto"]):
    field("pagamento", fitz.PDF_WIDGET_TYPE_RADIOBUTTON, (160 + i * 80, 366, 174 + i * 80, 380), button_caption=opt)
    p.insert_text((178 + i * 80, 378), opt, fontsize=11)
field("codigo", fitz.PDF_WIDGET_TYPE_TEXT, (140, 400, 300, 420), field_value="A-001", field_flags=fitz.PDF_FIELD_IS_READ_ONLY)
# O PyMuPDF dá o mesmo nome de estado ("None") às duas opções; cada uma ganha o seu.
kids = [w.xref for w in p.widgets() if w.field_name == "pagamento"]
for xref, opt in zip(kids, ["pix", "boleto"]):
    doc.update_object(xref, doc.xref_object(xref).replace("/None", "/" + opt))
parent = int(doc.xref_get_key(kids[0], "Parent")[1].split()[0])
doc.xref_set_key(parent, "V", "/Off")
for xref in kids:
    doc.xref_set_key(xref, "AS", "/Off")
doc.save("formulario.pdf", garbage=3, deflate=True)
# ----------------------------------------------------------- marcadores.pdf
doc = fitz.open()
for i in range(5):
    doc.new_page().insert_text((72, 72), f"Pagina {i + 1}")
doc.set_toc([[1, "Capítulo 1", 1], [2, "Seção 1.1", 2], [1, "Capítulo 2", 3], [2, "Seção 2.1", 4], [1, "Fim", 5]])
doc.save("marcadores.pdf")
print("ok")
