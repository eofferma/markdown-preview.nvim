# AGENTS.md — markdown-preview.nvim

Fork de `iamcco/markdown-preview.nvim` con sincronización de cursor/selección en la vista previa (rama `source-line-highlight`). Este documento describe la arquitectura para evitar re-analizar el código en cada sesión.

## Componentes

El plugin tiene tres capas que se comunican en cadena:

```
Neovim (vimscript) --msgpack-rpc--> Servidor Node --socket.io v2--> Navegador (app Next.js)
```

### 1. Capa vimscript (`plugin/`, `autoload/`)

- `plugin/mkdp.vim` — define `:MarkdownPreview`, `:MarkdownPreviewStop`, `:MarkdownPreviewToggle` y las opciones `g:mkdp_*`.
- `autoload/mkdp/rpc.vim` — arranca el servidor como job RPC (`mkdp#rpc#start_server()`, línea 40) y envía notificaciones:
  - `mkdp#rpc#preview_refresh()` (línea 110) envía `refresh_content` con `{bufnr, activeLineRange}`.
  - `s:get_active_line_range()` (línea 100): devuelve `[inicio, fin]` **solo en modo visual-línea (`V`)**; en cualquier otro modo es `v:null`.
  - También: `close_page`, `open_browser` (notificaciones) y `close_all_pages` (request).
- `autoload/mkdp/autocmd.vim` (línea 54) — en modo normal instala `CursorHold,CursorHoldI,CursorMoved,CursorMovedI → mkdp#rpc#preview_refresh()`. Con `g:mkdp_refresh_slow = 1` solo `CursorHold/BufWrite/InsertLeave` (sin CursorMoved). `ModeChanged`/`SafeState` disparan refresh extra para el modo visual.

### 2. Servidor Node (`src/` → compilado a `app/lib/`, más scripts a mano en `app/`)

- `src/attach/index.ts` — conecta con Neovim vía `@chemzqm/neovim` (stdin/stdout). En `refresh_content` (línea 52) consulta a Neovim: `winline`, `winheight`, `getpos('.')` (cursor, 1-based), `activeLineRange`, opciones, nombre y líneas del buffer, y llama `app.refreshPage({bufnr, data})`.
- `app/server.js` — **JS mantenido a mano, NO generado por tsc**. Sirve la app estática y el websocket (socket.io v2). `refreshPage()` (línea 134) emite `refresh_content` a los clientes del `bufnr`. Puerto: `g:mkdp_port` o `8080 + aleatorio` (línea 127).
- `app/index.js` — entrada cuando no hay binario: carga `app/server.js` en un `vm` con los módulos precompilados de `app/lib` y `app/node_modules` (`src/app/load.ts`).
- Runtime: usa `app/bin/markdown-preview-<platform>` si existe (pkg), si no `node app/index.js`.

### 3. App del navegador (`app/pages/`, Next.js 7 exportada a `app/out/`)

- Página única `/page/:bufnr` (`app/pages/index.jsx`):
  - `startSocket()` (línea ~153) conecta con query `bufnr` y escucha `refresh_content` → `onRefreshContent()` (línea ~243).
  - Renderiza markdown con markdown-it (configuración lazy en el primer refresh). Si el contenido no cambió, salta el re-render y solo llama `refreshScroll()`.
  - `refreshScroll()` (línea ~298): scroll sincronizado (`app/pages/scroll.js`, interpola offsets con TweenLite) + `applySourceLineHighlight(activeLineRange)` + `applyCursorLine(cursor[1])`.
- `app/pages/linenumbers.js` — plugin markdown-it que inyecta en `paragraph_open`, `heading_open`, `list_item_open`, `table_open`, `tr_open`: `class="source-line"`, `data-source-line="<map[0]>"` (0-based), `data-source-line-end="<map[1]-1>"`. Toda la correlación línea-fuente ↔ DOM se basa en estos atributos.

## Feature propio del fork: highlights sincronizados

Todo el pipeline ya existente se reutiliza; la lógica visual vive en `app/pages/index.jsx`:

- **`mkdp-source-line-active` (amarillo)** — `applySourceLineHighlight(range)` (línea ~77): resalta los bloques cuyo rango `data-source-line` intersecta la selección visual-línea (`V`). CSS inline en el `<style>` del componente.
- **`mkdp-cursor-line` (azul, borde izquierdo)** — `applyCursorLine(line)`: marca el bloque que contiene la línea del cursor (`data-source-line <= line <= data-source-line-end`), con fallback al bloque anterior más cercano (líneas en blanco). Se pasa `null` cuando hay `activeLineRange` activo para no solapar con el amarillo.
- La posición del cursor ya viaja en cada `refresh_content` (`cursor = getpos('.')`); no hace falta tocar vimscript ni el servidor para cambios visuales nuevos.

## Build

- `yarn build-lib` — `tsc -p ./`: compila `src/**` → `app/lib/**`. Necesario solo si se toca `src/`.
- `yarn build-app` — `next build && next export` en `app/`: regenera `app/out/` (que está commiteado). Necesario tras tocar `app/pages/` o `app/_static/`.
- `yarn build` — todo lo anterior + `pkg` para generar binarios en `app/bin/`.
- **Gotcha Node ≥ 17:** webpack 4 falla con `ERR_OSSL_EVP_UNSUPPORTED`; usar `NODE_OPTIONS=--openssl-legacy-provider yarn build-app`.
- Tras un build, `app/out/_next/static/<hash>/` cambia de nombre; git suele detectarlo como renombres.

## Pruebas manuales

No hay suite de tests. Flujo de verificación:

```sh
nvim -u test/init.vim test/test.md
:MarkdownPreview
```

- `test/init.vim` solo añade el repo al `runtimepath`.
- `test/test.md` tiene encabezados, listas, tablas, código, etc.
- Headless smoke test: lanzar `nvim --headless -u test/init.vim test/test.md -c 'MarkdownPreview'`, buscar el puerto con `ss -ltn` (≥8080) y hacer `curl http://localhost:<puerto>/page/2` (debe dar 200).

## Limitaciones conocidas

- `activeLineRange` solo cubre visual-línea (`V`); `v` y `Ctrl-V` no resaltan (ver `s:get_active_line_range()` en `autoload/mkdp/rpc.vim:100`).
- Con `g:mkdp_refresh_slow = 1` el cursor/scroll solo se actualiza en `CursorHold`/`BufWrite`.
- markdown-it va con `breaks: false` por defecto: un Enter simple no genera `<br>` (CommonMark). Se puede activar con `g:mkdp_preview_options = {'mkit': {'breaks': v:true}}`.
- `app/server.js` se edita a mano; si se añade un campo al payload hay que actualizarlo tanto en `src/attach/index.ts` como en `app/server.js` (emisión inicial al conectar, línea ~101).
