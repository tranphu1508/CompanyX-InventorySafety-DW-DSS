"""Read flattened SSAS rowsets through the installed Windows ADO/MSOLAP provider.

ctypes supplies the handful of IDispatch calls needed for the Connection and
Recordset interfaces. No additional Python package or script host is required.
"""
from __future__ import annotations

import ctypes as ct
from contextlib import contextmanager
from uuid import UUID


def guid(value):
    return (ct.c_ubyte * 16).from_buffer_copy(UUID(value).bytes_le)


IID_NULL = guid('00000000-0000-0000-0000-000000000000')
IID_DISPATCH = guid('00020400-0000-0000-c000-000000000046')
ole32 = ct.OleDLL('ole32')
oleaut = ct.WinDLL('oleaut32')
oleaut.SysAllocString.argtypes = [ct.c_wchar_p]
oleaut.SysAllocString.restype = ct.c_void_p
oleaut.SysFreeString.argtypes = [ct.c_void_p]
oleaut.SysStringLen.argtypes = [ct.c_void_p]
oleaut.SafeArrayCreateVector.argtypes = [ct.c_ushort, ct.c_long, ct.c_ulong]
oleaut.SafeArrayCreateVector.restype = ct.c_void_p
oleaut.SafeArrayPutElement.argtypes = [ct.c_void_p, ct.POINTER(ct.c_long), ct.c_void_p]
oleaut.SafeArrayGetDim.argtypes=[ct.c_void_p]
oleaut.SafeArrayGetLBound.argtypes=[ct.c_void_p,ct.c_uint,ct.POINTER(ct.c_long)]
oleaut.SafeArrayGetUBound.argtypes=[ct.c_void_p,ct.c_uint,ct.POINTER(ct.c_long)]
oleaut.SafeArrayAccessData.argtypes=[ct.c_void_p,ct.POINTER(ct.c_void_p)]
oleaut.SafeArrayUnaccessData.argtypes=[ct.c_void_p]


class Value(ct.Union):
    _fields_ = [('pointer', ct.c_void_p), ('int16', ct.c_short), ('int32', ct.c_int32),
                ('int64', ct.c_int64), ('double', ct.c_double), ('record', ct.c_void_p * 2)]


class Variant(ct.Structure):
    _fields_ = [('vt', ct.c_ushort), ('reserved', ct.c_ushort * 3), ('value', Value)]

    @classmethod
    def argument(cls, obj):
        v = cls()
        if isinstance(obj, str):
            v.vt, v.value.pointer = 8, oleaut.SysAllocString(obj)
        elif isinstance(obj, int):
            v.vt, v.value.int32 = 3, obj
        elif isinstance(obj, (list, tuple)):
            v.vt = 0x200c  # VT_ARRAY | VT_VARIANT, as required by ADO OpenSchema.
            v.value.pointer = oleaut.SafeArrayCreateVector(12, 0, len(obj))
            for i, entry in enumerate(obj):
                element = cls.argument(entry)
                try:
                    check(oleaut.SafeArrayPutElement(v.value.pointer, ct.byref(ct.c_long(i)), ct.byref(element)))
                finally:
                    oleaut.VariantClear(ct.byref(element))
        elif obj is not None:
            raise TypeError(type(obj))
        return v

    def python(self):
        if self.vt == 0x200c:
            # ADO GetRows: VARIANT[field, record]. Copy values before VariantClear.
            ptr=self.value.pointer
            if oleaut.SafeArrayGetDim(ptr)!=2:raise ValueError('Expected a two-dimensional ADO GetRows array')
            lengths=[]
            for dim in (1,2):
                lo,hi=ct.c_long(),ct.c_long()
                check(oleaut.SafeArrayGetLBound(ptr,dim,ct.byref(lo)))
                check(oleaut.SafeArrayGetUBound(ptr,dim,ct.byref(hi)))
                lengths.append(hi.value-lo.value+1)
            raw=ct.c_void_p();check(oleaut.SafeArrayAccessData(ptr,ct.byref(raw)))
            try:
                values=ct.cast(raw,ct.POINTER(Variant));fields,rows=lengths
                return [tuple(values[row*fields+col].python() for col in range(fields)) for row in range(rows)]
            finally:check(oleaut.SafeArrayUnaccessData(ptr))
        if self.vt in (0, 1):
            return None
        if self.vt == 9:
            # Transfer COM's owned reference from the output variant.
            self.vt = 0
            return Dispatch(self.value.pointer) if self.value.pointer else None
        if self.vt == 8:
            return ct.wstring_at(self.value.pointer, oleaut.SysStringLen(self.value.pointer)) if self.value.pointer else ''
        if self.vt == 11:
            return bool(self.value.int16)
        if self.vt in (2, 3, 20):
            return {2: self.value.int16, 3: self.value.int32, 20: self.value.int64}[self.vt]
        converted = Variant()
        try:
            target = 5 if self.vt in (4, 5, 6, 14) else 8
            check(oleaut.VariantChangeType(ct.byref(converted), ct.byref(self), 0, target))
            return converted.value.double if target == 5 else converted.python()
        finally:
            oleaut.VariantClear(ct.byref(converted))


class Params(ct.Structure):
    _fields_ = [('args', ct.POINTER(Variant)), ('named', ct.POINTER(ct.c_long)),
                ('count', ct.c_uint), ('named_count', ct.c_uint)]


class ExceptionInfo(ct.Structure):
    _fields_ = [('code', ct.c_ushort), ('reserved', ct.c_ushort), ('source', ct.c_void_p),
                ('description', ct.c_void_p), ('help', ct.c_void_p), ('context', ct.c_ulong),
                ('internal', ct.c_void_p), ('deferred', ct.c_void_p), ('error', ct.c_long)]


def check(hr, message=''):
    if hr < 0:
        raise RuntimeError(message or f'Windows ADO returned HRESULT 0x{hr & 0xffffffff:08x}')


class Dispatch:
    def __init__(self, pointer):
        self.pointer = ct.c_void_p(pointer)
        self.vtable = ct.cast(self.pointer, ct.POINTER(ct.POINTER(ct.c_void_p))).contents

    def method(self, slot, *argtypes):
        return ct.WINFUNCTYPE(ct.c_long, ct.c_void_p, *argtypes)(self.vtable[slot])

    def release(self):
        if self.pointer:
            self.method(2)(self.pointer)
            self.pointer = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.release()

    def call(self, name, *args, flags=1):
        names = (ct.c_wchar_p * 1)(name)
        dispid = ct.c_long()
        lookup = self.method(5, ct.c_void_p, ct.c_void_p, ct.c_uint, ct.c_ulong, ct.c_void_p)
        check(lookup(self.pointer, ct.byref(IID_NULL), names, 1, 0, ct.byref(dispid)))
        argv = (Variant * len(args))(*(Variant.argument(v) for v in reversed(args)))
        putid = ct.c_long(-3)
        params = Params(argv, ct.pointer(putid) if flags == 4 else None, len(args), int(flags == 4))
        result, exc = Variant(), ExceptionInfo()
        invoke = self.method(6, ct.c_long, ct.c_void_p, ct.c_ulong, ct.c_ushort,
                             ct.c_void_p, ct.c_void_p, ct.c_void_p, ct.c_void_p)
        try:
            hr = invoke(self.pointer, dispid, ct.byref(IID_NULL), 0, flags, ct.byref(params),
                        ct.byref(result), ct.byref(exc), None)
            check(hr, ct.wstring_at(exc.description) if exc.description else '')
            return result.python()
        finally:
            oleaut.VariantClear(ct.byref(result))
            for v in argv:
                oleaut.VariantClear(ct.byref(v))
            for bstr in (exc.source, exc.description, exc.help):
                if bstr:
                    oleaut.SysFreeString(bstr)

    def get(self, name, *args):
        return self.call(name, *args, flags=2)


@contextmanager
def connect(server=r'localhost\COMPANYXOLAP', database=''):
    """A single-threaded Windows COM session owned by the calling thread."""
    ole32.CoInitializeEx(None, 2)
    try:
        clsid = (ct.c_ubyte * 16)()
        ole32.CLSIDFromProgID('ADODB.Connection', ct.byref(clsid))
        ptr = ct.c_void_p()
        ole32.CoCreateInstance(ct.byref(clsid), None, 1, ct.byref(IID_DISPATCH), ct.byref(ptr))
        with Dispatch(ptr.value) as conn:
            conn.call('ConnectionTimeout', 10, flags=4)
            conn.call('CommandTimeout', 1800, flags=4)
            # Callers specify either the fixed local cube or a localhost Desktop engine.
            if ';' in server or ';' in database:
                raise ValueError('Invalid SSAS connection target')
            catalog = f'Initial Catalog={database};' if database else ''
            conn.call('Open', f'Provider=MSOLAP.8;Data Source={server};{catalog}Integrated Security=SSPI;')
            try:
                yield conn
            finally:
                conn.call('Close')
    finally:
        ole32.CoUninitialize()


def read_recordset(rs):
    with rs.get('Fields') as fields:
        columns = []
        try:
            for i in range(fields.get('Count')):
                columns.append(fields.get('Item', i))
            names = [field.get('Name') for field in columns]
            rows = []
            while not rs.get('EOF'):
                rows.append(tuple(field.get('Value') for field in columns))
                rs.call('MoveNext')
            return names, rows
        finally:
            for field in columns:
                field.release()


def query(conn, statement):
    """Return column names and typed Python tuples from a flattened MDX/DMV rowset."""
    with conn.call('Execute', statement) as rs:
        return read_recordset(rs)

def query_fast(conn,statement):
    """Batch reads of large cube input contracts without per-cell COM calls."""
    with conn.call('Execute',statement) as rs:
        with rs.get('Fields') as fields:
            names=[]
            for i in range(fields.get('Count')):
                with fields.get('Item',i) as f:names.append(f.get('Name'))
        rows=[]
        while not rs.get('EOF'):
            chunk=rs.call('GetRows',4096)
            if not chunk or any(len(r)!=len(names) for r in chunk):raise RuntimeError('Invalid ADO batch shape')
            rows.extend(chunk)
        return names,rows
