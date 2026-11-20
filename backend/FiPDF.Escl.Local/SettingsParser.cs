// Arquivo do FiPDF.Escl.Local, derivado do NAPS2 (https://github.com/cyanfish/naps2,
// NAPS2.Escl.Server, versão 8.6.1 / SDK 1.5.0).
// Copyright 2009-2026 NAPS2 Contributors; modificações © 2026 Cauã F. O.
// Licença: GNU LGPL v2.1 ou posterior (veja LICENSE nesta pasta).
// Modificações: só o namespace (FiPDF.Escl.Local).

using System.Xml.Linq;

namespace FiPDF.Escl.Local;

internal static class SettingsParser
{
    private static readonly XNamespace ScanNs = EsclXmlHelper.ScanNs;
    private static readonly XNamespace PwgNs = EsclXmlHelper.PwgNs;

    public static EsclScanSettings Parse(XDocument doc)
    {
        var root = doc.Root;
        if (root?.Name != ScanNs + "ScanSettings")
        {
            throw new InvalidOperationException("Unexpected root element: " + doc.Root?.Name);
        }
        var scanRegion = root!.Element(PwgNs + "ScanRegions")?.Elements(PwgNs + "ScanRegion").FirstOrDefault();
        return new EsclScanSettings
        {
            // TODO: Handle intents?
            InputSource = ParseHelper.MaybeParseEnum(root.Element(PwgNs + "InputSource"), EsclInputSource.Platen),
            ColorMode = ParseHelper.MaybeParseEnum(root.Element(ScanNs + "ColorMode"), EsclColorMode.RGB24),
            DocumentFormat = root.Element(ScanNs + "DocumentFormatExt")?.Value ??
                             root.Element(PwgNs + "DocumentFormat")?.Value,
            Duplex = root.Element(ScanNs + "Duplex")?.Value == "true",
            XResolution = ParseHelper.MaybeParseInt(root.Element(ScanNs + "XResolution")) ?? 0,
            YResolution = ParseHelper.MaybeParseInt(root.Element(ScanNs + "YResolution")) ?? 0,
            Width = ParseHelper.MaybeParseInt(scanRegion?.Element(PwgNs + "Width")) ?? 0,
            Height = ParseHelper.MaybeParseInt(scanRegion?.Element(PwgNs + "Height")) ?? 0,
            XOffset = ParseHelper.MaybeParseInt(scanRegion?.Element(PwgNs + "XOffset")) ?? 0,
            YOffset = ParseHelper.MaybeParseInt(scanRegion?.Element(PwgNs + "YOffset")) ?? 0,
            CompressionFactor = ParseHelper.MaybeParseInt(root.Element(ScanNs + "CompressionFactor"))
        };
    }
}