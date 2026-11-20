// Arquivo do FiPDF.Escl.Local, derivado do NAPS2 (https://github.com/cyanfish/naps2,
// NAPS2.Escl.Server, versão 8.6.1 / SDK 1.5.0).
// Copyright 2009-2026 NAPS2 Contributors; modificações © 2026 Cauã F. O.
// Licença: GNU LGPL v2.1 ou posterior (veja LICENSE nesta pasta).
// Modificações: só o namespace (FiPDF.Escl.Local).

namespace FiPDF.Escl.Local;

internal class SimpleAsyncLock
{
    private readonly Queue<TaskCompletionSource<bool>> _listeners = new();
    private bool _isTaken;

    public Task Take()
    {
        lock (this)
        {
            if (!_isTaken)
            {
                _isTaken = true;
                return Task.CompletedTask;
            }
            var tcs = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            _listeners.Enqueue(tcs);
            return tcs.Task;
        }
    }

    public void Release()
    {
        lock (this)
        {
            if (_listeners.Count > 0)
            {
                _listeners.Dequeue().SetResult(true);
            }
            else
            {
                _isTaken = false;
            }
        }
    }
}