# FiLume

Compressor e divisor de vídeos para desktop, feito em Flutter (Material 3). *File* + *lume*, de vagalume.

| Módulo | Ferramentas |
| --- | --- |
| Vídeo | Compressor, splitter, conversor, cortador, merger, cropper e mux — **todos prontos** |
| Áudio | Conversor, compressor, mixer, splitter e merger — **todos prontos** |
| Documentos | PDF: comprimir, dividir, unir, organizar páginas, PDF ↔ imagens e senha — **prontos** |
| Imagem | em breve |

## Como obter o FiLume.exe

O app é compilado pelo GitHub Actions; não precisa instalar Flutter, Python nem abrir terminal.

1. Crie um repositório em <https://github.com/new> (pode ser privado).
2. Na página do repositório, clique em **uploading an existing file** e arraste **todo o conteúdo desta pasta**, incluindo a pasta `.github`. Confirme em **Commit changes**.
3. Abra a aba **Actions** e espere o build "Build FiLume (Windows)" terminar (uns 10 minutos).
4. Em **Releases**, baixe `FiLume-windows-x64.zip`, extraia e abra `FiLume.exe`. O FFmpeg já vai dentro da pasta `ffmpeg`.

Cada novo envio para a branch principal gera uma versão nova em Releases.

## O que ele faz

**Comprimir**
- Por qualidade, por tamanho final (MB) ou por porcentagem do original.
- H.264, H.265 e AV1, na CPU ou na GPU (NVIDIA, Intel ou AMD, detectadas sozinhas).
- Limite de resolução e FPS, escolha de áudio e de formato (MP4, MKV, MOV).
- Duas passadas para acertar o tamanho-alvo; modo econômico para usar menos CPU e memória.

**Dividir**
- Por tamanho máximo de cada parte, por duração ou por número de partes.
- Sem recodificar: rápido e sem perda. Os cortes caem em keyframes.
- Por tamanho, o vídeo é analisado antes para nenhuma parte passar do limite.

**Converter**
- MP4, MKV, MOV ou WebM. Se os codecs já cabem no formato, só troca o contêiner (segundos, sem perda); senão recodifica só o necessário.

**Cortar**
- Mantém um trecho (início e fim). Rápido (sem recodificar, cai no keyframe) ou exato (recodifica o trecho).

**Unir**
- Junta os vídeos na ordem da lista. Mesmo formato: sem recodificar. Formatos diferentes: recodifica no formato do primeiro.

**Recortar**
- Por proporção (16:9, 9:16, 1:1...), por margens em pixels ou removendo barras pretas automaticamente, com prévia.

**Mux**
- Troca, adiciona ou remove o áudio e adiciona legenda (.srt, .ass, .vtt) sem recodificar o vídeo.

**Áudio**
- Converter (MP3, M4A, Opus, OGG, FLAC, WAV), também extraindo o áudio de vídeos.
- Comprimir por bitrate, tamanho final ou porcentagem.
- Mixar vários áudios ao mesmo tempo, com volume por faixa.
- Dividir por tamanho, duração ou número de partes, sem recodificar.
- Unir na ordem da lista (sem recodificar quando os formatos batem).

**Documentos (PDF)**
- Comprimir em quatro níveis (reduz a resolução das imagens), com opção de tons de cinza.
- Dividir a cada N páginas, por tamanho máximo em MB, por intervalos ou uma página por arquivo.
- Unir vários PDFs na ordem da lista.
- Organizar: mesa com miniaturas para arrastar, girar, excluir e misturar páginas de vários PDFs.
- PDF → imagens (JPG/PNG) e imagens → PDF.
- Proteger com senha ou remover a senha (sabendo a atual).

**Prévia com player**
- Cortar e Recortar têm um player embutido: marque início e fim no ponto em que o vídeo está, e veja a área de recorte por cima da imagem.

## Vídeos longos e pesados

- O app nunca carrega o vídeo na memória: quem lê e grava é o FFmpeg, em streaming.
- A fila roda uma tarefa por vez, então CPU, RAM e disco ficam previsíveis.
- A análise para dividir por tamanho guarda só uma tabela pequena de keyframes, seja o vídeo de 100 MB ou de 100 GB.
- Fechar a janela ou cancelar encerra o FFmpeg e apaga o arquivo incompleto.

## Estrutura

```
lib/core/ffmpeg.dart     localizar FFmpeg, ler metadados, rodar processos
lib/core/compress.dart   opções e comando de compressão
lib/core/split.dart      opções e planejamento dos cortes
lib/core/convert.dart    conversor · trim.dart cortador · merge.dart merger
lib/core/crop.dart       cropper · mux.dart mux
lib/core/streams.dart    compatibilidade de codecs/contêineres e recodificação
lib/core/audio.dart      ferramentas de áudio
lib/core/pdf.dart        ferramentas de PDF · pdf_workspace.dart organizador e miniaturas
lib/ui/modules.dart      lista de ferramentas de cada módulo
lib/ui/expressive.dart   componentes no estilo Material 3 Expressive
lib/core/state.dart      estado do app e fila de tarefas
lib/ui/                  telas (Material 3)
tool/patch_windows.dart  título, ícone e tamanho mínimo da janela
tool/core_test.dart      teste do núcleo sem interface
```

Para usar outro FFmpeg, defina a variável de ambiente `FILUME_FFMPEG_DIR` com a pasta que contém `ffmpeg.exe` e `ffprobe.exe`.

## Licenças

O FFmpeg embutido é o build GPL de <https://github.com/BtbN/FFmpeg-Builds>, distribuído como executável separado.

O módulo Documentos usa o qpdf (Apache 2.0) e o Ghostscript (AGPL v3), também como executáveis separados, baixados no build por `tool/patch_windows.dart` para a pasta `pdftools`.
