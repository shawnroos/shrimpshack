# Vendored dependency

`asciichartpy.py` is a byte-identical copy of asciichartpy 1.5.25.

- Upstream: https://github.com/kroitor/asciichart
- Package: https://pypi.org/project/asciichartpy/1.5.25/
- Licence: MIT (the licence header is inside the file itself)
- sha256: 1d24a0a01f8559fdeea83e654f187796eab5898c77511b5d67ef864d6e4a1990

The file is not edited, so `tests/vendor_test.py` can hash the whole thing against the
published release. Version and provenance live here for that reason.

It is vendored rather than installed because it is one file that imports only `math`,
and this marketplace has no install step. It receives no upstream fixes automatically:
on a suspected renderer bug, diff against the upstream tag before patching locally.
