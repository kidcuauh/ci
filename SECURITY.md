# Política de seguridad

## Cómo reportar una vulnerabilidad

Usa el reporte privado de vulnerabilidades de GitHub: pestaña **Security** de este repo, luego **Report a vulnerability**.

No abras issues: están apagados en este repo. No publiques detalles de una vulnerabilidad antes de que se corrija.

## Versión soportada

Solo `main`. Las releases `vX.Y.Z` son marcas de versión y pines de emergencia, y no reciben parches propios: la corrección entra por `main`.

## Alcance

Los workflows reutilizables de este repo (`.github/workflows/`) y los scripts de `scripts/`: por ejemplo, una forma de ejecutar código con los secretos de un repo que lo llama, de saltarse las protecciones del repo o de filtrar un secreto.

Fuera de alcance: los repos que llaman a estos workflows y sus propios secretos.
