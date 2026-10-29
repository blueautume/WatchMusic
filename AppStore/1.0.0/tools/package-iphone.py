#!/usr/bin/env python3
"""Package the iPhone images accepted by the current medium-display slot."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import struct

root=Path(__file__).resolve().parents[1]
archive=root.parents[1]/'Artifacts/Deployment/watchmusic-iphone-1206x2622.zip'
readme='''WatchMusic iPhone 截图修正版

统一尺寸：1206 × 2622 px，RGB PNG，无透明通道。
上传位置：带灵动岛的 iPhone（中等显示屏）。

简体中文本地化上传 zh-Hans/ 里的 01.png—04.png；
English (U.S.) 本地化上传 en-US/ 里的同名图片。
每个本地化选择对应的一套图片。

这8张是重新导出的修正版，替换此前1320×2868手机宣传图。
'''
with ZipFile(archive,'w',ZIP_DEFLATED) as z:
    z.writestr('上传说明.txt',readme)
    for locale in ['zh-Hans','en-US']:
        for n in range(1,5):
            image=root/f'screenshots/{locale}/iphone/0{n}.png'
            assert struct.unpack('>IIBB',image.read_bytes()[16:26])==(1206,2622,8,2)
            z.write(image,f'{locale}/0{n}.png')
print(archive)
