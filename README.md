# FiLume

Compressor e divisor de vídeos para desktop, feito em Flutter (Material 3). *File* + *lume*, de vagalume.

| Módulo | Ferramentas |
| --- | --- |
| Vídeo | **Compressor** e **splitter** prontos · conversor, cortador, merger, cropper e mux em breve |
| Áudio, Imagem, Documentos | em breve |

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
lib/core/state.dart      estado do app e fila de tarefas
lib/ui/                  telas (Material 3)
tool/patch_windows.dart  título, ícone e tamanho mínimo da janela
tool/core_test.dart      teste do núcleo sem interface
```

Para usar outro FFmpeg, defina a variável de ambiente `FILUME_FFMPEG_DIR` com a pasta que contém `ffmpeg.exe` e `ffprobe.exe`.

## Licenças

O FFmpeg embutido é o build GPL de <https://github.com/BtbN/FFmpeg-Builds>, distribuído como executável separado.
