// Arquivo do FiPDF.Escl.Local, derivado do NAPS2 (https://github.com/cyanfish/naps2,
// NAPS2.Sdk/Remoting/Server/ScanJob.cs, versão 8.6.1 / SDK 1.5.0).
// Copyright 2009-2026 NAPS2 Contributors; modificações © 2026 Cauã F. O.
// Licença: GNU LGPL v2.1 ou posterior (veja LICENSE nesta pasta).
// Modificações: origem "Auto" (o driver escolhe entre alimentador e vidro); A4 quando o pedido não
// traz área (o original usava Carta, que corta o fim da folha A4); área limitada ao que o aparelho
// aceita; detalhes de erro em português, em texto simples; sem os auxiliares internos do NAPS2.

using System.Globalization;
using System.Security;
using NAPS2.Images;
using NAPS2.Pdf;
using NAPS2.Scan;
using NAPS2.Scan.Exceptions;

namespace FiPDF.Escl.Local;

/// <summary>Um trabalho de digitalização de um aparelho local (WIA ou TWAIN) servido pelo eSCL.</summary>
public sealed class LocalScanJob : IEsclScanJob
{
    private const string Jpeg = "image/jpeg", Png = "image/png", Pdf = "application/pdf";

    private readonly ScanningContext _scanningContext;
    private readonly ScanController _controller;
    private readonly CancellationTokenSource _cts = new();
    private readonly TaskCompletionSource<bool> _completedTcs = new();
    private readonly IAsyncEnumerator<ProcessedImage> _enumerable;
    private readonly List<ProcessedImage> _allImages = [];
    private readonly List<ProcessedImage> _pdfImages = [];
    private readonly Dictionary<int, double> _lastProgressByPageNumber = new();

    private int _currentPage = 1;
    private Action<StatusTransition>? _statusCallback;
    private Exception? _lastError;
    private Task<bool>? _pausedNextDocumentTask;

    /// <param name="maxWidth">Largura máxima do aparelho, em 1/300 de polegada (para alinhar a área).</param>
    public LocalScanJob(ScanningContext scanningContext, ScanDevice device, LocalScanRequest request, int maxWidth)
    {
        var settings = request.Settings;
        _scanningContext = scanningContext;
        _controller = new ScanController(scanningContext);
        _controller.PageProgress += (_, args) => _lastProgressByPageNumber[args.PageNumber] = args.Progress;
        _controller.PageEnd += (_, args) =>
        {
            _statusCallback?.Invoke(StatusTransition.PageComplete);
            _allImages.Add(args.Image);
        };
        _controller.ScanEnd += (_, args) =>
        {
            if (args.HasError)
            {
                _lastError = args.Error;
            }
            _statusCallback?.Invoke(StatusTransition.ScanComplete);
            _completedTcs.TrySetResult(!args.HasError);
        };

        ContentType = settings.DocumentFormat switch
        {
            Png or Pdf => settings.DocumentFormat,
            _ => Jpeg
        };
        var feeder = settings.InputSource == EsclInputSource.Feeder;
        var options = new ScanOptions
        {
            Device = device,
            Dpi = Math.Max(settings.XResolution, settings.YResolution),
            BitDepth = settings.ColorMode switch
            {
                EsclColorMode.BlackAndWhite1 => BitDepth.BlackAndWhite,
                EsclColorMode.Grayscale8 or EsclColorMode.Grayscale16 => BitDepth.Grayscale,
                _ => BitDepth.Color
            },
            PaperSource = (request.AutoSource, feeder, settings.Duplex) switch
            {
                (_, true, true) => PaperSource.Duplex,
                (_, true, false) => PaperSource.Feeder,
                (true, false, _) => PaperSource.Auto,
                _ => PaperSource.Flatbed
            },
            PageSize = PageSizeFor(settings),
            PageAlign = SnapToAlignment(settings.XOffset, settings.Width, maxWidth > 0 ? maxWidth : EsclInputCaps.DEFAULT_MAX_WIDTH),
            Quality = settings.CompressionFactor ?? ScanOptions.DEFAULT_QUALITY,
            MaxQuality = ContentType == Png
        };

        try
        {
            _enumerable = _controller.Scan(options, _cts.Token).GetAsyncEnumerator();
        }
        catch (Exception)
        {
            _statusCallback?.Invoke(StatusTransition.AbortJob);
            _statusCallback?.Invoke(StatusTransition.ScanComplete);
            throw;
        }
    }

    /// <summary>
    /// Área pedida, em polegadas. Sem área (ou com a área "genérica" de 5000×5000 que o servidor anuncia
    /// quando o driver não informa o tamanho), vai A4: é o papel de quase todo mundo aqui.
    /// </summary>
    private static PageSize PageSizeFor(EsclScanSettings settings)
    {
        if (settings.Width <= 0 || settings.Height <= 0 ||
            (settings.Width >= EsclInputCaps.DEFAULT_MAX_WIDTH && settings.Height >= EsclInputCaps.DEFAULT_MAX_HEIGHT))
        {
            return PageSize.A4;
        }
        return new PageSize(settings.Width / 300m, settings.Height / 300m, PageSizeUnit.Inch);
    }

    private static HorizontalAlign SnapToAlignment(int x, int width, int maxWidth)
    {
        if (x == 0 || width >= maxWidth) return HorizontalAlign.Right;
        var fraction = x / (double) (maxWidth - width);
        return fraction switch
        {
            <= 0.25 => HorizontalAlign.Right,
            >= 0.75 => HorizontalAlign.Left,
            _ => HorizontalAlign.Center,
        };
    }

    public string ContentType { get; }

    public void Cancel()
    {
        _cts.Cancel();
        _statusCallback?.Invoke(StatusTransition.CancelJob);
    }

    public void RegisterStatusTransitionCallback(Action<StatusTransition> callback)
    {
        _statusCallback = callback;
    }

    public async Task<bool> WaitForNextDocument(CancellationToken cancelToken)
    {
        Task<bool> nextDocumentTask;
        lock (this)
        {
            nextDocumentTask = _pausedNextDocumentTask ?? Task.Run(async () =>
            {
                if (ContentType == Pdf)
                {
                    // PDF: todas as páginas num documento só, então espera o fim da digitalização.
                    if (!await _enumerable.MoveNextAsync())
                    {
                        return false;
                    }
                    do
                    {
                        _currentPage++;
                        _pdfImages.Add(_enumerable.Current);
                    } while (await _enumerable.MoveNextAsync());
                    return true;
                }

                if (await _enumerable.MoveNextAsync())
                {
                    _currentPage++;
                    return true;
                }
                return false;
            });
            _pausedNextDocumentTask = null;
        }
        var canceled = new TaskCompletionSource();
        await using (cancelToken.Register(() => canceled.TrySetResult()))
        {
            await Task.WhenAny(nextDocumentTask, canceled.Task);
        }
        lock (this)
        {
            if (!nextDocumentTask.IsCompleted)
            {
                _pausedNextDocumentTask = nextDocumentTask;
                throw new TaskCanceledException();
            }
        }
        return await nextDocumentTask;
    }

    public async Task WriteDocumentTo(Stream stream)
    {
        if (ContentType == Jpeg)
        {
            _enumerable.Current.Save(stream, ImageFileFormat.Jpeg);
            stream.Dispose();
            _enumerable.Current.Dispose();
        }
        if (ContentType == Png)
        {
            _enumerable.Current.Save(stream, ImageFileFormat.Png);
            stream.Dispose();
            _enumerable.Current.Dispose();
        }
        if (ContentType == Pdf)
        {
            var pdfExporter = new PdfExporter(_scanningContext);
            await pdfExporter.Export(stream, _pdfImages);
            stream.Dispose();
            foreach (var image in _pdfImages)
            {
                image.Dispose();
            }
            _pdfImages.Clear();
        }
    }

    public async Task WriteProgressTo(Stream stream)
    {
        var pageEndTcs = new TaskCompletionSource<bool>();
        var streamWriter = new StreamWriter(stream);
        var pageNumber = _currentPage;

        void WriteProgress(double progress)
        {
            streamWriter.WriteLine(progress.ToString(CultureInfo.InvariantCulture));
            streamWriter.Flush();
        }
        void OnPageProgress(object? sender, PageProgressEventArgs e)
        {
            if (e.PageNumber == pageNumber)
            {
                WriteProgress(e.Progress);
            }
        }
        void OnPageEnd(object? sender, PageEndEventArgs e) => pageEndTcs.TrySetResult(true);

        if (_lastProgressByPageNumber.TryGetValue(pageNumber, out var lastPageProgress))
        {
            WriteProgress(lastPageProgress);
        }

        _controller.PageProgress += OnPageProgress;
        _controller.PageEnd += OnPageEnd;
        await Task.WhenAny(pageEndTcs.Task, _completedTcs.Task);
        _controller.PageProgress -= OnPageProgress;
        _controller.PageEnd -= OnPageEnd;
    }

    /// <summary>
    /// Detalhes do erro, em XML simples:
    /// <c>&lt;Erro&gt;&lt;Codigo&gt;…&lt;/Codigo&gt;&lt;Mensagem&gt;…&lt;/Mensagem&gt;&lt;Tecnico&gt;…&lt;/Tecnico&gt;&lt;/Erro&gt;</c>.
    /// </summary>
    public async Task WriteErrorDetailsTo(Stream stream)
    {
        if (_lastError == null) return;
        var (code, message) = Describe(_lastError);
        await using var writer = new StreamWriter(stream);
        await writer.WriteAsync(
            $"<Erro><Codigo>{code}</Codigo><Mensagem>{SecurityElement.Escape(message)}</Mensagem>" +
            $"<Tecnico>{SecurityElement.Escape($"{_lastError.GetType().Name}: {_lastError.Message}")}</Tecnico></Erro>");
    }

    /// <summary>Código e mensagem em português para os erros conhecidos do NAPS2.</summary>
    public static (string Code, string Message) Describe(Exception e) => e switch
    {
        DeviceFeederEmptyException => ("alimentador-vazio", "O alimentador está vazio. Coloque as folhas e tente de novo."),
        DevicePaperJamException => ("papel-atolado", "Papel atolado no scanner. Tire a folha presa e tente de novo."),
        DeviceCoverOpenException => ("tampa-aberta", "A tampa do scanner está aberta. Feche e tente de novo."),
        DeviceBusyException => ("ocupado", "O scanner está ocupado com outra tarefa. Espere um pouco e tente de novo."),
        DeviceWarmingUpException => ("aquecendo", "O scanner ainda está aquecendo. Espere um pouco e tente de novo."),
        DeviceOfflineException => ("desligado", "O scanner não respondeu. Confira se está ligado e conectado."),
        DeviceNotFoundException => ("nao-encontrado", "O scanner não foi encontrado. Ele pode ter sido desconectado."),
        DeviceCommunicationException => ("comunicacao", "A comunicação com o scanner caiu no meio da digitalização."),
        NoFeederSupportException => ("sem-alimentador", "Este scanner não tem alimentador de folhas. Use o vidro."),
        NoDuplexSupportException => ("sem-frente-e-verso", "Este scanner não faz frente e verso sozinho."),
        OperationCanceledException => ("cancelado", "A digitalização foi cancelada."),
        _ => ("desconhecido", "O scanner informou um erro: " + e.Message),
    };

    public void Dispose()
    {
        foreach (var image in _allImages)
        {
            image.Dispose();
        }
    }
}
