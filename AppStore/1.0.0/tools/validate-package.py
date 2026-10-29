#!/usr/bin/env python3
"""Check upload dimensions, PNG encoding, metadata limits and four-page deployment."""
from pathlib import Path
from html.parser import HTMLParser
import base64,hashlib,json,re,struct,zipfile

root=Path(__file__).resolve().parents[1]
repo=root.parents[1]
assets=[]
for locale in ('zh-Hans','en-US'):
    for n in range(1,5):
        assets.append((f'screenshots/{locale}/iphone/0{n}.png',(1320,2868),'iphone',locale))
    assets.extend([(f'creative/header-{locale}.png',(3840,1646),'header',locale),
                   (f'creative/search-{locale}.png',(1920,1280),'search',locale)])
for n in range(1,5):assets.append((f'screenshots/watch/0{n}.png',(422,514),'watch','shared'))
manifest=[]
for name,size,kind,locale in assets:
    data=(root/name).read_bytes()
    assert data[:8]==b'\x89PNG\r\n\x1a\n', name
    width,height,depth,color=struct.unpack('>IIBB',data[16:26])
    assert (width,height)==size,(name,width,height)
    assert depth==8 and color==2,(name,'expected opaque RGB, no alpha channel',depth,color)
    assert b'tRNS' not in data, (name,'unexpected transparency chunk')
    manifest.append(dict(file=name,width=width,height=height,kind=kind,locale=locale,
                         encoding='RGB PNG; no alpha',sha256=hashlib.sha256(data).hexdigest()))
metadata=json.loads((root/'metadata.json').read_text())
for locale,fields in metadata.items():
    for name,item in fields.items():
        value=item['value'];assert len(value)==item['characters'];assert len(value.encode())==item['utf8Bytes']
        if name=='keywords':
            assert len(value.encode())<=100
            terms=value.split(',');assert all(len(t)>2 for t in terms);assert len(set(t.lower() for t in terms))==len(terms)
        else:assert len(value)<={'name':30,'subtitle':30,'promotionalText':170,'description':4000}[name]

class ResourceParser(HTMLParser):
    def __init__(self):super().__init__();self.resources=[];self.links=[]
    def handle_starttag(self,tag,attrs):
        a=dict(attrs)
        if tag in ('img','script','iframe','source') and a.get('src'):self.resources.append(a['src'])
        if tag=='link' and a.get('href'):self.resources.append(a['href'])
        if tag=='a' and a.get('href'):self.links.append(a['href'])
archive=repo/'Artifacts/Deployment/watchmusic-marketing-1.0.0.zip'
with zipfile.ZipFile(archive) as z:
    expected={'index.html','privacy.html','terms.html','support.html'}
    assert set(z.namelist())==expected,z.namelist()
    for name in sorted(expected):
        data=z.read(name);html=data.decode('utf8');parser=ResourceParser();parser.feed(html)
        assert all(r.startswith('data:') for r in parser.resources),(name,'external resource')
        assert not re.findall(r'url\(\s*[\'\"]?(?:https?:|//|assets/)',html),(name,'external CSS asset')
        for resource in parser.resources:
            if resource.startswith('data:image/png;base64,'):
                assert base64.b64decode(resource.split(',',1)[1]).startswith(b'\x89PNG')
        for link in parser.links:
            if not re.match(r'^(?:https?:|mailto:|#)',link):assert link.split('#')[0] in expected,(name,link)
        if name!='index.html':assert data==(repo/'PhoneApp/Legal'/name).read_bytes()
(root/'manifest.json').write_text(json.dumps({'version':'1.0.0','date':'2026-10-29','assets':manifest},ensure_ascii=False,indent=2)+'\n')
print(f'PASS: {len(manifest)} upload PNGs, 10 metadata fields, exact 4 self-contained HTML pages.')
print('Keywords: '+', '.join(f'{k} {v["keywords"]["utf8Bytes"]}/100 bytes' for k,v in metadata.items()))
