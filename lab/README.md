# MagiluFinance LAB

Rama `ui-lab`: laboratorio de interfaz. **No es la app oficial.**

Todo lo que identifica al LAB vive aquí (`lab/`) más las referencias en el `<head>`
de cada página (script `lab/lab.js`, manifest e iconos de `lab/`, títulos "MagiluFinance LAB").

- `lab.js`: franja amarilla fija "LAB" arriba y barra de estado en amarillo.
- `manifest.json`: PWA "MagiluFinance LAB" (id propio) con iconos naranja + banda "LAB".

Cuando un cambio de interfaz del LAB se quiera pasar a la oficial, se lleva **solo ese cambio**
a `main` (cherry-pick del commit concreto), nunca el commit de identidad LAB.

⚠️ El LAB usa la misma Supabase (y por tanto Holded) que la oficial: todo lo que se guarde,
facture o envíe desde aquí es real.
