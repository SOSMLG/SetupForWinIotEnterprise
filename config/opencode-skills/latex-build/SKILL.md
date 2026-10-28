---
name: latex-build
description: Build LaTeX, Typst and pandoc documents and fix common compile errors. Load when a PDF or .tex build is needed.
---
- LaTeX: `latexmk -pdf -interaction=nonstopmode -halt-on-error main.tex`. Clean with `latexmk -c`.
- Read the log from the first line starting with `!`. That is the real error.
- `Undefined control sequence`: typo or missing package. `File not found`: MiKTeX package missing, install it with `mpm --install=<package>` or allow on-the-fly installs in MiKTeX.
- Undefined references need a second run. Overfull hbox warnings are cosmetic.
- Non-ASCII text: use `xelatex` or `lualatex` with `fontspec`. `pdflatex` needs `inputenc` utf8 and `fontenc` T1.
- Typst: `typst compile main.typ`, `typst watch main.typ`.
- pandoc: `pandoc in.md -o out.docx` (add `--reference-doc=template.docx` to control styles), `--toc` for a contents page. PDF output needs `--pdf-engine=xelatex`.
- Open the result in Word or a PDF viewer before calling it done.
- Never commit build files: .aux .log .out .toc .synctex.gz
