# Vendored libltc

- Source: https://github.com/x42/libltc, release v1.3.2 (2022-09-04)
- License: GNU LGPL v3 or later (see `COPYING` in this folder)
- Copyright: Robin Gareus and contributors (see `AUTHORS`)

Files are copied unmodified from the release's `src/` folder; `ltc.h` lives in `../include/`
so Swift can see it. The autotools `config.h` is not needed and was not copied.

To satisfy the LGPL, the complete libltc source is included here, and TC Trigger can be
rebuilt against a modified copy by editing these files and running `scripts/build.sh`.
