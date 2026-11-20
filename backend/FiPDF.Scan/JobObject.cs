// FiPDF.Scan — Copyright (C) 2026 Cauã F. O. — GPL-3.0-or-later.
using System.Runtime.InteropServices;

namespace FiPDF.Scan;

/// <summary>
/// Coloca este processo num Job Object do Windows com "matar ao fechar": quando o FiPDF.Scan
/// termina, mesmo à força, os processos que ele abriu (o NAPS2.Worker.exe do TWAIN) terminam junto.
/// </summary>
internal static class JobObject
{
    private static IntPtr _job;

    public static bool KillChildrenWithMe()
    {
        if (!OperatingSystem.IsWindows()) return false;
        _job = CreateJobObject(IntPtr.Zero, null);
        if (_job == IntPtr.Zero) return false;
        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            BasicLimitInformation = new JOBOBJECT_BASIC_LIMIT_INFORMATION { LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE },
        };
        var size = Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>();
        var ptr = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(info, ptr, false);
            if (!SetInformationJobObject(_job, JobObjectExtendedLimitInformation, ptr, (uint) size)) return false;
        }
        finally
        {
            Marshal.FreeHGlobal(ptr);
        }
        // O handle fica aberto até o processo acabar; aí o Windows fecha e mata o resto do job.
        return AssignProcessToJobObject(_job, System.Diagnostics.Process.GetCurrentProcess().Handle);
    }

    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
    private const int JobObjectExtendedLimitInformation = 9;

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string? name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
}
