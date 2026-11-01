import sys,struct,pickle,bisect,collections
d=open(sys.argv[1],'rb').read()
addr,size,starts=pickle.load(open(sys.argv[2],'rb'))
n=size//4; ins=struct.unpack_from('<%dI'%n,d,22000)
targets=[int(x,16) for x in sys.argv[3:]]
for tg in targets:
    c=collections.Counter()
    for i,v in enumerate(ins):
        if (v&0xfc000000)==0x94000000:
            t=addr+i*4+(((v&0x3ffffff)^0x2000000)-0x2000000)*4
            if t==tg: c[starts[bisect.bisect_right(starts,addr+i*4)-1]]+=1
    print(hex(tg),[(hex(f),k) for f,k in c.most_common(12)])
