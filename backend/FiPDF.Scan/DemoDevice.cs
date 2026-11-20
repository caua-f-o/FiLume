// FiPDF.Scan — Copyright (C) 2026 Cauã F. O. — GPL-3.0-or-later.
using System.Drawing;
using System.Drawing.Imaging;
using NAPS2.Escl;
using NAPS2.Escl.Server;

namespace FiPDF.Scan;

/// <summary>
/// Aparelho de demonstração (servir --demo): serve uma página gerada na hora. Existe para testar a ponte
/// sem scanner, por exemplo no build do GitHub e nos testes do lado Dart.
/// </summary>
internal static class DemoDevice
{
    public const string Name = "FiPDF Demonstração";

    public static EsclDeviceConfig Config(int port) => new()
    {
        Port = port,
        Capabilities = new EsclCapabilities
        {
            MakeAndModel = Name,
            Manufacturer = "FiLume",
            Uuid = "8a3c0b9e-6f1d-4a52-9f0e-000000000001",
        },
        CreateJob = _ => new Job(),
    };

    private sealed class Job : IEsclScanJob
    {
        private Action<StatusTransition>? _callback;
        private bool _sent;

        public string ContentType => "image/jpeg";

        public void Cancel() => _callback?.Invoke(StatusTransition.CancelJob);

        public void Start(Action<StatusTransition>? statusCallback = null) => _callback = statusCallback;

        // Uma página só.
        public Task<bool> WaitForNextDocument(CancellationToken cancelToken) => Task.FromResult(!_sent);

        public async Task WriteDocumentTo(Stream stream)
        {
            _sent = true;
            using var bmp = new Bitmap(850, 1100);
            using (var g = Graphics.FromImage(bmp))
            {
                g.Clear(Color.White);
                using var font = new Font("Segoe UI", 28);
                g.DrawString("FiPDF — página de demonstração", font, Brushes.Black, 60, 80);
                g.DrawRectangle(Pens.Black, 40, 40, 770, 1020);
            }
            using var ms = new MemoryStream();
            bmp.Save(ms, ImageFormat.Jpeg);
            ms.Position = 0;
            await ms.CopyToAsync(stream);
            _callback?.Invoke(StatusTransition.ScanComplete);
        }

        public Task WriteProgressTo(Stream stream) => Task.CompletedTask;

        public Task WriteErrorDetailsTo(Stream stream) => Task.CompletedTask;

        public void Dispose()
        {
        }
    }
}
