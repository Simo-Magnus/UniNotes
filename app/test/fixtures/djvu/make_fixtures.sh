#!/bin/sh
# Rigenera i file DjVu di prova e le immagini di riferimento con DjVuLibre
# (strumenti esterni, usati solo qui: il decodificatore dell'app è scritto
# dalla specifica). Serve: djvulibre-bin, minidjvu, ghostscript,
# imagemagick, python3.
#   sudo apt-get install djvulibre-bin minidjvu ghostscript imagemagick
set -e
cd "$(dirname "$0")"
T=$(mktemp -d)

# Pagina bitonale con livello di testo (cjb2 + djvused).
convert -size 600x300 xc:white -fill black -pointsize 36 \
  -annotate +20+60 'Teorema di Rolle' -pointsize 24 \
  -annotate +20+120 'Sia f continua in [a,b] e derivabile' \
  -annotate +20+170 'in (a,b), con f(a) = f(b).' \
  -draw "circle 500,230 540,260" -monochrome "$T/text.pbm"
cjb2 "$T/text.pbm" bitonal.djvu
printf '%s' '(page 0 0 600 300 (line 20 230 400 270 (word 20 230 270 270 "Teorema") (word 280 230 400 270 "di")) (line 20 130 500 160 (word 20 130 200 160 "perché") (word 210 130 500 160 "continua")))' > "$T/txt"
djvused bitonal.djvu -e "select 1; set-txt $T/txt" -s
ddjvu -format=pbm bitonal.djvu bitonal.pbm

# Foto a colori e in grigio (c44).
convert logo: -resize 160x120 "$T/logo.ppm"
c44 "$T/logo.ppm" photo.djvu
ddjvu -format=ppm photo.djvu "$T/photo.ppm" && convert "$T/photo.ppm" photo.png
c44 -crcbhalf "$T/logo.ppm" chroma_half.djvu
ddjvu -format=ppm chroma_half.djvu "$T/half.ppm" && convert "$T/half.ppm" chroma_half.png
convert "$T/logo.ppm" -colorspace Gray "$T/logo.pgm"
c44 "$T/logo.pgm" gray.djvu
ddjvu -format=pgm gray.djvu "$T/gray.pgm" && convert "$T/gray.pgm" gray.png

# Pagina composta: maschera JB2, primo piano FG44 (1/12), sfondo BG44 (1/3).
cat > "$T/p.ps" <<'EOF'
%!PS
/Times-Roman findfont 14 scalefont setfont
50 280 moveto (Pagina composta: testo nero su sfondo sfumato) show
50 250 moveto (Il primo piano ha i colori di una piccola immagine) show
/Helvetica-Bold findfont 30 scalefont setfont 50 180 moveto (DjVu) show
showpage
EOF
gs -q -dNOPAUSE -dBATCH -sDEVICE=pbmraw -r100 -g600x450 -sOutputFile="$T/mask.pbm" "$T/p.ps"
cjb2 "$T/mask.pbm" "$T/mask.djvu"
convert -size 200x150 gradient:yellow-skyblue "$T/bg.ppm" && c44 "$T/bg.ppm" "$T/bg.djvu"
convert -size 50x38 gradient:red-blue "$T/fg.ppm" && c44 -slice 100 "$T/fg.ppm" "$T/fg.djvu"
python3 iffbuild.py compound.djvu 600 450 100 1 Sjbz="$T/mask.djvu" \
  FG44="$T/fg.djvu:BG44" BG44="$T/bg.djvu"
ddjvu -format=ppm compound.djvu "$T/compound.ppm" && convert "$T/compound.ppm" compound.png

# Colori per forma (FGbz).
convert -size 300x200 xc:white -fill red -draw "rectangle 20,20 120,90" \
  -fill blue -draw "circle 200,120 240,160" -fill green -pointsize 30 \
  -annotate +20+170 'Colori' "$T/pal.ppm"
cpaldjvu "$T/pal.ppm" palette.djvu
ddjvu -format=ppm palette.djvu "$T/pal.ppm" && convert "$T/pal.ppm" palette.png

# Documento raggruppato: 3 pagine, segnalibri, pagina ruotata.
djvm -c bundled.djvu bitonal.djvu photo.djvu compound.djvu
printf '%s' '(bookmarks ("Inizio" "#1") ("Foto" "#2" ("Composta" "#3")))' > "$T/outline"
djvused bundled.djvu -e "set-outline $T/outline" -s
djvused bundled.djvu -e 'select 2; set-rotation 1' -s
ddjvu -format=ppm -page=2 bundled.djvu "$T/b2.ppm" && convert "$T/b2.ppm" bundled_p2.png

# Dizionario di forme condiviso (Djbz in FORM:DJVI, INCL) con minidjvu.
cat > "$T/t.ps" <<'EOF'
%!PS
/Times-Roman findfont 11 scalefont setfont
1 1 2 { pop
  /y 760 def
  { y 60 lt { exit } if
    50 y moveto (Lezione di analisi: limiti, derivate e integrali definiti.) show
    /y y 14 sub def } loop
  showpage } for
EOF
gs -q -dNOPAUSE -dBATCH -sDEVICE=pbmraw -r100 -sOutputFile="$T/s%d.pbm" "$T/t.ps"
minidjvu -l -p 2 "$T/s1.pbm" "$T/s2.pbm" shared.djvu
ddjvu -format=ppm -page=2 shared.djvu "$T/sh2.ppm" && convert "$T/sh2.ppm" shared_p2.png

# Documento indiretto (solo la cartella: le pagine sono file separati).
(cd "$T" && minidjvu -i s1.pbm s2.pbm ind.djvu) && cp "$T/ind.djvu" indirect.djvu
rm -rf "$T"
