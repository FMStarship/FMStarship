import sys,struct,subprocess,re,bisect
b=sys.argv[1]
d=open(b,'rb').read()
# __text bounds
hdr=subprocess.run(['otool','-l',b],capture_output=True,text=True).stdout
m=re.search(r'sectname __text\n\s+segname __TEXT\n\s+addr (0x[0-9a-f]+)\n\s+size (0x[0-9a-f]+)\n\s+offset (\d+)',hdr)
addr,size,off=int(m[1],16),int(m[2],16),int(m[3])
print('text',hex(addr),hex(size),off)
n=size//4
ins=struct.unpack_from('<%dI'%n,d,off)
# function starts from LC_FUNCTION_STARTS
fs=subprocess.run(['otool','-l',b],capture_output=True,text=True).stdout
m2=re.search(r'cmd LC_FUNCTION_STARTS\n\s+cmdsize \d+\n\s+dataoff (\d+)\n\s+datasize (\d+)',fs)
starts=[]
if m2:
    o,sz=int(m2[1]),int(m2[2]); p=o; a=0; end=o+sz
    while p<end:
        v=0;s=0
        while True:
            c=d[p];p+=1
            v|=(c&0x7f)<<s;s+=7
            if not c&0x80:break
        if v==0:break
        a+=v;starts.append(a)
print('function starts',len(starts))
import pickle
pickle.dump((addr,size,starts),open(sys.argv[2],'wb'))
def fn(a):
    i=bisect.bisect_right(starts,a)-1
    return starts[i] if i>=0 else None
# MOVZ W/X, #0x2710 ; CMP/SUBS Wn,#imm with 0x2710 is not encodable directly except shifted; find movz only
hits={}
for i,v in enumerate(ins):
    if (v&0x7fffffe0)==0x5284e200:  # movz w/x d, #0x2710
        a=addr+i*4
        hits.setdefault(fn(a),[]).append(a)
print('functions using movz #10000:',len(hits))
vt=[int(x,16) for x in sys.argv[3:]]
print('vtable slots that use 10000:',[(i,hex(x)) for i,x in enumerate(vt) if x in hits])
open(sys.argv[2]+'.txt','w').write('\n'.join(hex(k) for k in sorted(hits)))
