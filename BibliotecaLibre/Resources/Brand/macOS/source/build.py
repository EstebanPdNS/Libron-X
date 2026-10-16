from pathlib import Path
import json,re

ROOT=Path(__file__).resolve().parents[1]
contour=json.loads((ROOT/'reference/tile-contour.json').read_text())['d']
bounds=json.loads((ROOT/'reference/book-bounds.json').read_text())
scale=548/bounds['width']
tx=512-scale*(bounds['x']+bounds['width']/2)
# Revised position: previous +7%, then moved up 4%; net +3%, or 30.72 px.
ty=507+30.72-scale*(bounds['y']+bounds['height']/2)
variants=[('Red','white',['#ff2938','#ec0812','#d30713']),('Black','red',['#323234','#242426','#151517'])]
for name,color,stops in variants:
    original=(ROOT/'reference'/f'book-{color}.svg').read_text()
    body=original[original.index('<g id="original-book">'):original.rindex('</svg>')].strip()
    if name=='Black':
        body=body.replace('fill="#ec0812"','fill="url(#emblem-red)"')
    shadow=re.sub(r'fill="[^"]+"','fill="#000000"',body)
    svg=f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-label="Libron X, icono {'rojo' if name=='Red' else 'negro y rojo'} para macOS">
<title>Libron X · {'Rojo' if name=='Red' else 'Negro y rojo'} · macOS</title>
<defs>
<path id="tile" d="{contour}" transform="translate(100 100) scale(.8046875)"/>
<linearGradient id="background" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse"><stop stop-color="{stops[0]}"/><stop offset=".48" stop-color="{stops[1]}"/><stop offset="1" stop-color="{stops[2]}"/></linearGradient>
<linearGradient id="edge" x1="220" y1="100" x2="810" y2="940" gradientUnits="userSpaceOnUse"><stop stop-color="#ffffff" stop-opacity=".37"/><stop offset=".5" stop-color="#ffffff" stop-opacity=".04"/><stop offset="1" stop-color="#ffffff" stop-opacity=".19"/></linearGradient>
<linearGradient id="emblem-red" x1="0" y1="175" x2="0" y2="819" gradientUnits="userSpaceOnUse"><stop stop-color="#ff3945"/><stop offset=".55" stop-color="#ec0812"/><stop offset="1" stop-color="#d40716"/></linearGradient>
<filter id="tile-shadow" x="-25%" y="-25%" width="150%" height="165%" color-interpolation-filters="sRGB"><feDropShadow dx="0" dy="16" stdDeviation="13" flood-color="#000000" flood-opacity=".23"/></filter>
<filter id="emblem-lift" x="-25%" y="-25%" width="150%" height="165%" color-interpolation-filters="sRGB"><feDropShadow dx="0" dy="8" stdDeviation="6" flood-color="#000000" flood-opacity="{'0.16' if name=='Red' else '0.36'}"/></filter>
</defs>
<use href="#tile" fill="#000000" filter="url(#tile-shadow)"/>
<use href="#tile" fill="url(#background)"/>
<use href="#tile" fill="none" stroke="url(#edge)" stroke-width="2.8"/>
<g transform="translate({tx} {ty}) scale({scale})" filter="url(#emblem-lift)">{shadow}</g>
<g id="original-emblem" transform="translate({tx} {ty}) scale({scale})">{body}</g>
</svg>'''
    (ROOT/f'LibronX-{name}.svg').write_text(svg)
print('Built both macOS SVG masters from the unchanged original emblem paths.')
