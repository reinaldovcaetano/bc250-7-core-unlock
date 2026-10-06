# Tabelas ACPI (SSDT) do e-tho

`SSDT-CPU.aml`, `SSDT-PST.aml` e `SSDT-STUBS.aml` vêm de [e-tho/bc250-acpi-fix](https://github.com/e-tho/bc250-acpi-fix) **v1.1.0**, licença MIT, Copyright (c) 2026 e-tho.
São idênticas (sha256 conferido no script) ao payload embutido no BC250 Control Center.

| Arquivo | OEM table ID / revisão | sha256 |
|---|---|---|
| SSDT-CPU.aml | `AMD CPU` rev 2 (substitui a `AMD CPU` rev 1 da BIOS P3.00) | `dcc596e8b566a74268f75d8c66bd90a23bc8ac02768283b265edfec13f9d7fca` |
| SSDT-PST.aml | `PSTATES` rev 1 | `cb3c96c622d2d653777020283c434f92c26bf2c83502a27d9a398f98424a771f` |
| SSDT-STUBS.aml | `STUBS` rev 1 | `c219ce775476725d49739024e149556228436a1c3faf0768a7c3eff9d85f66c2` |

```
MIT License

Copyright (c) 2026 e-tho

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
