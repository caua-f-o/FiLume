// FiPDF.Scan — Copyright (C) 2026 Cauã F. O. — GPL-3.0-or-later.
using Microsoft.Extensions.Logging;

namespace FiPDF.Scan;

/// <summary>
/// Log em arquivo, na pasta de dados do FiLume (%LOCALAPPDATA%\FiLume\logs\fipdf-scan.log).
/// O arquivo passa de 1 MB → vira fipdf-scan.1.log e começa outro.
/// </summary>
internal sealed class FileLogger : ILogger, IDisposable
{
    private readonly StreamWriter? _out;
    private readonly object _lock = new();

    private FileLogger(StreamWriter? output) => _out = output;

    public static string LogPath
    {
        get
        {
            var root = Environment.GetEnvironmentVariable("FILUME_LOG_DIR");
            if (string.IsNullOrWhiteSpace(root))
            {
                root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FiLume", "logs");
            }
            return Path.Combine(root, "fipdf-scan.log");
        }
    }

    public static FileLogger Open()
    {
        try
        {
            var path = LogPath;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var info = new FileInfo(path);
            if (info.Exists && info.Length > 1024 * 1024)
            {
                File.Move(path, Path.ChangeExtension(path, ".1.log"), overwrite: true);
            }
            var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite);
            return new FileLogger(new StreamWriter(stream) { AutoFlush = true });
        }
        catch
        {
            // Sem log não é motivo para não digitalizar.
            return new FileLogger(null);
        }
    }

    public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

    public bool IsEnabled(LogLevel logLevel) => _out != null && logLevel >= LogLevel.Information;

    public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
    {
        if (!IsEnabled(logLevel)) return;
        var level = logLevel switch
        {
            LogLevel.Warning => "AVISO",
            LogLevel.Error or LogLevel.Critical => "ERRO",
            _ => "INFO",
        };
        var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {level} {formatter(state, exception)}";
        if (exception != null) line += Environment.NewLine + exception;
        lock (_lock)
        {
            try
            {
                _out!.WriteLine(line);
            }
            catch
            {
                // disco cheio etc.: ignora
            }
        }
    }

    public void Dispose()
    {
        lock (_lock)
        {
            _out?.Dispose();
        }
    }
}
