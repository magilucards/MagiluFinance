# Instrucciones para desplegar Magilu Finance

Tienes 3 caminos: **Cowork (automatizado)**, **GitHub web (manual rápido)** o **terminal (manual técnico)**. Elige uno.

---

## 🤖 OPCIÓN A: COWORK (recomendado, sin tocar nada)

Si tienes [Cowork de Anthropic](https://www.anthropic.com/cowork) instalado en tu Mac/PC, copia y pega este briefing tal cual:

```
Necesito desplegar una PWA llamada "Magilu Finance".

CONTEXTO:
- Tengo un archivo ZIP en /Users/[mi-usuario]/Downloads/magilu-finance-v8.zip 
  (ajusta la ruta a donde tengas el ZIP)
- Necesito crear un repo público de GitHub y desplegarlo en GitHub Pages
- Mi cuenta de GitHub ya está conectada

PASOS QUE NECESITO QUE HAGAS:

1. Descomprime el ZIP en una carpeta nueva ~/magilu-finance/

2. Crea un repositorio PÚBLICO en GitHub llamado "magilu-finance" 
   (visibility: public, sin README inicial, sin .gitignore, sin licencia)

3. Sube TODOS los archivos descomprimidos al repo:
   - index.html
   - manifest.json
   - sw.js
   - README.md
   - .gitignore
   - icon-192.png
   - icon-512.png
   - icon-maskable-192.png
   - icon-maskable-512.png
   - apple-touch-icon.png
   - favicon-16.png
   - favicon-32.png
   - favicon.ico
   
   Commit message: "Initial commit - Magilu Finance v8"

4. Activa GitHub Pages:
   - Settings → Pages
   - Source: Deploy from a branch
   - Branch: main / root
   - Save

5. Espera 1-2 minutos a que el deploy esté listo y dime la URL pública.
   Será algo como: https://[mi-usuario].github.io/magilu-finance/

6. Una vez tengas la URL, abre el panel de Supabase 
   (https://supabase.com/dashboard/project/bgrsjftxwuduvlglfpky)
   - Ve a Authentication → URL Configuration
   - En "Site URL" pon: https://[mi-usuario].github.io/magilu-finance/
   - En "Redirect URLs" añade la misma URL
   - Guarda los cambios

7. Devuélveme la URL final de la app.

IMPORTANTE: no toques nada del contenido de los archivos. Solo subir tal cual.
```

---

## 🌐 OPCIÓN B: GITHUB WEB (manual, 5 minutos)

### B.1 — Crear el repo

1. Entra a [github.com/new](https://github.com/new)
2. **Repository name**: `magilu-finance`
3. **Public** (marcado, importante)
4. **NO** marques "Add a README", "Add .gitignore", ni "Choose a license" (ya están en el ZIP)
5. Click **Create repository**

### B.2 — Subir archivos

1. En la página del repo recién creado, verás "uploading an existing file" como enlace en el medio.
2. Descomprime el ZIP `magilu-finance-v8.zip` en tu ordenador.
3. Selecciona **todos los archivos** (sin la carpeta contenedora) y arrástralos a la zona de drop.
4. Commit message: `Initial commit - Magilu Finance v8`
5. Click **Commit changes**

### B.3 — Activar GitHub Pages

1. En tu repo, click **Settings** (arriba a la derecha).
2. Menú izquierdo: **Pages**.
3. **Source**: Deploy from a branch.
4. **Branch**: `main` / `/(root)`.
5. Click **Save**.
6. Espera 1-2 minutos. Cuando esté listo verás un mensaje verde con tu URL pública.

### B.4 — Configurar Supabase Auth

1. Entra a [supabase.com/dashboard/project/bgrsjftxwuduvlglfpky](https://supabase.com/dashboard/project/bgrsjftxwuduvlglfpky)
2. Menú izquierdo: **Authentication** → **URL Configuration**.
3. **Site URL**: pega `https://TU-USUARIO.github.io/magilu-finance/` (con la barra final).
4. **Redirect URLs**: añade la misma URL.
5. **Save**.

### B.5 — Activar HaveIBeenPwned (capa extra de seguridad)

1. En Supabase Dashboard: **Authentication** → **Policies** → **Auth Settings**.
2. Busca **"Password Strength and Leaked Password Protection"**.
3. Activa **"Prevent use of leaked passwords"**.
4. **Minimum password length**: 8.
5. Save.

### B.6 — Primera entrada

1. Abre la URL pública en tu navegador.
2. Verás la pantalla de login con el logo MF.
3. Click **"Crear cuenta"**.
4. Email + contraseña fuerte (mínimo 8 caracteres, mayúscula, minúscula, número).
5. Si Supabase te pide confirmación por email, revisa tu correo y confirma.
6. Inicia sesión.
7. **Tus 5 cuentas, 12 deudas y 40 gastos fijos se cargarán automáticamente** gracias al trigger que configuré.

### B.7 — Instalar como PWA

**En iPhone (Safari)**:
1. Abre la URL.
2. Botón compartir (cuadrado con flecha).
3. "Añadir a pantalla de inicio".
4. Aparecerá el icono MF en tu home.

**En Android (Chrome)**:
1. Abre la URL.
2. Menú (tres puntos) → "Instalar app".

**En Mac/PC (Chrome o Edge)**:
1. Abre la URL.
2. Icono de instalación en la barra de direcciones (lado derecho).
3. Click → Instalar.

---

## 💻 OPCIÓN C: TERMINAL (manual técnico)

```bash
# 1. Descomprimir
cd ~/Downloads
unzip magilu-finance-v8.zip -d magilu-finance
cd magilu-finance

# 2. Inicializar Git
git init
git add .
git commit -m "Initial commit - Magilu Finance v8"
git branch -M main

# 3. Crear repo en GitHub (necesitas gh CLI instalado: brew install gh)
gh repo create magilu-finance --public --source=. --push

# Si no tienes gh CLI, crea el repo manualmente en github.com/new
# y luego ejecuta:
# git remote add origin https://github.com/TU-USUARIO/magilu-finance.git
# git push -u origin main

# 4. Activar Pages (con gh CLI):
gh api repos/{owner}/magilu-finance/pages -X POST \
  -f source[branch]=main -f source[path]=/

# Después: Settings → Pages en la web para verificar.
```

Sigue los pasos **B.4 a B.7** desde la opción anterior.

---

## ⚠️ Comprobaciones de seguridad post-despliegue

Una vez desplegado, verifica:

1. **HTTPS activo**: la URL debe ser `https://` (GitHub Pages lo activa automático).
2. **CSP funciona**: abre DevTools → Console. Si ves errores de CSP es porque algo se bloqueó (esperado y bueno: la app sigue funcionando).
3. **No hay datos en el código fuente**: View Source en el navegador no debe mostrar nada personal (cuentas, importes, etc).
4. **RLS activo**: si abres otra ventana de incógnito sin login, no debes poder acceder a datos.

---

## 🆘 Si algo va mal

- **Pantalla en blanco**: abre DevTools (F12) → Console → mándame el error.
- **"No se pudo cargar Supabase SDK"**: revisa la conexión o adblockers que bloqueen `cdn.jsdelivr.net`.
- **No carga los datos**: confirma que el email del paso B.6 está confirmado y que el Site URL del paso B.4 está correcto.
- **Iconos no aparecen**: limpia caché del navegador (Cmd/Ctrl + Shift + R).

Si nada de eso funciona, manda screenshot del error en la próxima sesión y lo arreglamos.
