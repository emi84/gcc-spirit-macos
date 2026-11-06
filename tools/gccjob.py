# Relit un travail déjà imprimé (le PDF reçu par CUPS) : python3 tools/gccjob.py <dossier> <n° de travail>...
import socket,struct,sys,getpass
def attr(tag,name,val):
    n=name.encode(); return bytes([tag])+struct.pack('>H',len(n))+n+struct.pack('>H',len(val))+val
def fetch(job,out):
    u=getpass.getuser().encode()
    b=b'\x02\x00'+struct.pack('>H',0x4027)+struct.pack('>I',1)+b'\x01'
    b+=attr(0x47,'attributes-charset',b'utf-8')+attr(0x48,'attributes-natural-language',b'en')
    b+=attr(0x45,'printer-uri',b'ipp://localhost/printers/GCC_Spirit')
    b+=attr(0x21,'job-id',struct.pack('>I',job))+attr(0x21,'document-number',struct.pack('>I',1))
    b+=attr(0x42,'requesting-user-name',u)+b'\x03'
    s=socket.socket(socket.AF_UNIX); s.connect('/private/var/run/cupsd')
    h=b'POST / HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/ipp\r\nAuthorization: PeerCred '+u+b'\r\nConnection: close\r\nContent-Length: %d\r\n\r\n'%len(b)
    s.sendall(h+b); d=b''
    while True:
        c=s.recv(1<<20)
        if not c: break
        d+=c
    hd,_,body=d.partition(b'\r\n\r\n')
    print(job,hd.split(b'\r\n')[0],len(body))
    if b'chunked' in hd.lower():
        o=b'';i=0
        while True:
            j=body.index(b'\r\n',i); n=int(body[i:j].split(b';')[0],16)
            if n==0: break
            o+=body[j+2:j+2+n]; i=j+2+n+2
        body=o
    print(' ipp status',body[2:4].hex() if len(body)>4 else body)
    k=body.find(b'%PDF')
    if k>=0: open(out,'wb').write(body[k:]); print(' pdf',len(body)-k)
for j in map(int, sys.argv[2:]): fetch(j, sys.argv[1] + "/job%d.pdf" % j)
