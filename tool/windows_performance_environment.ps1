# Read-only companion for the Windows performance wrapper. Dot-sourcing has no
# side effects. Start once before the timed window; Read reuses one PDH query.
# No ETW, temperature-provider probing, process enumeration, or setting changes.
# PDH is locale-neutral and keeps percentages above 100 (e.g. turbo performance).

function Initialize-HanMusicPerformanceEnvironmentInterop {
    if ('HanMusic.PerformanceEnvironment.Collector' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace HanMusic.PerformanceEnvironment {
    public sealed class Collector : IDisposable {
        private readonly object gate = new object();
        private IntPtr query;
        private bool disposed;
        private uint openStatus;
        private uint lastCollectionStatus;
        private int collections;
        private readonly Dictionary<string, string> paths;
        private readonly Dictionary<string, IntPtr> counters = new Dictionary<string, IntPtr>();
        private readonly Dictionary<string, uint> addStatuses = new Dictionary<string, uint>();

        [StructLayout(LayoutKind.Explicit)]
        private struct CounterValue {
            [FieldOffset(0)] public uint Status;
            [FieldOffset(8)] public double Value;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct SystemPowerStatus {
            public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag;
            public uint BatteryLifeTime, BatteryFullLifeTime;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct MemoryStatus {
            public uint Length, MemoryLoad;
            public ulong TotalPhysical, AvailablePhysical, TotalPageFile, AvailablePageFile;
            public ulong TotalVirtual, AvailableVirtual, AvailableExtendedVirtual;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct PowerThrottlingState {
            public uint Version, ControlMask, StateMask;
        }

        [DllImport("pdh.dll", CharSet=CharSet.Unicode)]
        private static extern uint PdhOpenQueryW(string source, UIntPtr userData, out IntPtr query);
        [DllImport("pdh.dll", CharSet=CharSet.Unicode)]
        private static extern uint PdhAddEnglishCounterW(IntPtr query, string path, UIntPtr userData, out IntPtr counter);
        [DllImport("pdh.dll")]
        private static extern uint PdhCollectQueryDataWithTime(IntPtr query, out long timestamp);
        [DllImport("pdh.dll")]
        private static extern uint PdhGetFormattedCounterValue(IntPtr counter, uint format, out uint type, out CounterValue value);
        [DllImport("pdh.dll")]
        private static extern uint PdhCloseQuery(IntPtr query);
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetSystemPowerStatus(out SystemPowerStatus value);
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GlobalMemoryStatusEx(ref MemoryStatus value);
        [DllImport("powrprof.dll")]
        private static extern uint PowerGetActiveScheme(IntPtr rootKey, out IntPtr scheme);
        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr value);
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetProcessInformation(IntPtr process, int informationClass, ref PowerThrottlingState value, uint size);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern uint GetProcessId(IntPtr process);
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        private static Dictionary<string, object> Result(string status, string reason) {
            return new Dictionary<string, object> { { "status", status }, { "reason", reason } };
        }
        private static string Hex(uint code) { return "0x" + code.ToString("X8"); }
        private static Dictionary<string, object> Error(string reason, int code) {
            var result = Result("unavailable", reason);
            result["win32Error"] = code;
            return result;
        }

        public Collector(Dictionary<string, string> requestedPaths) {
            paths = new Dictionary<string, string>(requestedPaths);
            try {
                openStatus = PdhOpenQueryW(null, UIntPtr.Zero, out query);
                if (openStatus != 0) return;
                foreach (var item in paths) {
                    IntPtr counter;
                    uint code = PdhAddEnglishCounterW(query, item.Value, UIntPtr.Zero, out counter);
                    addStatuses[item.Key] = code;
                    if (code == 0) counters[item.Key] = counter;
                }
                // Rate counters need a previous sample. This first collection
                // belongs to initialization, outside the benchmark window.
                long ignored;
                lastCollectionStatus = PdhCollectQueryDataWithTime(query, out ignored);
                collections = 1;
            } catch {
                Dispose();
                throw;
            }
        }

        public Dictionary<string, object> ReadCounters() {
            lock (gate) {
                var timer = Stopwatch.StartNew();
                var values = new Dictionary<string, object>();
                long timestamp = 0;
                string collectedAtUtc = null;
                if (!disposed && query != IntPtr.Zero && openStatus == 0) {
                    lastCollectionStatus = PdhCollectQueryDataWithTime(query, out timestamp);
                    collectedAtUtc = DateTime.UtcNow.ToString("o");
                    collections++;
                }
                foreach (var item in paths) {
                    var value = Result("unavailable", "query_open_failed");
                    value["path"] = item.Value;
                    value["value"] = null;
                    value["apiStatus"] = Hex(openStatus);
                    value["dataStatus"] = null;
                    if (disposed) {
                        value["status"] = "stopped";
                        value["reason"] = "collector_disposed";
                    } else if (query != IntPtr.Zero && openStatus == 0) {
                        uint addCode = addStatuses[item.Key];
                        value["apiStatus"] = Hex(addCode);
                        if (addCode != 0) value["reason"] = "counter_add_failed";
                        else if (lastCollectionStatus != 0) {
                            value["reason"] = "collection_failed";
                            value["apiStatus"] = Hex(lastCollectionStatus);
                        } else {
                            CounterValue formatted;
                            uint type;
                            uint code = PdhGetFormattedCounterValue(counters[item.Key], 0x200 | 0x8000, out type, out formatted);
                            value["apiStatus"] = Hex(code);
                            value["dataStatus"] = Hex(formatted.Status);
                            value["counterType"] = type;
                            if (code == 0 && formatted.Status <= 1 && !Double.IsNaN(formatted.Value) && !Double.IsInfinity(formatted.Value)) {
                                value["status"] = "ok";
                                value["reason"] = null;
                                value["value"] = formatted.Value;
                            } else value["reason"] = "counter_value_unavailable";
                        }
                    }
                    values[item.Key] = value;
                }
                timer.Stop();
                int validCount = 0;
                foreach (Dictionary<string, object> value in values.Values) {
                    if ((string)value["status"] == "ok") validCount++;
                }
                return new Dictionary<string, object> {
                    { "status", disposed ? "stopped" : (validCount == 0 ? "unavailable" : (validCount == paths.Count ? "ok" : "partial")) },
                    { "collectionStatus", Hex(lastCollectionStatus) },
                    { "collectionCount", collections },
                    { "validCounterCount", validCount },
                    // Do not assume the provider's FILETIME matches observer
                    // UTC. Keep it raw alongside the actual observation time.
                    { "pdhRawTimestampFileTime", timestamp > 0 ? (object)timestamp : null },
                    { "collectedAtUtc", collectedAtUtc },
                    { "timestampSource", "observer_utc_after_pdh_collect" },
                    { "durationMs", timer.Elapsed.TotalMilliseconds },
                    { "counters", values }
                };
            }
        }

        public static Dictionary<string, object> ReadPower() {
            SystemPowerStatus power;
            Dictionary<string, object> result;
            if (!GetSystemPowerStatus(out power)) result = Error("GetSystemPowerStatus_failed", Marshal.GetLastWin32Error());
            else {
                result = Result("ok", null);
                result["acLineStatus"] = power.ACLineStatus;
                result["acOnline"] = power.ACLineStatus == 255 ? (object)null : power.ACLineStatus == 1;
                result["batteryFlag"] = power.BatteryFlag;
                result["batteryLifePercent"] = power.BatteryLifePercent == 255 ? (object)null : power.BatteryLifePercent;
                result["systemStatusFlag"] = power.SystemStatusFlag;
            }
            IntPtr scheme = IntPtr.Zero;
            try {
                uint code = PowerGetActiveScheme(IntPtr.Zero, out scheme);
                result["activeSchemeStatus"] = Hex(code);
                result["activeSchemeGuid"] = code == 0 && scheme != IntPtr.Zero ? Marshal.PtrToStructure(scheme, typeof(Guid)).ToString() : null;
            } finally {
                if (scheme != IntPtr.Zero) LocalFree(scheme);
            }
            return result;
        }

        public static Dictionary<string, object> ReadMemory() {
            var memory = new MemoryStatus();
            memory.Length = (uint)Marshal.SizeOf(typeof(MemoryStatus));
            if (!GlobalMemoryStatusEx(ref memory)) return Error("GlobalMemoryStatusEx_failed", Marshal.GetLastWin32Error());
            var result = Result("ok", null);
            result["physicalLoadPercent"] = memory.MemoryLoad;
            result["totalPhysicalBytes"] = memory.TotalPhysical;
            result["availablePhysicalBytes"] = memory.AvailablePhysical;
            result["commitLimitBytes"] = memory.TotalPageFile;
            result["availableCommitBytes"] = memory.AvailablePageFile;
            return result;
        }

        public static Dictionary<string, object> ReadProcessQos(IntPtr handle, uint expectedId) {
            // Query the exact supplied process handle, never reopen by PID.
            uint actualId = GetProcessId(handle);
            if (actualId == 0) return Error("GetProcessId_failed", Marshal.GetLastWin32Error());
            if (actualId != expectedId) return Result("unavailable", "process_handle_identity_mismatch");
            var result = Result("unavailable", null);
            result["targetProcessId"] = actualId;
            uint wait = WaitForSingleObject(handle, 0);
            if (wait != 258) {
                result["reason"] = wait == 0 ? "target_process_exited" : "process_liveness_query_failed";
                result["waitStatus"] = Hex(wait);
                return result;
            }
            long creation, exit, kernel, user;
            if (GetProcessTimes(handle, out creation, out exit, out kernel, out user)) {
                result["targetCreatedAtUtc"] = DateTime.FromFileTimeUtc(creation).ToString("o");
            }
            var state = new PowerThrottlingState { Version = 1 };
            if (!GetProcessInformation(handle, 4, ref state, 12)) {
                result["reason"] = "GetProcessInformation_failed";
                result["win32Error"] = Marshal.GetLastWin32Error();
                return result;
            }
            result["status"] = "ok";
            result["version"] = state.Version;
            result["controlMask"] = state.ControlMask;
            result["stateMask"] = state.StateMask;
            result["executionSpeedPolicy"] = (state.ControlMask & 1) == 0 ? "system_managed" : ((state.StateMask & 1) != 0 ? "explicit_eco" : "explicit_disable");
            // No claim about per-thread QoS or the system's effective scheduling.
            return result;
        }

        public void Dispose() {
            lock (gate) {
                if (disposed) return;
                disposed = true;
                if (query != IntPtr.Zero) {
                    PdhCloseQuery(query);
                    query = IntPtr.Zero;
                }
                counters.Clear();
            }
        }
    }
}
'@
}

function Start-HanMusicPerformanceEnvironment {
    [CmdletBinding()]
    param([System.Collections.IDictionary]$CounterPaths)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $started = [DateTime]::UtcNow.ToString('o')
    $native = $null
    $reason = $null
    if ($null -eq $CounterPaths) {
        $CounterPaths = [ordered]@{
            processorTimePercent = '\Processor Information(_Total)\% Processor Time'
            processorFrequencyMHz = '\Processor Information(_Total)\Processor Frequency'
            processorPerformancePercent = '\Processor Information(_Total)\% Processor Performance'
            maximumFrequencyPercent = '\Processor Information(_Total)\% of Maximum Frequency'
            performanceLimitPercent = '\Processor Information(_Total)\% Performance Limit'
            performanceLimitFlags = '\Processor Information(_Total)\Performance Limit Flags'
        }
    }
    try {
        Initialize-HanMusicPerformanceEnvironmentInterop
        $paths = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        foreach ($key in $CounterPaths.Keys) { $paths.Add([string]$key, [string]$CounterPaths[$key]) }
        $native = New-Object HanMusic.PerformanceEnvironment.Collector -ArgumentList (, $paths)
    } catch {
        $reason = $_.Exception.Message
    }
    $context = [pscustomobject]@{
        PSTypeName = 'HanMusic.PerformanceEnvironment.Context'
        Native = $native
        InitializationError = $reason
        InitializationDurationMs = $timer.Elapsed.TotalMilliseconds
        StartedAtUtc = $started
        Stopped = $false
    }
    # Prime PowerShell member binding and power/memory P/Invoke as well as PDH.
    # Target-process QoS needs one additional pre-window Read with that handle.
    if ($null -ne $native) { $null = Read-HanMusicPerformanceEnvironment -Collector $context }
    $timer.Stop()
    $context.InitializationDurationMs = $timer.Elapsed.TotalMilliseconds
    return $context
}

function Read-HanMusicPerformanceEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Collector,
        [Diagnostics.Process]$TargetProcess
    )
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $result = [ordered]@{
        schemaVersion = 1
        startedAtUtc = [DateTime]::UtcNow.ToString('o')
        completedAtUtc = $null
        durationMs = 0.0
        initializationDurationMs = $Collector.InitializationDurationMs
        initializationError = $Collector.InitializationError
        cpu = $null
        power = $null
        memory = $null
        processQos = @{ status = 'not_requested'; reason = 'no_target_process_handle' }
        temperature = @{ status = 'not_collected'; reason = 'no_reliable_unprivileged_cpu_temperature_source_configured' }
    }
    if ($Collector.Stopped -or $null -eq $Collector.Native) {
        $status = if ($Collector.Stopped) { 'stopped' } else { 'unavailable' }
        $reason = if ($Collector.Stopped) { 'collector_disposed' } else { 'interop_initialization_failed' }
        foreach ($key in @('cpu', 'power', 'memory', 'processQos')) { $result[$key] = @{ status=$status; reason=$reason } }
    } else {
        foreach ($key in @('cpu', 'power', 'memory')) {
            try {
                switch ($key) {
                    'cpu' { $result[$key] = $Collector.Native.ReadCounters() }
                    'power' { $result[$key] = [HanMusic.PerformanceEnvironment.Collector]::ReadPower() }
                    'memory' { $result[$key] = [HanMusic.PerformanceEnvironment.Collector]::ReadMemory() }
                }
            } catch { $result[$key] = @{ status='unavailable'; reason=$_.Exception.Message } }
        }
        if ($null -ne $TargetProcess) {
            try {
                # The Process object must be the wrapper's Start-Process result.
                # Keeping this SafeHandle alive prevents handle reuse mid-query.
                $safeHandle = $TargetProcess.SafeHandle
                $added = $false
                try {
                    $safeHandle.DangerousAddRef([ref]$added)
                    $result.processQos = [HanMusic.PerformanceEnvironment.Collector]::ReadProcessQos($safeHandle.DangerousGetHandle(), [uint32]$TargetProcess.Id)
                } finally { if ($added) { $safeHandle.DangerousRelease() } }
            } catch { $result.processQos = @{ status='unavailable'; reason=$_.Exception.Message } }
        }
    }
    $timer.Stop()
    $result.durationMs = $timer.Elapsed.TotalMilliseconds
    $result.completedAtUtc = [DateTime]::UtcNow.ToString('o')
    return [pscustomobject]$result
}

function Stop-HanMusicPerformanceEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Collector)
    if ($Collector.Stopped) { return }
    $Collector.Stopped = $true
    if ($null -ne $Collector.Native) {
        try { $Collector.Native.Dispose() } catch { }
    }
}
