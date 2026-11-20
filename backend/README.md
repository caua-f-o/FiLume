# Back do FiPDF (C#)

O Flutter continua cuidando da interface; o trabalho pesado vai para programas
em C# que rodam junto com o app. O plano está no roadmap do FiPDF.

| Projeto | O que faz |
| --- | --- |
| `FiPDF.Scan` | Auxiliar de digitalização: aparelhos WIA e TWAIN pela [NAPS2.Sdk](https://github.com/cyanfish/naps2). |
| `FiPDF.Escl.Local` | Servidor eSCL que só atende este computador (`127.0.0.1`). Derivado do `NAPS2.Escl.Server`, LGPL. |

## A ponte (`FiPDF.Scan servir`)

O FiPDF abre o auxiliar junto com ele. Cada aparelho local (WIA ou TWAIN) ganha um
servidor eSCL em `127.0.0.1`, e o FiPDF digitaliza por ele com o mesmo cliente eSCL que
usa para os aparelhos de rede. Pela ponte só passam comandos; as páginas vêm pelo eSCL.

Ao subir, o auxiliar escreve uma linha JSON no stdout:

```json
{"tipo":"pronto","versao":1,"dispositivos":[{"nome":"...","driver":"wia","id":"wia:...","url":"http://127.0.0.1:PORTA/eSCL"}],"erros":[]}
```

Comandos pelo stdin, uma linha cada (texto puro ou `{"comando":"..."}`):

| Comando | Resposta |
| --- | --- |
| `ping` | `{"tipo":"pong"}` |
| `listar` | `{"tipo":"dispositivos",...}` (mesmo formato do pronto) |
| `atualizar` | procura os aparelhos de novo, refaz os servidores e responde como `listar` |
| `sair` | `{"tipo":"tchau"}` e encerra |

Erros: `{"tipo":"erro","codigo":"...","mensagem":"..."}`.

O auxiliar encerra sozinho quando o stdin fecha ou quando o processo de `--pai PID`
termina, e os processos que ele abre (o `NAPS2.Worker.exe` do TWAIN) morrem junto, por
um Job Object do Windows. O log fica em `%LOCALAPPDATA%\FiLume\logs\fipdf-scan.log`.

**Portas.** Por padrão cada aparelho ganha uma porta livre entre 10001 e 19999, escolhida
na hora (o mesmo padrão do NAPS2.Sdk); a URL certa vai sempre no anúncio, e o FiPDF lembra
os aparelhos pelo `id`, nunca pela URL. `--porta N` fixa as portas (N, N+1, …) para testar
à mão. `--demo` acrescenta um aparelho de demonstração que serve uma página gerada.

## Compilar

Precisa do [SDK do .NET 10](https://dotnet.microsoft.com/download/dotnet/10.0) (LTS, suporte até novembro de 2028).

```
cd backend
dotnet publish FiPDF.Scan -c Release -o publish/FiPDF.Scan
publish\FiPDF.Scan\FiPDF.Scan.exe --versao
publish\FiPDF.Scan\FiPDF.Scan.exe listar
```

A publicação já sai *self-contained* (não exige o .NET instalado) e com o
*trimming* em modo `partial`: só as bibliotecas que declaram suportar isso são
enxugadas, para não quebrar a NAPS2.Sdk, que carrega partes por reflexão.

No GitHub Actions, o build do FiLume compila o back, roda os dois comandos acima
como teste e coloca o resultado na pasta `fipdf-scan` do pacote.

## Licenças

O back é GPL-3.0-or-later, como o FiLume. A NAPS2.Sdk e os pacotes dela são
LGPL-2.1-or-later (© NAPS2 Contributors, Ben Olden-Cooligan); os avisos estão em
`THIRD_PARTY_NOTICES.md`, na raiz.
