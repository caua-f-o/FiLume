// Arquivo do FiPDF.Escl.Local, derivado do NAPS2 (https://github.com/cyanfish/naps2,
// NAPS2.Escl.Server, versão 8.6.1 / SDK 1.5.0).
// Copyright 2009-2026 NAPS2 Contributors; modificações © 2026 Cauã F. O.
// Licença: GNU LGPL v2.1 ou posterior (veja LICENSE nesta pasta).
// Modificações: só o namespace (FiPDF.Escl.Local).

using EmbedIO;

namespace FiPDF.Escl.Local;

internal static class WebServerExtensions
{
    public static async Task StartAsync(this WebServer server, CancellationToken cancelToken = default)
    {
        var startedTcs = new TaskCompletionSource<bool>();
        server.StateChanged += (_, args) =>
        {
            if (args.NewState == WebServerState.Listening)
            {
                startedTcs.TrySetResult(true);
            }
        };
        _ = server.RunAsync(cancelToken).ContinueWith(t =>
        {
            if (t.IsFaulted)
            {
                startedTcs.TrySetException(t.Exception!);
            }
            else
            {
                startedTcs.TrySetCanceled();
            }
        });
        await startedTcs.Task;
    }
}