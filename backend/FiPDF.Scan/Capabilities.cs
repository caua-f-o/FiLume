// FiPDF.Scan — Copyright (C) 2026 Cauã F. O. — GPL-3.0-or-later.
using System.Security.Cryptography;
using System.Text;
using NAPS2.Escl;
using NAPS2.Scan;

namespace FiPDF.Scan;

/// <summary>Traduz o que o driver informa (ScanCaps do NAPS2) para as capacidades do eSCL.</summary>
internal static class Capabilities
{
    public const string Extensions = "Progress;ErrorDetails;ShortTimeout;AnyDpi;FiPDFAutoSource";

    private static readonly int[] Common = [150, 200, 300, 400, 600];

    /// <summary>
    /// Capacidades do aparelho. Com <paramref name="caps"/> nulo (o driver não respondeu), as fontes
    /// ficam em branco e o servidor anuncia vidro, alimentador e frente e verso, como o NAPS2.
    /// </summary>
    public static EsclCapabilities For(string name, string key, ScanCaps? caps)
    {
        var sources = caps?.PaperSourceCaps;
        // Driver que responde mas não diz nada das fontes: trata como desconhecido.
        var known = sources != null && (sources.SupportsFlatbed || sources.SupportsFeeder || sources.SupportsDuplex);
        return new EsclCapabilities
        {
            MakeAndModel = name,
            Uuid = Uuid(key),
            Manufacturer = "FiPDF",
            Naps2Extensions = Extensions,
            PlatenCaps = known && sources!.SupportsFlatbed ? Input(caps!.FlatbedCaps) : null,
            AdfSimplexCaps = known && (sources!.SupportsFeeder || sources.SupportsDuplex) ? Input(caps!.FeederCaps ?? caps.DuplexCaps) : null,
            AdfDuplexCaps = known && sources!.SupportsDuplex ? Input(caps!.DuplexCaps ?? caps.FeederCaps) : null,
        };
    }

    private static EsclInputCaps Input(PerSourceCaps? source)
    {
        var bits = source?.BitDepthCaps;
        var modes = new List<EsclColorMode>();
        if (bits == null || bits.SupportsBlackAndWhite) modes.Add(EsclColorMode.BlackAndWhite1);
        if (bits == null || bits.SupportsGrayscale) modes.Add(EsclColorMode.Grayscale8);
        if (bits == null || bits.SupportsColor) modes.Add(EsclColorMode.RGB24);
        if (modes.Count == 0) modes.AddRange([EsclColorMode.Grayscale8, EsclColorMode.RGB24]);

        // Resoluções: as que o driver lista (as comuns, quando ele dá uma faixa enorme).
        var dpis = source?.DpiCaps?.CommonValues ?? source?.DpiCaps?.Values;
        var resolutions = (dpis is { Count: > 0 } ? dpis.Where(d => d is >= 75 and <= 1200) : Common)
            .Distinct().OrderBy(d => d).Select(d => new DiscreteResolution(d, d)).ToList();
        if (resolutions.Count == 0) resolutions = Common.Select(d => new DiscreteResolution(d, d)).ToList();

        // Área máxima, em 1/300 de polegada.
        var area = source?.PageSizeCaps?.ScanArea;
        int? maxW = area == null ? null : (int) Math.Round(area.WidthInInches * 300);
        int? maxH = area == null ? null : (int) Math.Round(area.HeightInInches * 300);
        return new EsclInputCaps
        {
            MinWidth = 1,
            MinHeight = 1,
            MaxWidth = maxW is > 0 ? maxW : null,
            MaxHeight = maxH is > 0 ? maxH : null,
            SettingProfiles =
            [
                new EsclSettingProfile
                {
                    ColorModes = modes,
                    DiscreteResolutions = resolutions,
                }
            ],
        };
    }

    /// <summary>UUID estável a partir do identificador do aparelho (o mesmo aparelho, o mesmo UUID).</summary>
    public static string Uuid(string key)
    {
        var hash = MD5.HashData(Encoding.UTF8.GetBytes("fipdf-scan:" + key));
        return new Guid(hash).ToString();
    }
}
