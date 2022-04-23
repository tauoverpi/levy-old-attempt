#!/bin/sh

clean() {
    cat $1 | sed -e '/    ----*/d' \
                -e 's/^    lang.*tag: #\(.*\)$/\n\\vspace{0.6cm}\\footnotesize\\centerline{\n\\underline{\1}\n}\n\\normalsize\\vspace{0.2cm}/' \
                -e 's/^    lang.*file: \(.*\)$/\n\\vspace{0.6cm}\\footnotesize\\centerline{\n\\underline{\1}\n}\n\\normalsize\\vspace{0.2cm}/' \

}

mkdir -p tmp
echo extracting source files ------------------------------------------
zangle tangle *.md
echo running tests ----------------------------------------------------
zig build test
echo building ---------------------------------------------------------
zig build --prominent-compile-errors

if [[ -n "$1" ]]; then
    echo generating diagrams ----------------------------------------------
    zangle ls "$1" | grep '.uml' | while read -r name; do plantuml "$name"; done
    zangle ls "$1" | grep '.asy' | while read -r name; do asy -o uml/img/ "$name"; done
    zangle ls "$1" | grep '.plot' | while read -r name; do gnuplot "$name"; done
    clean "$1" | pandoc -o "tmp/$(basename $1).pdf" --metadata-file misc/meta.yml
else
    echo generating diagrams ----------------------------------------------
    rm tmp/*.pdf
    find uml/ -name '*.uml' -exec plantuml {} \;
    find uml/ -name '*.asy' -exec asy -o uml/img/ {} \;
    find uml/ -name '*.plot' -exec gnuplot {} \;
    zangle graph *.md | sed -e '/\.uml/d' -e '/\.asy/d' | dot -Tpng > uml/img/map.png
    ls *.md | while read -r l; do clean "$1" | pandoc -o "tmp/${l}.pdf" --metadata-file misc/meta.yml; done
    find tmp/ -name '*.pdf' | xargs gs -q \
        -sPAPERSIZE=letter \
        -dNOPAUSE -dBATCH \
        -sDEVICE=pdfwrite \
        -sOutputFile=book.pdf
fi
echo done -------------------------------------------------------------
