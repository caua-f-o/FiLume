// Arquivo do FiPDF.Escl.Local, derivado do NAPS2 (https://github.com/cyanfish/naps2,
// NAPS2.Escl.Server, versão 8.6.1 / SDK 1.5.0).
// Copyright 2009-2026 NAPS2 Contributors; modificações © 2026 Cauã F. O.
// Licença: GNU LGPL v2.1 ou posterior (veja LICENSE nesta pasta).
// Modificações: copiado de NAPS2.Escl (onde é interno) para uso deste servidor.

using System.Globalization;
using System.Xml.Linq;

namespace FiPDF.Escl.Local;

internal class ParseHelper
{
    public static T MaybeParseEnum<T>(XElement? element, T defaultValue) where T : struct =>
        Enum.TryParse<T>(element?.Value, out var value) ? value : defaultValue;

    public static int? MaybeParseInt(XElement? element) =>
        int.TryParse(element?.Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) ? value : null;
}