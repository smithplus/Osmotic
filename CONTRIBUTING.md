# Contribuir

Guía corta; el detalle para trabajar en el código está en [`CLAUDE.md`](CLAUDE.md) (sirve igual para personas y para agentes de IA).

1. `swift build && swift test` antes de proponer cambios; `scripts/lint.sh --fix` para el formato.
2. Textos de UI en inglés con `Text("…")`/`String(localized:)`; después `scripts/sync_strings.sh` y el español en `Resources/Localizable.xcstrings`.
3. Tests nuevos con Swift Testing. El protocolo se prueba contra `FakeCamera`/`FakeHTTPServer`, sin hardware.
4. Commits chicos, en inglés, en imperativo ("Fix …", "Add …"). Anotá en `CHANGELOG.md` lo que ve el usuario.
5. Código adaptado de otros proyectos: respetá su licencia y dejá el crédito (ver `LICENSE`, `README.md`).
