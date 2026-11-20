// FiPDF.Scan — Copyright (C) 2026 Cauã F. O. — GPL-3.0-or-later.
using NAPS2.Images.Gdi;
using NAPS2.Scan;

namespace FiPDF.Scan;

/// <summary>Descoberta dos aparelhos locais (WIA e TWAIN) pela NAPS2.Sdk.</summary>
internal static class Devices
{
    public static string DriverName(Driver d) => d switch
    {
        Driver.Wia => "wia",
        Driver.Twain => "twain",
        _ => d.ToString().ToLowerInvariant(),
    };

    /// <summary>Identificador estável do aparelho (é por ele que o FiPDF lembra os aparelhos, não pela URL, que muda).</summary>
    public static string Key(ScanDevice d) => $"{DriverName(d.Driver)}:{d.ID}";

    /// <summary>Contexto de digitalização com o auxiliar de 32 bits do TWAIN já preparado.</summary>
    public static ScanningContext NewContext(out string? twainSetupError, Microsoft.Extensions.Logging.ILogger? logger = null)
    {
        var scanning = new ScanningContext(new GdiImageContext());
        if (logger != null) scanning.Logger = logger;
        twainSetupError = null;
        try
        {
            // O TWAIN só roda num processo de 32 bits: o NAPS2 sobe o NAPS2.Worker.exe para isso.
            scanning.SetUpWin32Worker();
        }
        catch (Exception ex)
        {
            twainSetupError = ex.Message;
        }
        return scanning;
    }

    /// <summary>Lista os aparelhos de cada driver. A falha (ou demora) de um driver não impede os outros.</summary>
    public static async Task<(List<ScanDevice> Found, List<DriverError> Errors)> Find(ScanningContext scanning, string? twainSetupError)
    {
        var controller = new ScanController(scanning);
        var found = new List<ScanDevice>();
        var errors = new List<DriverError>();
        foreach (var driver in new[] { Driver.Wia, Driver.Twain })
        {
            var name = DriverName(driver);
            if (driver == Driver.Twain && twainSetupError != null)
            {
                errors.Add(new DriverError(name, twainSetupError));
                continue;
            }
            try
            {
                var task = controller.GetDeviceList(driver);
                if (await Task.WhenAny(task, Task.Delay(TimeSpan.FromSeconds(30))) != task)
                {
                    errors.Add(new DriverError(name, "O driver demorou demais para responder."));
                    continue;
                }
                // O mesmo aparelho às vezes aparece duas vezes no mesmo driver.
                foreach (var d in await task)
                {
                    if (!found.Any(x => Key(x) == Key(d))) found.Add(d);
                }
            }
            catch (Exception ex)
            {
                errors.Add(new DriverError(name, ex.Message));
            }
        }
        return (found, errors);
    }
}
