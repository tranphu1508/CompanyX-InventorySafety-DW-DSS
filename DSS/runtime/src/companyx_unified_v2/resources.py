"""Per-run Windows committed-memory cap and durable daily native-solver budget.

RAM is committed memory of the simulation process tree, not CPLEX workmem or
resident-set sampling. The SQL Server service is outside this job.
"""
from contextlib import contextmanager
import ctypes,os,math
from ctypes import wintypes as W
from .legacy import read,save

class DailyBudget:
    def __init__(self,path,total):
        self.path,self.total=path,float(total)
        self.state=read(path) if path.exists() else dict(total_seconds=self.total,used_seconds=0.,pending_seconds=0.,attempts=[])
        if self.state['total_seconds']!=self.total:raise ValueError('Immutable daily solver budget changed')
        if self.state['pending_seconds']:
            # No durable result means the entire reserved allowance is consumed.
            self.settle(None)
    def reserve(self):
        left=max(0.,self.total-self.state['used_seconds'])
        if left<=1e-6:raise RuntimeError('Daily solver budget exhausted; create a new policy/run to change the budget')
        self.state['pending_seconds']=left;save(self.path,self.state);return left
    def settle(self,seconds):
        reserved=self.state['pending_seconds']
        if not reserved:return
        known=isinstance(seconds,(int,float)) and math.isfinite(seconds) and seconds>=0
        used=float(seconds) if known else reserved
        self.state['attempts'].append(dict(reserved_seconds=reserved,charged_seconds=used,basis='NATIVE_WALL_SECONDS' if known else 'UNKNOWN_EXIT_FULL_RESERVATION'))
        self.state['used_seconds']+=used;self.state['pending_seconds']=0.;save(self.path,self.state)

class Basic(ctypes.Structure):
    _fields_=[('PerProcessUserTimeLimit',ctypes.c_longlong),('PerJobUserTimeLimit',ctypes.c_longlong),('LimitFlags',W.DWORD),
              ('MinimumWorkingSetSize',ctypes.c_size_t),('MaximumWorkingSetSize',ctypes.c_size_t),('ActiveProcessLimit',W.DWORD),
              ('Affinity',ctypes.c_size_t),('PriorityClass',W.DWORD),('SchedulingClass',W.DWORD)]
class IO(ctypes.Structure):
    _fields_=[(n,ctypes.c_ulonglong) for n in ('ReadOperationCount','WriteOperationCount','OtherOperationCount','ReadTransferCount','WriteTransferCount','OtherTransferCount')]
class Extended(ctypes.Structure):
    _fields_=[('BasicLimitInformation',Basic),('IoInfo',IO)]+[(n,ctypes.c_size_t) for n in ('ProcessMemoryLimit','JobMemoryLimit','PeakProcessMemoryUsed','PeakJobMemoryUsed')]

@contextmanager
def memory_limit(gib,folder):
    if gib is None:
        save(folder/'resource_limits.json',dict(max_ram_gib=None,enforced=False,scope='simulation process tree; SQL Server excluded'))
        yield;return
    if os.name!='nt':raise RuntimeError('Hard RAM cap currently supported on Windows only; refusing an unenforced limit')
    k=ctypes.WinDLL('kernel32',use_last_error=True)
    k.CreateJobObjectW.argtypes=[ctypes.c_void_p,W.LPCWSTR];k.CreateJobObjectW.restype=W.HANDLE
    k.GetCurrentProcess.restype=W.HANDLE
    k.SetInformationJobObject.argtypes=[W.HANDLE,ctypes.c_int,ctypes.c_void_p,W.DWORD];k.SetInformationJobObject.restype=W.BOOL
    k.AssignProcessToJobObject.argtypes=[W.HANDLE,W.HANDLE];k.AssignProcessToJobObject.restype=W.BOOL
    k.QueryInformationJobObject.argtypes=[W.HANDLE,ctypes.c_int,ctypes.c_void_p,W.DWORD,ctypes.c_void_p];k.QueryInformationJobObject.restype=W.BOOL
    k.CloseHandle.argtypes=[W.HANDLE];k.CloseHandle.restype=W.BOOL
    handle=k.CreateJobObjectW(None,None)
    if not handle:raise ctypes.WinError(ctypes.get_last_error())
    info=Extended();info.BasicLimitInformation.LimitFlags=0x200;info.JobMemoryLimit=int(gib*2**30)
    attached=False
    try:
        if not k.SetInformationJobObject(handle,9,ctypes.byref(info),ctypes.sizeof(info)):raise ctypes.WinError(ctypes.get_last_error())
        if not k.AssignProcessToJobObject(handle,k.GetCurrentProcess()):raise ctypes.WinError(ctypes.get_last_error())
        attached=True
        save(folder/'resource_limits.json',dict(max_ram_gib=gib,enforced=True,limit_bytes=info.JobMemoryLimit,
            mechanism='Windows JOB_OBJECT_LIMIT_JOB_MEMORY',scope='committed memory of simulation and inherited child processes; not SQL Server or resident RAM'))
        yield
    finally:
        if attached:
            final=Extended()
            if k.QueryInformationJobObject(handle,9,ctypes.byref(final),ctypes.sizeof(final),None):
                save(folder/'resource_usage.json',dict(peak_committed_bytes=final.PeakJobMemoryUsed,limit_bytes=info.JobMemoryLimit))
            # No kill-on-close flag. Release this limit; never terminate unrelated jobs.
            empty=Extended();k.SetInformationJobObject(handle,9,ctypes.byref(empty),ctypes.sizeof(empty))
        k.CloseHandle(handle)
