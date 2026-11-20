// FiPDF.Scan — auxiliar de digitalização do FiPDF.
// Copyright (C) 2026 Cauã F. O. — GPL-3.0-or-later (veja LICENSE na raiz do FiLume).
//
// Usa a NAPS2.Sdk (https://github.com/cyanfish/naps2, LGPL-2.1-or-later,
// © NAPS2 Contributors, Ben Olden-Cooligan) para falar com scanners WIA e TWAIN.
//
// Comandos:
//   --versao          versão do auxiliar e do protocolo
//   listar            aparelhos WIA e TWAIN (uma linha JSON e sai)
//   servir            modo ponte: um servidor eSCL local (127.0.0.1) por aparelho,
//                     anúncio "pronto" no stdout e comandos JSON pelo stdin

using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;
using NAPS2.Scan;

namespace FiPDF.Scan;

public static class Program
{
    /// <summary>Versão do protocolo entre o FiPDF e este auxiliar.</summary>
    public const int ProtocolVersion = 1;

    public static async Task<int> Main(string[] args)
    {
        Console.OutputEncoding = System.Text.Encoding.UTF8;
        var command = args.Length == 0 ? "ajuda" : args[0].TrimStart('-').ToLowerInvariant();
        try
        {
            switch (command)
            {
                case "versao":
                case "version":
                    Emit(new VersionInfo("versao", ProtocolVersion, AppVersion(), Environment.Version.ToString(), NapsVersion()));
                    return 0;
                case "listar":
                case "list":
                {
                    using var scanning = Devices.NewContext(out var twainSetup);
                    var (found, errors) = await Devices.Find(scanning, twainSetup);
                    Emit(new DeviceList("dispositivos", ProtocolVersion,
                        found.Select(d => new DeviceInfo(d.Name, Devices.DriverName(d.Driver), Devices.Key(d), null)).ToList(), errors));
                    return 0;
                }
                case "servir":
                case "serve":
                    return await new Bridge(BridgeOptions.Parse(args.Skip(1).ToArray())).Run();
                default:
                    Console.Error.WriteLine("FiPDF.Scan — auxiliar de digitalização do FiPDF");
                    Console.Error.WriteLine();
                    Console.Error.WriteLine("  FiPDF.Scan --versao   versão do auxiliar e do protocolo");
                    Console.Error.WriteLine("  FiPDF.Scan listar     aparelhos WIA e TWAIN deste computador");
                    Console.Error.WriteLine("  FiPDF.Scan servir [--porta N] [--pai PID] [--demo]");
                    Console.Error.WriteLine("                        ponte com o FiPDF: servidor eSCL em 127.0.0.1 e comandos pelo stdin");
                    Console.Error.WriteLine("                        (listar, atualizar, ping, sair)");
                    Console.Error.WriteLine();
                    Console.Error.WriteLine("A saída é uma linha JSON por resposta.");
                    return command == "ajuda" || command == "help" || command == "h" ? 0 : 2;
            }
        }
        catch (Exception ex)
        {
            Emit(new ErrorInfo("erro", "inesperado", ex.Message));
            return 1;
        }
    }

    internal static string AppVersion() =>
        typeof(Program).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "?";

    internal static string NapsVersion() =>
        typeof(ScanController).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "?";

    private static readonly object OutLock = new();

    /// <summary>Escreve uma resposta: uma linha JSON no stdout.</summary>
    internal static void Emit<T>(T value)
    {
        var info = (System.Text.Json.Serialization.Metadata.JsonTypeInfo<T>) Json.Default.GetTypeInfo(typeof(T))!;
        var line = JsonSerializer.Serialize(value, info);
        lock (OutLock)
        {
            Console.Out.WriteLine(line);
            Console.Out.Flush();
        }
    }
}

public record VersionInfo(string Tipo, int Protocolo, string Versao, string Dotnet, string Naps2);

public record DeviceInfo(string Nome, string Driver, string Id, string? Url);

public record DriverError(string Driver, string Mensagem);

public record DeviceList(string Tipo, int Protocolo, List<DeviceInfo> Dispositivos, List<DriverError> Erros);

public record ErrorInfo(string Tipo, string Codigo, string Mensagem);

public record Ready(string Tipo, int Versao, List<DeviceInfo> Dispositivos, List<DriverError> Erros);

public record Simple(string Tipo);

/// <summary>Comando recebido pelo stdin.</summary>
public record Command(string? Comando);

// Serialização gerada em tempo de compilação: não depende de reflexão (seguro com o trimming).
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, WriteIndented = false)]
[JsonSerializable(typeof(VersionInfo))]
[JsonSerializable(typeof(DeviceList))]
[JsonSerializable(typeof(ErrorInfo))]
[JsonSerializable(typeof(Ready))]
[JsonSerializable(typeof(Simple))]
[JsonSerializable(typeof(Command))]
internal partial class Json : JsonSerializerContext;
