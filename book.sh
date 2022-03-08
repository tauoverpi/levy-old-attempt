#!/bin/sh

echo extracting source files ------------------------------------------
zangle tangle *.md
echo running tests ----------------------------------------------------
zangle ls *.md | sed -e '/\.uml/d' -e '/\.asy/d' | while read -r l; do zig test $l; done
echo generating diagrams ----------------------------------------------
find uml/ -name '*.uml' -exec plantuml {} \;
find uml/ -name '*.asy' -exec asy -o uml/img/ {} \;
echo building pdf -----------------------------------------------------
mkdir -p tmp
find . -name '*.md' | while read -r l; do \
    sed -e '/    ----*/d' \
        -e 's/^    lang.*tag: #\(.*\)$/\n\\vspace{0.6cm}\\footnotesize\\centerline{\n\\underline{\1}\n}\n\\normalsize\\vspace{0.2cm}/' \
        -e 's/^    lang.*file: \(.*\)$/\n\\vspace{0.6cm}\\footnotesize\\centerline{\n\\underline{\1}\n}\n\\normalsize\\vspace{0.2cm}/' \
    < $l | pandoc -o "tmp/${l}.pdf"; \
done
find tmp/ -name '*.pdf' | xargs gs -q \
    -sPAPERSIZE=letter \
    -dNOPAUSE -dBATCH \
    -sDEVICE=pdfwrite \
    -sOutputFile=book.pdf
rm tmp/*.pdf
echo done -------------------------------------------------------------
