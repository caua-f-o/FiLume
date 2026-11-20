// Arquivo do FiPDF.Escl.Local — © 2026 Cauã F. O.
// Licença: GNU LGPL v2.1 ou posterior (veja LICENSE nesta pasta), como o resto desta biblioteca.

namespace FiPDF.Escl.Local;

/// <summary>Pedido de digitalização como chegou ao servidor local.</summary>
/// <param name="Settings">As opções do eSCL.</param>
/// <param name="AutoSource">
/// A origem pedida foi "Auto" (extensão do FiPDF): o driver usa o alimentador se houver papel nele,
/// senão o vidro.
/// </param>
public sealed record LocalScanRequest(EsclScanSettings Settings, bool AutoSource);
