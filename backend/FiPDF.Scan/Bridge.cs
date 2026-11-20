// FiPDF.Scan — Copyright (C) 2026 Cauã F. O. — GPL-3.0-or-later.
using System.Diagnostics;
using System.Text.Json;
using FiPDF.Escl.Local;
using Microsoft.Extensions.Logging;
using NAPS2.Remoting.Server;
using NAPS2.Scan;

namespace FiPDF.Scan;

internal sealed record BridgeOptions(int BasePort, int? ParentPid, bool Demo)
{
    public static BridgeOptions Parse(string[] args)
    {
        int port = 0;
        int? parent = null;
        var demo = false;
        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i].TrimStart('-').ToLowerInvariant())
            {
                case "porta" when i + 1 < args.Length && int.TryParse(args[i + 1], out var p) && p is > 0 and < 65536:
                    port = p;
                    i++;
                    break;
                case "demo":
                    demo = true;
                    break;
                case "pai" when i + 1 < args.Length && int.TryParse(args[i + 1], out var pid):
                    parent = pid;
                    i++;
                    break;
            }
        }
        return new BridgeOptions(port, parent, demo);
    }
}

/// <summary>
/// Modo ponte: cada aparelho local ganha um servidor eSCL em 127.0.0.1, e o FiPDF digitaliza
/// por ele com o mesmo cliente eSCL que usa para os aparelhos de rede.
/// </summary>
internal sealed class Bridge(BridgeOptions options)
{
    private readonly ILogger _log = FileLogger.Open();
    private readonly CancellationTokenSource _quit = new();
    private readonly SemaphoreSlim _busy = new(1, 1);
    private ScanningContext? _scanning;
    private ScanServer? _server;
    private LocalEsclServer? _escl;
    private List<ScanDevice> _devices = new();
    private List<DriverError> _errors = new();

    public async Task<int> Run()
    {
        // Os processos que este auxiliar abrir (o NAPS2.Worker.exe do TWAIN) morrem junto com ele.
        if (!JobObject.KillChildrenWithMe()) _log.LogWarning("Não foi possível criar o Job Object para os processos auxiliares");
        _log.LogInformation("FiPDF.Scan {Version} (NAPS2.Sdk {Naps}) subindo; porta base {Port}, pai {Parent}",
            Program.AppVersion(), Program.NapsVersion(), options.BasePort, options.ParentPid);
        WatchParent();
        try
        {
            await Refresh();
            Program.Emit(new Ready("pronto", Program.ProtocolVersion, Snapshot(), _errors));
            await ReadCommands();
            return 0;
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Falha no modo ponte");
            Program.Emit(new ErrorInfo("erro", "inesperado", ex.Message));
            return 1;
        }
        finally
        {
            await StopServer();
            _scanning?.Dispose();
            _log.LogInformation("FiPDF.Scan encerrado");
            (_log as IDisposable)?.Dispose();
        }
    }

    /// <summary>Procura os aparelhos de novo e refaz os servidores.</summary>
    private async Task Refresh()
    {
        await _busy.WaitAsync();
        try
        {
            await StopServer();
            _scanning?.Dispose();
            _scanning = Devices.NewContext(out var twainError, _log);
            var (found, errors) = await Devices.Find(_scanning, twainError);
            _devices = found;
            _errors = errors;
            foreach (var e in errors) _log.LogWarning("Driver {Driver}: {Message}", e.Driver, e.Mensagem);

            _escl = new LocalEsclServer { Logger = _log };
            _server = new ScanServer(_scanning, _escl);
            // Nomes únicos: dois aparelhos iguais (um no WIA, outro no TWAIN) não se confundem.
            var used = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            for (var i = 0; i < _devices.Count; i++)
            {
                var d = _devices[i];
                var name = d.Name;
                if (!used.Add(name))
                {
                    name = $"{d.Name} ({Devices.DriverName(d.Driver).ToUpperInvariant()})";
                    var n = 2;
                    while (!used.Add(name)) name = $"{d.Name} ({n++})";
                }
                _server.RegisterDevice(d, name, options.BasePort == 0 ? 0 : options.BasePort + i);
            }
            // Aparelho de demonstração: registrado direto no servidor local, depois dos reais.
            if (options.Demo) _escl.AddDevice(DemoDevice.Config(options.BasePort == 0 ? 0 : options.BasePort + _devices.Count));
            await _server.Start();
            foreach (var (config, port, error) in _escl.Devices)
            {
                if (error != null) _log.LogError("Servidor de {Device}: {Error}", config.Capabilities.MakeAndModel, error);
                else _log.LogInformation("{Device} em {Url}", config.Capabilities.MakeAndModel, _escl.UrlFor(port));
            }
        }
        finally
        {
            _busy.Release();
        }
    }

    private async Task StopServer()
    {
        if (_server == null) return;
        try
        {
            await _server.Stop();
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Ao parar os servidores");
        }
        _server.Dispose();
        _server = null;
        _escl = null;
    }

    /// <summary>Aparelhos com a URL de cada um (a ordem é a mesma do registro).</summary>
    private List<DeviceInfo> Snapshot()
    {
        var running = _escl?.Devices ?? [];
        var list = new List<DeviceInfo>();
        for (var i = 0; i < _devices.Count; i++)
        {
            var d = _devices[i];
            var url = i < running.Count && running[i].Port > 0 ? _escl!.UrlFor(running[i].Port) : null;
            var name = i < running.Count ? running[i].Config.Capabilities.MakeAndModel ?? d.Name : d.Name;
            list.Add(new DeviceInfo(name, Devices.DriverName(d.Driver), Devices.Key(d), url));
        }
        for (var i = _devices.Count; i < running.Count; i++)
        {
            var url = running[i].Port > 0 ? _escl!.UrlFor(running[i].Port) : null;
            list.Add(new DeviceInfo(running[i].Config.Capabilities.MakeAndModel ?? DemoDevice.Name, "demo", "demo:1", url));
        }
        return list;
    }

    private async Task ReadCommands()
    {
        // A leitura do console bloqueia e ignora cancelamento: fica numa thread à parte, e o laço
        // também acorda quando é hora de sair (o FiPDF fechou, ou pediu "sair").
        var quit = Task.Delay(Timeout.Infinite, _quit.Token).ContinueWith(_ => { }, TaskScheduler.Default);
        while (!_quit.IsCancellationRequested)
        {
            var read = Task.Run(() => Console.In.ReadLine());
            if (await Task.WhenAny(read, quit) != read) break;
            var line = await read;
            // stdin fechado: o FiPDF foi embora.
            if (line == null)
            {
                _log.LogInformation("stdin fechado; encerrando");
                break;
            }
            line = line.Trim();
            if (line.Length == 0) continue;
            string? cmd;
            try
            {
                cmd = line.StartsWith('{')
                    ? JsonSerializer.Deserialize(line, Json.Default.Command)?.Comando
                    : line;
            }
            catch (JsonException)
            {
                Program.Emit(new ErrorInfo("erro", "json-invalido", "O comando não é um JSON válido."));
                continue;
            }
            switch (cmd?.Trim().ToLowerInvariant())
            {
                case "ping":
                    Program.Emit(new Simple("pong"));
                    break;
                case "listar":
                    Program.Emit(new Ready("dispositivos", Program.ProtocolVersion, Snapshot(), _errors));
                    break;
                case "atualizar":
                    try
                    {
                        await Refresh();
                        Program.Emit(new Ready("dispositivos", Program.ProtocolVersion, Snapshot(), _errors));
                    }
                    catch (Exception ex)
                    {
                        _log.LogError(ex, "Ao atualizar a lista");
                        Program.Emit(new ErrorInfo("erro", "atualizar", ex.Message));
                    }
                    break;
                case "sair":
                    Program.Emit(new Simple("tchau"));
                    _quit.Cancel();
                    break;
                default:
                    Program.Emit(new ErrorInfo("erro", "comando-desconhecido", $"Comando desconhecido: {cmd}"));
                    break;
            }
        }
    }

    /// <summary>Se o FiPDF (--pai) fechar sem avisar, o auxiliar também fecha.</summary>
    private void WatchParent()
    {
        if (options.ParentPid is not int pid) return;
        try
        {
            var parent = Process.GetProcessById(pid);
            parent.EnableRaisingEvents = true;
            parent.Exited += (_, _) =>
            {
                _log.LogInformation("O processo {Pid} (FiPDF) terminou; encerrando", pid);
                _quit.Cancel();
            };
            if (parent.HasExited) _quit.Cancel();
        }
        catch (ArgumentException)
        {
            _log.LogWarning("O processo pai {Pid} já não existe; encerrando", pid);
            _quit.Cancel();
        }
    }
}
