import sys, re, collections, json
def tokenize(data):
    assert data[:4]==b'SLF0'
    i=4; n=len(data); classes=[]; toks=[]
    hexset=set(b'0123456789abcdef')
    while i<n:
        if data[i]==0x2d:
            toks.append(('null',)); i+=1; continue
        j=i
        while j<n and data[j] in hexset: j+=1
        if j==i or j>=n: 
            toks.append(('ERR',i,data[i:i+20])); break
        num=data[i:j]; t=chr(data[j]); j+=1
        if t=='#': toks.append(('int',int(num,10))); i=j
        elif t=='"':
            L=int(num,10); toks.append(('str',data[j:j+L].decode('utf8','replace'))); i=j+L
        elif t=='*':
            L=int(num,10); toks.append(('json',data[j:j+L].decode('utf8','replace'))); i=j+L
        elif t=='%':
            L=int(num,10); name=data[j:j+L].decode(); classes.append(name); toks.append(('cls',name)); i=j+L
        elif t=='@': toks.append(('inst',int(num,10))); i=j
        elif t=='(': toks.append(('arr',int(num,10))); i=j
        elif t=='^': toks.append(('dbl',num.decode())); i=j
        elif t=='-': toks.append(('null',)); i=j
        else:
            toks.append(('ERR',i,t,data[i:i+20])); break
    return toks, classes
if __name__=='__main__':
    d=open(sys.argv[1],'rb').read()
    toks,classes=tokenize(d)
    print('tokens',len(toks),'last',toks[-1][:2] if toks else None)
    err=[t for t in toks if t[0]=='ERR']; print('errors',err[:3])
    inst=collections.Counter(t[1] for t in toks if t[0]=='inst')
    print('classes (index: name: instance refs):')
    for k,name in enumerate(classes,1): print(f'  {k:3d} {name}: {inst.get(k,0)}')
    print('token kinds', collections.Counter(t[0] for t in toks))
    pat=re.compile(r'^(Compile|Swift|Ld |Link|Process|Copy|Ditto|CodeSign|PhaseScriptExecution|Emit|Scan|Precompile|Planning|Compute|Create|Write|Generate|Validate|Touch|Register|Mkdir|Sign|Build description|Prepare|Resolve|Extract|Construct|Clean|Remove|Build|Link)')
    c=collections.Counter()
    for t in toks:
        if t[0]=='str' and pat.match(t[1]) and '\n' not in t[1]:
            c[re.sub(r' /.*','',t[1])[:70]]+=1
    print('step titles (first-line strings):')
    for k,v in c.most_common(80): print(f'  {v:5d} {k}')
