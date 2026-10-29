"""Generate original demo audio and metadata for isolated simulator screenshots.

No user media is read. Audio is three minutes of silence, encoded by macOS
afconvert; the cover is an original vector-style composition drawn by Swift.
Usage: python3 capture-fixtures.py OUTPUT_DIRECTORY COVER_PNG
"""
from pathlib import Path
import struct
import subprocess
import sys
import wave

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
cover = Path(sys.argv[2]).read_bytes()
wav = root / "original-silence.wav"
with wave.open(str(wav), "wb") as stream:
    stream.setnchannels(1)
    stream.setsampwidth(2)
    stream.setframerate(44100)
    stream.writeframes(b"\0\0" * (44100 * 180))
base = root / "original-silence.flac"
subprocess.run(["/usr/bin/afconvert", str(wav), str(base), "-f", "flac", "-d", "flac"], check=True)
raw = base.read_bytes()
assert raw[:4] == b"fLaC"
blocks = []
offset = 4
while True:
    kind = raw[offset] & 127
    last = bool(raw[offset] & 128)
    length = int.from_bytes(raw[offset + 1:offset + 4], "big")
    if kind != 4 and kind != 6:
        blocks.append((kind, raw[offset + 4:offset + 4 + length]))
    offset += 4 + length
    if last:
        break
audio = raw[offset:]

def be(value):
    return struct.pack(">I", value)

def le(value):
    return struct.pack("<I", value)

def make_track(title, path):
    comments = [f"TITLE={title}", "ARTIST=随身音乐", "ALBUM=山海之间"]
    vendor = b"WatchMusic original screenshot demo"
    tags = le(len(vendor)) + vendor + le(len(comments))
    for comment in comments:
        encoded = comment.encode()
        tags += le(len(encoded)) + encoded
    picture = be(3) + be(9) + b"image/png" + be(0) + be(1024) + be(1024) + be(24) + be(0) + be(len(cover)) + cover
    new_blocks = blocks + [(4, tags), (6, picture)]
    result = bytearray(b"fLaC")
    for i, (kind, content) in enumerate(new_blocks):
        result.append(kind | (128 if i == len(new_blocks) - 1 else 0))
        result.extend(len(content).to_bytes(3, "big"))
        result.extend(content)
    result.extend(audio)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(result)

library = {
    "日常精选": ["清晨漫步", "山海之间", "夜色回声", "向光而行", "微风来信", "沿途风景"],
    "跑步节拍": ["城市脉搏", "迎风奔跑", "下一公里", "心跳节奏"],
    "睡前时光": ["静谧星河", "月光海岸", "慢慢入梦"],
    "旅行随听": ["远方的山", "日落公路", "海岸线", "云端来信", "晴空之外"],
}
for folder, titles in library.items():
    for title in titles:
        make_track(title, root / "Music" / folder / f"{title}.flac")
make_track("清晨漫步", root / "watch-player" / "测试旋律.flac")
wav.unlink()
base.unlink()
print(f"Created {sum(map(len, library.values()))} original demo tracks and Watch preview track")
