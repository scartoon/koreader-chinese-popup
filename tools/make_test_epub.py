#!/usr/bin/env python3
"""Write a small EPUB for testing taps on a device: mixed Chinese/English text,
traditional characters, digits, punctuation, and words split by inline tags.

    python3 tools/make_test_epub.py build/chinesepopup-test.epub
"""
import sys
import zipfile

PARAS = [
    # Latin and digits between Chinese: taps on them must turn the page.
    "他昨天读了 The Economist 的一篇文章，觉得很靠谱。",
    # Traditional characters: matched through CC-CEDICT's traditional column.
    "這個歷史挺靠譜，國家圖書館裡有很多。",
    "Numbers like 2026 年 and 中华人民共和国成立的时候。",
    # Inline tags inside words: the context walk must cross them.
    "这是<b>中</b>国的<i>历</i>史，也是<span>世界</span>的历史。",
    # Paragraph boundary with Han characters on both sides.
    "第一段结尾是汉字",
    "第二段开头也是汉字",
    "A paragraph in English only, to tap on Latin text: the quick brown fox jumps over the lazy dog.",
]

CONTAINER = """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"""

OPF = """<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Chinese popup test</dc:title><dc:language>zh</dc:language>
    <dc:identifier id="id">chinesepopup-test</dc:identifier>
  </metadata>
  <manifest>
    <item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="text"/></spine>
</package>"""

NCX = """<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="chinesepopup-test"/></head>
  <docTitle><text>Chinese popup test</text></docTitle>
  <navMap><navPoint id="p1" playOrder="1"><navLabel><text>Test</text></navLabel>
  <content src="text.xhtml"/></navPoint></navMap>
</ncx>"""


def xhtml():
    body = "\n".join(f"<p>{p}</p>" for p in PARAS)
    return f"""<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh"><head><title>Test</title></head>
<body><h2>测试页</h2>
{body}
</body></html>"""


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "chinesepopup-test.epub"
    with zipfile.ZipFile(out, "w") as z:
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", CONTAINER, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/content.opf", OPF, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/toc.ncx", NCX, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/text.xhtml", xhtml(), compress_type=zipfile.ZIP_DEFLATED)
    print(f"Wrote {out}")


if __name__ == "__main__":
    main()
