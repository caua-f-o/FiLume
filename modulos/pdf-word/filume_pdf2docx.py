"""Módulo "PDF → Word" do FiLume: converte um PDF em DOCX com o pdf2docx.

Uso: filume-pdf2docx <entrada.pdf> <saida.docx>
O andamento sai na saída padrão, uma linha por etapa; em caso de erro, a
última linha começa com "ERRO: " e o programa termina com código 1.
Nada é enviado para a internet.
"""
import logging
import sys


def main():
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace", line_buffering=True)
        except Exception:
            pass
    # O pdf2docx registra o andamento pelo logging, que por padrão vai para a saída de erro.
    sys.stderr = sys.stdout
    if len(sys.argv) == 2 and sys.argv[1] == "--versao":
        import fitz
        print("pdf2docx", getattr(fitz, "VersionBind", "?"))
        return 0
    if len(sys.argv) != 3:
        print("ERRO: uso: filume-pdf2docx <entrada.pdf> <saida.docx>")
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    try:
        from pdf2docx import Converter
        logging.getLogger().setLevel(logging.INFO)
        cv = Converter(src)
        try:
            cv.convert(dst)
        finally:
            cv.close()
    except Exception as e:  # noqa: BLE001 - qualquer falha vira mensagem para o FiLume
        print(f"ERRO: {type(e).__name__}: {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
