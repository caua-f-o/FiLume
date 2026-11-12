# Changelog

Todas as mudanças relevantes do FiLume. As versões seguem o `pubspec.yaml`.
Versões estáveis saem do branch `main`; betas (`-beta.N`) saem do `dev` como pre-release.

## [1.5.0-beta.2] — 2026-11-12

### Adicionado
- **FiLume PDF:** o PDF saiu do app principal e virou um aplicativo dedicado (`FiLume PDF.exe`, na mesma pasta). A bandeja de páginas fica sempre à vista, com uma faixa fixa de ferramentas (adicionar, digitalizar, girar, inverter, endireitar, tamanho da página, excluir) e o painel de cada ferramenta à direita: Organizar, Comprimir, Dividir, Imagens e Senha, todas trabalhando sobre o que está na bandeja.
- **Caixa de salvar:** nome do arquivo, pasta (com atalhos para as pastas guardadas nos Ajustes) e qualidade das imagens, sem abrir o explorador de arquivos toda vez.
- Atalhos na bandeja: Delete exclui, Ctrl+A seleciona tudo, Esc limpa a seleção.

- **Digitalização própria**, sem programas de terceiros: scanners deste computador pelo Windows (WIA) e scanners de rede por AirScan/eSCL (busca automática ou pelo endereço IP). As páginas entram na bandeja uma a uma, enquanto o scanner trabalha.

### Alterado
- O motor do NAPS2 saiu do pacote (cerca de 67 MB a menos). TWAIN fica para depois, se fizer falta.
- Soltar um PDF no FiLume avisa que PDF agora é no app dedicado e oferece abrir; aceitando, o arquivo já entra na bandeja e o FiLume fecha para poupar recursos (se não tiver trabalho em andamento).
- "Unir" e "Imagens → PDF" deixaram de ser ferramentas separadas: a bandeja já faz as duas coisas.

## [1.5.0-beta.1] — 2026-11-11

### Adicionado
- **Módulo Imagem:** ampliar (hiperescalador por IA com Real-ESRGAN, modo clássico e modo pixel art), converter (JPG, PNG, WebP, AVIF, BMP, TIFF), comprimir (por qualidade, tamanho ou porcentagem), redimensionar e girar.
- **Bandeja de páginas** (em "Organizar" do PDF Estúdio), no estilo do NAPS2: mistura PDFs, imagens e digitalizações; visão em miniaturas com controle de zoom ou lista simples; visualizador com zoom; menu de contexto com girar, inverter e endireitar; digitalização por scanner (TWAIN ou WIA).

### Alterado
- Os detalhes geométricos voltaram ao traço simples e agora aparecem em todas as telas (painéis de Vídeo, Áudio, PDF e Imagem).
- Tudo que cai no PDF Estúdio abre na bandeja; imagens soltas na tela inicial vão para o módulo Imagem.
- Fotos de celular giradas (EXIF) agora aparecem com as dimensões certas.

## [1.4.0] — 2026-11-10

### Adicionado
- **Tela inicial:** área para soltar qualquer arquivo (o FiLume abre a ferramenta certa), categorias, arquivos recentes e a fila em andamento.
- **PDF Estúdio:** o PDF ganhou área própria, com entrada dedicada e as ferramentas em cartões.
- **Ajustes:** tema (sistema, claro, escuro), cores (uma por ferramenta, padrão FiLume, cor de destaque do Windows ou paleta Material), tela ao abrir e histórico de recentes.
- **Botão de processo animado:** a seta vira uma barrinha, o enchimento acompanha o progresso real e termina em "Concluído".
- Detalhes geométricos nos cartões, cada um ligado ao que o lugar faz.

### Alterado
- O módulo "Documentos" passou a se chamar PDF Estúdio; a licença do projeto agora é GPL-3.0.

### Corrigido
- Atalhos de valores (10 MB, 25 MB…) apareciam com fundo preto; agora têm contraste correto e o escolhido fica marcado.

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

[1.4.0]: https://github.com/caua-f-o/FiLume/releases/tag/v1.4.0
[1.3.1]: https://github.com/caua-f-o/FiLume/releases/tag/v1.3.1
[1.3.0]: https://github.com/caua-f-o/FiLume/releases/tag/v1.3.0
[1.0.0]: https://github.com/caua-f-o/FiLume/releases/tag/v1.0.1
