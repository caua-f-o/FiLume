// Arquivo do FiPDF.Escl.Local, derivado do NAPS2 (https://github.com/cyanfish/naps2,
// NAPS2.Escl.Server, versão 9.0b1 / SDK 1.6.1).
// Copyright 2009-2026 NAPS2 Contributors; modificações © 2026 Cauã F. O.
// Licença: GNU LGPL v2.1 ou posterior (veja LICENSE nesta pasta).
// Modificações: escuta só em 127.0.0.1 (nunca na rede), sem HTTPS, sem certificado próprio e sem anúncio mDNS; expõe as portas usadas.

using System.Net;
using System.Security.Cryptography.X509Certificates;
using EmbedIO;
using EmbedIO.WebApi;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace FiPDF.Escl.Local;

/// <summary>
/// Servidor eSCL que só atende este computador.
/// <para>
/// Diferente do <c>NAPS2.Escl.Server.EsclServer</c>: escuta em <c>127.0.0.1</c> (o original escuta em
/// todas as placas de rede), não anuncia os aparelhos na rede local por mDNS, não sobe HTTPS e não gera
/// certificado. Como só o próprio computador alcança o endereço, o Firewall do Windows não pergunta nada
/// e não é preciso permissão de administrador.
/// </para>
/// </summary>
public sealed class LocalEsclServer : IEsclServer
{
    static LocalEsclServer()
    {
        Swan.Logging.Logger.NoLogging();
    }

    private readonly List<DeviceContext> _devices = new();
    private readonly object _lock = new();
    private bool _started;
    private CancellationTokenSource? _cts;

    /// <summary>Endereço em que o servidor escuta. Só aceita endereços de loopback.</summary>
    public IPAddress Address { get; }

    public LocalEsclServer(IPAddress? address = null)
    {
        Address = address ?? IPAddress.Loopback;
        if (!IPAddress.IsLoopback(Address))
        {
            throw new ArgumentException("O servidor eSCL do FiPDF só escuta neste computador (loopback).", nameof(address));
        }
    }

    /// <summary>
    /// Sem efeito: este servidor é sempre HTTP em loopback. Fica por exigência da interface
    /// <see cref="IEsclServer"/>; políticas que pedem HTTPS são recusadas em <see cref="Start"/>.
    /// </summary>
    public EsclSecurityPolicy SecurityPolicy { get; set; } = EsclSecurityPolicy.ServerDisableHttps;

    /// <summary>Sem efeito (sem HTTPS).</summary>
    public X509Certificate2? Certificate { get; set; }

    public ILogger Logger { get; set; } = NullLogger.Instance;

    /// <summary>Aparelhos registrados, na ordem em que foram adicionados, com a porta em uso (0 = ainda não subiu).</summary>
    public IReadOnlyList<(EsclDeviceConfig Config, int Port, string? Error)> Devices
    {
        get
        {
            lock (_lock)
            {
                return _devices.Select(d => (d.Config, d.Running ? d.Config.Port : 0, d.Error)).ToList();
            }
        }
    }

    /// <summary>Endereço base eSCL de um aparelho (ex.: http://127.0.0.1:12345/eSCL).</summary>
    public string UrlFor(int port) => $"http://{Address}:{port}/eSCL";

    public void AddDevice(EsclDeviceConfig deviceConfig)
    {
        var ctx = new DeviceContext(deviceConfig);
        bool started;
        lock (_lock)
        {
            _devices.Add(ctx);
            started = _started;
        }
        if (started)
        {
            ctx.StartTask = Task.Run(() => StartServer(ctx));
        }
    }

    public void RemoveDevice(EsclDeviceConfig deviceConfig)
    {
        DeviceContext? ctx;
        lock (_lock)
        {
            ctx = _devices.FirstOrDefault(d => d.Config == deviceConfig);
            if (ctx != null) _devices.Remove(ctx);
        }
        ctx?.Stop();
    }

    public async Task Start()
    {
        if (SecurityPolicy.HasFlag(EsclSecurityPolicy.ServerRequireHttps) ||
            SecurityPolicy.HasFlag(EsclSecurityPolicy.ServerRequireTrustedCertificate))
        {
            throw new EsclSecurityPolicyViolationException(
                $"O servidor eSCL local não usa HTTPS (política pedida: {SecurityPolicy})");
        }
        List<DeviceContext> devices;
        lock (_lock)
        {
            if (_started) return;
            _started = true;
            _cts = new CancellationTokenSource();
            devices = _devices.ToList();
        }
        foreach (var d in devices)
        {
            d.StartTask = Task.Run(() => StartServer(d));
        }
        await Task.WhenAll(devices.Select(d => d.StartTask!));
    }

    private async Task StartServer(DeviceContext ctx)
    {
        var cancelToken = CancellationTokenSource.CreateLinkedTokenSource(_cts!.Token, ctx.Cts.Token).Token;
        try
        {
            // Porta pedida (0 = aleatória entre 10001 e 19999); se estiver ocupada, tenta outras.
            await PortFinder.RunWithSpecifiedOrRandomPort(ctx.Config.Port, async port =>
            {
                await StartServer(ctx, port, cancelToken);
                ctx.Config.Port = port;
            }, cancelToken);
            ctx.Running = !cancelToken.IsCancellationRequested;
        }
        catch (Exception ex)
        {
            ctx.Error = ex.Message;
            Logger.LogError(ex, "Não foi possível subir o servidor eSCL local de {Device}", ctx.Config.Capabilities.MakeAndModel);
        }
    }

    private async Task StartServer(DeviceContext ctx, int port, CancellationToken cancelToken)
    {
        var url = $"http://{Address}:{port}/";
        ctx.ServerState = new EsclServerState(Logger);
        // Modo EmbedIO: o próprio EmbedIO abre o socket (sem o http.sys do Windows), então não
        // é preciso "netsh http add urlacl" nem permissão de administrador.
        var server = new WebServer(o => o
                .WithMode(HttpListenerMode.EmbedIO)
                .WithUrlPrefix(url))
            .HandleUnhandledException(UnhandledServerException);
        server.WithWebApi("/eSCL",
            m => m.WithController(() =>
                new EsclApiController(ctx.Config, ctx.ServerState, SecurityPolicy, Logger)));
        // Volta quando o servidor está escutando, ou com o erro (porta ocupada etc.).
        await server.StartAsync(cancelToken);
        ctx.Server = server;
    }

    private Task UnhandledServerException(IHttpContext ctx, Exception ex)
    {
        Logger.LogError(ex, "Erro no servidor eSCL local");
        return Task.CompletedTask;
    }

    public async Task Stop()
    {
        List<DeviceContext> devices;
        lock (_lock)
        {
            if (!_started) return;
            _started = false;
            devices = _devices.ToList();
        }
        _cts?.Cancel();
        foreach (var d in devices) d.Stop();
        await Task.WhenAll(devices.Select(d => d.StartTask ?? Task.CompletedTask).Select(t => t.ContinueWith(_ => { })));
        _cts = null;
    }

    public void Dispose()
    {
        Stop().GetAwaiter().GetResult();
    }

    private sealed class DeviceContext(EsclDeviceConfig config)
    {
        public EsclDeviceConfig Config { get; } = config;
        public CancellationTokenSource Cts { get; } = new();
        public Task? StartTask { get; set; }
        public WebServer? Server { get; set; }
        public EsclServerState? ServerState { get; set; }
        public bool Running { get; set; }
        public string? Error { get; set; }

        public void Stop()
        {
            Running = false;
            try { Cts.Cancel(); } catch { }
            try { Server?.Dispose(); } catch { }
        }
    }
}
