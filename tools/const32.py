import sys,struct,pickle,bisect
d=open(sys.argv[1],'rb').read()
addr,size,starts=pickle.load(open(sys.argv[2],'rb'))
n=size//4; ins=struct.unpack_from('<%dI'%n,d,22000)
val=int(sys.argv[3],16); lo=val&0xffff; hi=val>>16
for i,v in enumerate(ins):
    if (v&0xffe00000)==0x72a00000 and ((v>>5)&0xffff)==hi:
        rd=v&31
        for k in range(max(0,i-4),i):
            w=ins[k]
            if (w&0xffe0001f)==(0x52800000|rd) and ((w>>5)&0xffff)==lo:
                a=addr+i*4; f=starts[bisect.bisect_right(starts,a)-1]
                # next bl
                t=None
                for j in range(i,min(i+12,n)):
                    x=ins[j]
                    if (x&0xfc000000)==0x94000000:
                        t=addr+j*4+(((x&0x3ffffff)^0x2000000)-0x2000000)*4; break
                print(hex(a),'in fn',hex(f),'next bl',hex(t) if t else None)
