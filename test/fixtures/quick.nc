%
(quick: a 60 x 40 box 2 mm deep in two passes, then a 30 mm circle)
(spiralled down 3 mm; about a minute. Zero X/Y at the front-left corner,)
(Z on the stock's surface: the file lifts to Z5 between moves.)
G21 G90 G17
S16000 M3
G0 Z5
G0 X0 Y0
(box, pass 1)
G1 Z-1 F300
G1 X60 F1200
G1 Y40
G1 X0
G1 Y0
(box, pass 2)
G1 Z-2 F300
G1 X60 F1200
G1 Y40
G1 X0
G1 Y0
G0 Z5
(circle: centre X100 Y20, radius 15, three turns spiralling to Z-3)
G0 X85 Y20
G1 Z0 F300
G2 X85 Y20 I15 J0 Z-1 F1000
G2 X85 Y20 I15 J0 Z-2
G2 X85 Y20 I15 J0 Z-3
G2 X85 Y20 I15 J0
G0 Z5
M5
G0 X0 Y0
M30
%
