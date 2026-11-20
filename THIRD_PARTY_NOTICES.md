# Avisos de terceiros

O **FiLume** é software livre, distribuído sob a **GNU GPL v3** (veja `LICENSE`).
Copyright (C) 2026 Cauã F. O.

O pacote de download inclui os programas abaixo, **sem modificação**, executados como processos separados.
Cada um segue a sua própria licença, e o código-fonte está disponível nos endereços indicados.

| Programa | Versão | Licença | Código-fonte |
|---|---|---|---|
| FFmpeg / FFprobe (build GPL da BtbN) | n-estável mais recente na data do build | GPL v3 | https://github.com/BtbN/FFmpeg-Builds · https://ffmpeg.org/download.html |
| Ghostscript | 10.08.0 | **AGPL v3** | https://github.com/ArtifexSoftware/ghostpdl-downloads/releases · https://ghostscript.com |
| qpdf | 12.4.2 | Apache 2.0 | https://github.com/qpdf/qpdf |
| Real-ESRGAN ncnn-vulkan (programa e modelos) | 20220424 | BSD 3-Clause | https://github.com/xinntao/Real-ESRGAN · https://github.com/xinntao/Real-ESRGAN-ncnn-vulkan |
| ncnn | — | BSD 3-Clause | https://github.com/Tencent/ncnn |
| PDFium (editor de PDF) | binário de bblanchon/pdfium-binaries | BSD 3-Clause e Apache 2.0 | https://pdfium.googlesource.com/pdfium · https://github.com/bblanchon/pdfium-binaries |
| Visual C++ Runtime | — | Microsoft Redistributable | https://learn.microsoft.com/cpp/windows/redistributing-visual-cpp-files |

Bibliotecas usadas pelo app: media_kit (MIT, com libmpv), window_manager (MIT), desktop_drop (MIT),
file_selector (BSD-3) e path (BSD-3).

## NAPS2 (auxiliar de digitalização)

O `FiPDF.Scan` (pasta `fipdf-scan` do pacote) é escrito em C# e usa as bibliotecas do
[NAPS2](https://github.com/cyanfish/naps2), © 2009-2026 NAPS2 Contributors (Ben Olden-Cooligan),
como bibliotecas:

| Pacote | Licença |
|---|---|
| NAPS2.Sdk, NAPS2.Escl, NAPS2.Images, NAPS2.Images.Gdi, NAPS2.Internals (sem modificação) | **LGPL v2.1 ou posterior** |
| NAPS2.Sdk.Worker.Win32 (o NAPS2.Worker.exe, para o TWAIN) | LGPL v2.1 ou posterior |
| NAPS2.Wia, NAPS2.NTwain (dependências da NAPS2.Sdk) | LGPL v2.1 ou posterior |
| EmbedIO (servidor HTTP do eSCL) | MIT |

O servidor eSCL local (`FiPDF.Escl.Local.dll`) **é uma cópia modificada** do NAPS2.Escl.Server (versão 9.0b1,
SDK 1.6.1), também sob a **LGPL v2.1 ou posterior**: escuta só em `127.0.0.1`, sem HTTPS, sem certificado e
sem anúncio na rede (mDNS). Cada arquivo traz o aviso do que mudou; o código-fonte modificado está na pasta
`backend/FiPDF.Escl.Local` do repositório do FiLume.

O código-fonte está em https://github.com/cyanfish/naps2. Como pede a LGPL, as bibliotecas ficam em
arquivos separados (DLLs) na pasta `fipdf-scan` e podem ser trocadas por outra versão compatível.
O runtime do .NET que vai junto (self-contained) é da Microsoft, licença MIT (https://github.com/dotnet/runtime).

## PdfCraft

As ferramentas **Tarjar**, **Formulário**, **Comentar**, **Medir**, **Verificar**, **Assinar** e **Limpar** do FiPDF, e a preservação dos marcadores ao organizar, foram projetadas com base no
[PdfCraft](https://github.com/storytold/pdfcraft) (© 2026 ArtCraft Team e colaboradores do PdfCraft,
licença MIT ou Apache 2.0): de lá vieram o conjunto de recursos e as regras de comportamento (o que a
tarja remove, a conferência depois de gravar, a recusa em entregar o arquivo se algo sobrar, os tipos
de campo de formulário, os tipos de comentário, as verificações de acessibilidade e de PDF/A). O código do FiPDF é próprio, escrito em Dart sobre o PDFium e o qpdf; nenhum
arquivo, ícone, fonte, nome ou logotipo do PdfCraft ou da ArtCraft é distribuído com o FiLume.

```
MIT License

Copyright (c) 2026 ArtCraft Team and the PdfCraft contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Oferta de código-fonte

O código do FiLume está em https://github.com/caua-f-o/FiLume. Para obter o código-fonte
correspondente ao Ghostscript, ao FFmpeg ou ao qpdf incluídos neste pacote, use os links da tabela acima
ou abra uma issue no repositório do FiLume que o código será indicado.
