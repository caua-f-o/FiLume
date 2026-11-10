# Changelog

Todas as mudanças relevantes do FiLume. As versões seguem o `pubspec.yaml`.

## [1.3.1] — 2026-11-10

### Corrigido
- Comprimir por tamanho final ou por porcentagem (duas passadas) falhava quando o arquivo era aberto por um caminho relativo.

## [1.3.0] — 2026-11-10

### Adicionado
- **Módulo Documentos (PDF):** comprimir, dividir (a cada N páginas, por tamanho, por intervalos ou página a página), unir, organizar páginas com miniaturas, PDF → imagens, imagens → PDF e senha (proteger/remover).
- **Módulo Áudio:** converter (também extrai o áudio de vídeos), comprimir, mixar, dividir e unir.
- **Vídeo:** conversor, cortador, merger, cropper e mux, completando o módulo.
- **Player embutido** nas ferramentas Cortar (botões "Início aqui" / "Fim aqui") e Recortar (área de recorte desenhada sobre o vídeo).
- qpdf e Ghostscript embutidos no pacote, além do FFmpeg.

### Mudado
- **Barra de título integrada:** o degradê do app vai até o topo, com botões próprios de minimizar, maximizar e fechar.
- **Visual Material 3 Expressive:** grupo de botões conectados para escolher a ferramenta, barra de progresso ondulada, indicador de atividade animado, botão principal que muda de forma ao clicar, títulos mais fortes e cantos mais arredondados.
- A ferramenta aberta em cada módulo é lembrada ao trocar de módulo.

### Corrigido
- Comprimir para MKV um vídeo com legendas embutidas em MP4 falhava.
- Vídeos de celular gravados em pé eram lidos com largura e altura trocadas.

## [1.0.0] — 2026-11-09

Primeira versão.

### Adicionado
- **Comprimir vídeo** por qualidade, tamanho final ou porcentagem; H.264, H.265 e AV1, na CPU ou na GPU; limite de resolução e FPS; modo econômico.
- **Dividir vídeo** por tamanho de cada parte, por duração ou em N partes, sem recodificar.
- Fila de tarefas com progresso, tempo restante e cancelamento.
- Arrastar e soltar arquivos, escolha da pasta de saída, tema claro/escuro automático.
- FFmpeg embutido.

[1.3.1]: https://github.com/caua-f-o/FiLume/releases/tag/v1.3.1
[1.3.0]: https://github.com/caua-f-o/FiLume/releases/tag/v1.3.0
[1.0.0]: https://github.com/caua-f-o/FiLume/releases/tag/v1.0.1
