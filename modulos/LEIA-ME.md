# Módulos do FiLume

Ferramentas grandes que só parte das pessoas usa. Não entram no pacote do
FiLume: o programa baixa cada uma quando a pessoa pede (Ajustes → Módulos, ou
a oferta que aparece no Conversor) e instala em `%LOCALAPPDATA%\FiLume\modulos`.

| Pasta | Módulo | O que tem dentro |
| --- | --- | --- |
| `pdf-word` | PDF → Word | [pdf2docx](https://github.com/ArtifexSoftware/pdf2docx) (sobre o PyMuPDF, licença AGPL-3.0) empacotado com o PyInstaller |
| `documentos` | Documentos do Office | [LibreOffice](https://www.libreoffice.org) (MPL-2.0) sem ajuda, galerias, dicionários e idiomas que a conversão não usa |

## Como são publicados

O workflow `.github/workflows/modulos.yml` roda no Windows a cada mudança nesta
pasta (branch `dev`): monta cada módulo, **testa uma conversão de verdade com o
pacote já pronto** e publica os ZIPs na release fixa `modulos`, junto com o
`modulos.json` (versão, tamanho e resumo SHA-256 de cada pacote — o FiLume
confere os dois antes de instalar).

Um módulo só é montado de novo quando o número em `versao.txt` muda.
