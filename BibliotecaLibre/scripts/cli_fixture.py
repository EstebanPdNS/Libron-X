"""Generate only project-owned synthetic LSF/LIX CLI fixtures.

Wire construction follows the existing ReaderOutputTests.OutputFixture, with
the cumulative character-count chunk needed by locator checks. No proprietary
bytes, application artifacts, or commercial book content are used.
"""
from pathlib import Path
import struct
import tempfile

def generate():
    root = Path(tempfile.mkdtemp(prefix='libronx-cli-fixture-')).resolve()
    w = lambda n: struct.pack('<H', n)
    d = lambda n: struct.pack('<I', n)
    bodies = ['Own first 🦉.', 'Own second <tag>.', 'Own following heading', 'Own next chapter.']
    references = ['Xy 1:1', 'Xy 1:2', None, 'Xy 2:1']
    identity = bytes.fromhex('01000000030000003500')
    def article(text, reference):
        encoded = text.encode('utf-16le'); length = len(encoded) // 2
        value = bytearray(20)
        struct.pack_into('<H', value, 4, 17); struct.pack_into('<I', value, 6, 1)
        struct.pack_into('<HH', value, 10, 1, 1); struct.pack_into('<I', value, 16, length)
        value += w(1)+w(1)+w(1 if reference is None else 2)+d(10000)+w(0)+d(length+1)
        if reference: value += w(81)+w(128)+w(2)+w(len(reference.encode()))+reference.encode()
        value += w(17)+w(0 if reference is None else 0x8000)+w(0)+w(length)+w(1033)+b'\xf0'+encoded+w(0)
        struct.pack_into('<I', value, 0, len(value)); return bytes(value)
    def chunk(tag, data=b'', children=()): return (tag, data, children)
    def container(kind, chunks):
        def size(c): return len(c[1]) if not c[2] else sum(8+size(x) for x in c[2])
        def count(c): return 1+sum(count(x) for x in c[2])
        table_size = 18+18*sum(count(c) for c in chunks)
        header = bytearray(44); header[:4]=b'LSFF'; header[8:12]=kind.encode(); header[36:40]=b'pcr '
        struct.pack_into('<I', header, 40, table_size)
        table = bytearray(18); table[:4]=b'LSFF'; table[4:8]=kind.encode()
        def emit(c, offset):
            tag, data, children = c; length = size(c)
            table.extend(tag.encode()+d(0)+d(length)+d(offset+8)+w(len(children)))
            result = tag.encode()+d(length)
            if children:
                for child in children: result += emit(child, offset+len(result))
            else: result += data
            return result
        payload=b''
        for c in chunks: payload += emit(c, 44+table_size+len(payload))
        result=header+table+payload; struct.pack_into('<I', result, 4, len(result)-8)
        return result
    typography = w(1)+w(1)+w(1)+w(8)+b'Own Text'+w(5)+b'Arial'+w(2)
    for i in range(2):
        typography += w(1)+d(0x4000000 if i else 0)+d(0)+w(1033)+w(0)
        typography += w(480 if i else 240)+w(0)*3+w(700 if i else 400)
        typography += bytes([0,0,0,1,0,0,0,0x20])+b'Arial'+b'\0'*27+w(0)
    typography += w(1)+w(1)+(w(1)+w(1)+w(0)+w(0)+d(0))*4+d(0)*2
    typography += b''.join(w(x) for x in [10000,10000,0,0,0,0,0,0,0,3])+b'Own'+w(5)+w(0)*2
    tart=hits=keys=named=labels=reverse=counts=b''; cumulative=0
    for i,(body,reference) in enumerate(zip(bodies,references)):
        raw=article(body, reference); offset=len(tart); tart+=w(0)+d(len(raw))+raw
        hits+=d(i)+d(offset)+d(len(keys))+d(0x80000000)+d(i)+bytes([1 if i in (0,3) else 0])
        title=f'Own article {i}'.encode('utf-16le'); keys+=w(len(title)//2)+title+w(0)
        label='Xy.CH1' if i==0 else 'Xy.CH2' if i==3 else f'Own.{i}'
        named+=d(len(labels))+d(i); labels+=label.encode()+b'\0'; reverse+=d(i)
        cumulative+=len(body.encode('utf-16le'))//2; counts+=d(cumulative)
    lsf=root/'own.LSF'; lix=root/'own.LIX'
    lsf.write_bytes(container('GTTL',[chunk('bkid',identity),chunk('tart',tart),chunk('ttbl',typography)]))
    aidx=chunk('AIDX',children=[chunk('info',w(0)+d(4)+d(4)+w(1)),chunk('hlst',hits),chunk('klst',keys)])
    cidx=chunk('CIDX',children=[chunk('info',w(0)+d(4)),chunk('hlst',named),chunk('klst',labels),chunk('coff',reverse)])
    lix.write_bytes(container('BIDX',[chunk('bkid',w(1)+identity),aidx,cidx,chunk('ccct',counts)]))
    return {'root':str(root),'file':str(lsf),'id':'LLS:1.0.3','text':bodies[0]}
