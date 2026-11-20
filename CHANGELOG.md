# Changelog

Todas as mudanças relevantes do FiLume. As versões seguem o `pubspec.yaml`.
Versões estáveis saem do branch `main`; betas (`-beta.N`) saem do `dev` como pre-release.

## [1.5.0-beta.14] — 2026-11-20

### Alterado
- FiPDF → **Digitalizar**: os scanners deste computador agora passam pelo **FiPDF.Scan**, um auxiliar em C# que vem junto (pasta `fipdf-scan`) e usa as bibliotecas do NAPS2. Ele traz o **TWAIN** além do WIA, e cada aparelho é servido por eSCL só para este computador (`127.0.0.1`, nada fica exposto na rede). O FiPDF digitaliza por ele com o mesmo caminho dos scanners de rede.
- Uma lista só de aparelhos, com a etiqueta de cada um: **Rede**, **Local · WIA** ou **Local · TWAIN**. O botão de atualizar procura nos dois lugares ao mesmo tempo; o endereço (IP) de um scanner de rede pode ser digitado como antes.
- Vidro, alimentador e frente e verso de cada aparelho local vêm do driver; o **Automático** deixa o próprio driver escolher (alimentador com papel, senão vidro). Sem área definida, a folha é A4.
- Erros dos aparelhos locais aparecem em português (alimentador vazio, papel atolado, tampa aberta…).
- O auxiliar abre junto com o FiPDF e fecha com ele. Se travar ou cair, o FiPDF o reinicia sozinho e avisa na tela de digitalização. O registro fica em `%LOCALAPPDATA%\FiLume\logs\fipdf-scan.log`.
- Se o auxiliar não estiver disponível, os scanners WIA continuam funcionando pelo caminho antigo.

### Corrigido
- Digitalização em rede: o pedido ao scanner vai com o tamanho declarado (alguns aparelhos não liam o pedido enviado em partes).

## [1.5.0-beta.13] — 2026-11-16

### Alterado
- O **FiLume PDF** passa a se chamar **FiPDF** (`FiPDF.exe`). O executável com o nome antigo continua na pasta, para os atalhos que já existem.

### Adicionado
- FiPDF → **Tarjar**: esconde informações para valer. O texto, as imagens, os links e os comentários sob a tarja são apagados do arquivo, não só cobertos por um retângulo.
  - Marque áreas com o mouse ou procure um texto (nome, CPF) para tarjar todas as ocorrências do documento, inclusive em páginas giradas e em digitalizações com OCR.
  - O que está só em parte sob a tarja (o resto de uma linha, uma foto) é refeito como imagem, já com a tarja, para não sobrar nada legível por baixo.
  - Depois de gravar, o arquivo é reaberto e conferido: se ainda houver texto sob alguma tarja, nada é entregue.
  - Opção de apagar título, autor e outros dados do arquivo, e aviso quando o texto tarjado ainda aparece em outro lugar (comentários, marcadores).
- FiPDF → **Formulário**: preenche campos de texto, caixas de marcar, botões de opção e listas, com acentos, e pode "achatar" o resultado (os valores viram parte da página).
- FiPDF → **Comentar**: marca-texto, sublinhado, riscado, notas e retângulos, com autor e data. Mostra os comentários que o PDF já tem, apaga os que não servem e exporta a lista em texto.
- FiPDF → **Medir**: distâncias e áreas sobre a página, em mm, cm, m, polegadas ou pontos, com escala para plantas e mapas. Não altera o arquivo.
- FiPDF → **Verificar**: confere a acessibilidade (tags, idioma, título, páginas sem texto, descrição das imagens, marcadores) e os pontos principais do PDF/A (fontes embutidas, metadados, perfil de cor, scripts, mídia), com a indicação de como resolver. É uma verificação, não uma certificação.

- FiPDF → **Assinar**: confere as assinaturas digitais (se o documento mudou depois de assinado, se recebeu acréscimos, quem assinou, se o certificado é reconhecido pelo computador) e assina com o seu certificado: arquivo .pfx/.p12 ou o instalado no Windows, inclusive de cartão e token. Carimbo visível opcional, com nome e data. Depois de assinar, o arquivo é conferido antes de ser entregue.
- FiPDF → **Limpar**: tira o que não aparece na página mas vai junto com o arquivo (autor e programa de origem, scripts, anexos, miniaturas e dados ocultos e, se quiser, comentários e marcadores). Aceita vários PDFs de uma vez.

### Melhorado
- FiPDF → Organizar e Unir: os marcadores (sumário lateral) agora vão junto para o PDF novo, apontando para as páginas na posição nova. Antes eles se perdiam.
- FiPDF → Comprimir: quando a compressão normal deixaria o arquivo maior (imagens já leves), o FiPDF tenta reorganizar só a estrutura, sem perda de qualidade, em vez de desistir.

### Créditos
- As ferramentas novas foram projetadas com base no [PdfCraft](https://github.com/storytold/pdfcraft) (ArtCraft Team e colaboradores, MIT ou Apache 2.0); o código é próprio. Detalhes em `THIRD_PARTY_NOTICES.md`.

## [1.5.0-beta.12] — 2026-11-16

### Alterado
- Atualização: não é mais preciso fechar os outros programas do FiLume na mão. Ao instalar, o atualizador fecha sozinho o que estiver aberto na pasta (os outros aplicativos e qualquer processo auxiliar que tenha ficado para trás), troca os arquivos e reabre. O aviso mostra antes o que será fechado.

## [1.5.0-beta.11] — 2026-11-16

### Adicionado
- **Módulos** (Ajustes → Módulos, nos três aplicativos): ferramentas grandes que nem todo mundo usa deixam de pesar no pacote. Você baixa só as que quiser, direto do repositório; o FiLume confere o arquivo antes de instalar. Os módulos ficam numa pasta própria e continuam instalados quando o FiLume é atualizado. Dá para atualizar e remover cada um.
  - **PDF → Word**: conversor dedicado que remonta parágrafos, tabelas e imagens num documento do Word editável, sem precisar de Word nem LibreOffice.
  - **Documentos do Office**: converte Word, Excel e PowerPoint (e os formatos abertos) entre si e para PDF sem ter pacote de escritório instalado.
- Conversor: quando falta um módulo para os arquivos da lista, ele é oferecido ali mesmo, com o download em um clique. PDF → Word mostra o andamento página a página.

### Corrigido
- Conversor: com Word 2007 ou 2010 instalado, PDF → Word era oferecido e falhava (esses Words não abrem PDF). Agora a opção só aparece quando há como converter, e o aviso explica o que falta.
- Conversor: Word 2007 não conseguia gravar nenhum formato (usava um comando que só existe do Word 2010 em diante).

## [1.5.0-beta.10] — 2026-11-16

### Adicionado
- **FiLume Conversor**: novo aplicativo dedicado (`FiLume Conversor.exe`, na mesma pasta) que leva qualquer arquivo para outro formato. Solte arquivos de tipos diferentes (ou pastas inteiras) e cada um ganha a sua lista de formatos:
  - **Fotos**: JPG, PNG, WebP, AVIF, JPEG XL, TIFF, BMP, GIF, ICO e PDF, lendo também **HEIC/HEIF** (iPhone), PSD, TGA e JPEG 2000. Fotos HEIC são montadas com o tamanho e a rotação certos. Gravar em HEIC aparece quando o Windows tem o codificador HEVC.
  - **Vídeos**: MP4, MKV, MOV, WebM, AVI e GIF animado, ou só o áudio. Quando só o formato muda, o vídeo é copiado sem perda.
  - **Áudios**: MP3, M4A, Opus, OGG, FLAC, WAV, AIFF, AC-3 e WMA.
  - **PDF**: para imagens (JPG/PNG), texto e Word.
  - **Word, Excel e PowerPoint** (e OpenDocument, RTF, HTML, CSV): para PDF e entre si, usando o LibreOffice ou o Microsoft Office instalado no computador, sem abrir janela. Sem nenhum dos dois, ficam texto → PDF e Word → texto.
  - **Legendas**: SRT, WebVTT e ASS (legendas antigas com acento errado são corrigidas).
  - Opções de qualidade, tamanho, resolução, juntar várias imagens num PDF só e pasta de saída. Nada é sobrescrito.
- **Atualização pelo próprio app** (nos três aplicativos): consulta as versões publicadas no GitHub, mostra o que mudou, baixa, confere o arquivo, troca os arquivos da pasta e reabre. Nos Ajustes dá para escolher o canal **Estável** ou **Beta**, desligar a consulta ao abrir e procurar na hora.

### Alterado
- A tela inicial do FiLume e a barra lateral do FiLume PDF ganharam atalho para o Conversor (o antigo "Arquivos – em breve").

## [1.5.0-beta.9] — 2026-11-13

### Adicionado
- Comparador: botão **Limpar**, que tira os dois arquivos (e o resultado) de uma vez.
- Editor: aviso ao abrir PDFs em que as letras são desenhos e não texto (comum no "Microsoft Print to PDF").

### Corrigido
- Editor: em PDFs que dividem o desenho da página em vários pedaços (como os do "Microsoft Print to PDF"), editar empurrava partes da página para o lado e fazia o cabeçalho sumir. Agora a página é juntada num pedaço só antes de abrir no editor, sem mudar nada na aparência.

## [1.5.0-beta.8] — 2026-11-13

### Corrigido
- Editor: texto novo ou editado podia trocar letras acentuadas (õ virava ı, ã virava ª) quando a página já usava uma fonte padrão de mesmo nome, não embutida e com outra codificação. Agora o editor escreve com a própria fonte da página quando ela tem as letras e, se não tiver, com a equivalente do Windows (Arial, Times New Roman ou Courier New) embutida no arquivo.
- O teste do editor com o PDFium passou a bloquear a publicação, como devia.

## [1.5.0-beta.7] — 2026-11-13

### Adicionado
- **Editor de PDF** (ferramenta Editar), no estilo de um editor de texto:
  - dois cliques num parágrafo para mudar o que está escrito; a quebra de linha se refaz dentro da largura do parágrafo;
  - o texto mantém a fonte original quando ela tem as letras necessárias; senão, entra uma fonte padrão parecida, com aviso;
  - fonte, tamanho, negrito, itálico, cor e alinhamento, para texto novo e para parágrafos existentes;
  - mover, redimensionar e excluir textos, imagens e desenhos que já estavam no PDF;
  - inserir texto, imagem, retângulo, elipse, linha, seta, marca-texto, corretivo, traço à mão livre e assinatura desenhada;
  - desfazer e refazer sem limite, zoom e páginas giradas tratadas como aparecem na tela.
- O editor usa o PDFium (o motor de PDF do Chrome) embutido no pacote. Tudo roda neste computador; nada é enviado para fora.

## [1.5.0-beta.6] — 2026-11-12

### Adicionado
- **Assinatura digital** no FiLume PDF: PDFs assinados são identificados ao entrar na bandeja, com quem assinou, data, motivo e local (botão de detalhes no painel).
- Salvar em Organizar sem mexer nas páginas gera uma cópia idêntica, com a assinatura valendo.
- **Comparador de PDFs** (ferramenta Comparar): emparelha as páginas dos dois arquivos, achando as inseridas e as removidas; marca na página o que mudou; e lista as palavras que saíram e as que entraram. Funciona com PDFs digitais, digitalizações e fotos (com folga para ruído, brilho e folha fora do lugar; em páginas sem texto, lê por OCR). Visão lado a lado com zoom sincronizado e relatório em PDF.
- **Compressão avançada** no Comprimir (seção "Avançado", sem ferramenta nova): tamanho máximo em MB (o compressor acha sozinho a melhor qualidade que cabe), resolução e qualidade das imagens à escolha, e preto e branco puro (1 bit) para documentos de texto escaneados. Toda compressão ganhou ainda uma passada final sem perda na estrutura do PDF.
- Qualquer operação que invalidaria a assinatura avisa antes e oferece anexar o original assinado dentro do novo PDF, para quem receber poder conferir.

### Corrigido
- Faixa de ferramentas em janela estreita (monitor em pé): os botões encolhem e passam para a linha de baixo quando não cabem, em vez de ficarem escondidos.

## [1.5.0-beta.5] — 2026-11-12

### Alterado
- Alimentador pela rede: quando o scanner informa que o alimentador está vazio, o FiLume PDF espera até 12 segundos pelo sensor antes de pedir a digitalização, e o aviso deixa claro que a recusa veio do próprio aparelho. O diagnóstico agora traz o pedido enviado e o estado do scanner depois de cada recusa.

## [1.5.0-beta.4] — 2026-11-12

### Alterado
- Faixa de ferramentas do FiLume PDF no estilo do NAPS2: botões grandes com o ícone em cima e o nome embaixo, em grupos separados por uma linha.

### Corrigido
- Alimentador em scanners de rede que respondiam "sem papel" com papel: o FiLume PDF não confia mais só no aviso do scanner. Ele faz o pedido de qualquer jeito, insiste enquanto o aparelho ainda puxa a primeira folha, consulta o estado do trabalho e tenta formas mais simples do pedido antes de desistir.
- Quando a digitalização falha, a janela mostra o passo a passo da conversa com o scanner, com botão para copiar o diagnóstico.

## [1.5.0-beta.3] — 2026-11-12

### Adicionado
- **OCR** no FiLume PDF (ligado por padrão, botão na faixa de ferramentas): ao salvar, páginas sem texto (digitalizações, fotos) ganham uma camada de texto invisível, e o PDF passa a aceitar busca, seleção e cópia. Usa o reconhecimento de texto do próprio Windows 10/11, no idioma do sistema; páginas que já têm texto ficam como estão.
- Digitalização: origem **Automático** (alimentador se tiver papel, senão vidro) e **Frente e verso** como caixa de marcar, com cada lado virando uma página.
- A janela de digitalizar lembra as opções usadas e os scanners já encontrados, sem procurar de novo a cada abertura (o botão de atualizar procura).

### Corrigido
- Digitalização pelo alimentador: o pedido agora é montado a partir do que o scanner informa aceitar (resolução, cor, área, formato); nos drivers novos do Windows, o alimentador é usado como item próprio. Scanner sem alimentador ou sem papel avisa com clareza.

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
