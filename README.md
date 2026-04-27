# JavaScriptCore bindings for Odin

build vendored JavaScriptCore artifacts (Linux/Windows only):

```
# linux
./build.sh --configuration release

# windows
build.bat --configuration release
```

- Uses `WebKit/Tools/Scripts/build-jsc` under the vendored `WebKit` checkout.
- Linux builds with `--gtk` and copies `libjavascriptcoregtk-4.1.so*` to this folder.
- Windows builds with `--win` and copies `JavaScriptCore.dll` + `JavaScriptCore.lib` to this folder.
- `build_static.sh` / `build_static.bat` are aliases to the same shared-library build flow.

run demo:

```
odin run examples -- examples/script.js
```

generate module bindings:

```
odin run scripts/bindgen.odin -file -- ./path/to/module
```

- Emits:
  - `jsc_bindings.generated.odin` (shared helpers + public register proc)
  - `${source}_jsc.generated.odin` per source file
  - `jsc_bindings.generated.d.ts` (TypeScript declarations)
- Runtime JS surface is namespaced under `globalThis.<namespace_root>.<module_alias>`.
  - Default `<namespace_root>` is derived from the module parent folder name.
  - Default `<module_alias>` is the module folder name.
  - `target_rename` in `jsc_bindgen.spec` overrides `<module_alias>`.
  - Example: bindgen for `./rt/drift` registers symbols under `globalThis.rt.drift.*`.

optional `jsc_bindgen.spec` (per-module):

- Put the file at `<module>/jsc_bindgen.spec`.
- Empty lines and lines starting with `#` or `//` are ignored.
- Directive syntax:
  - `exclude <symbol>`
  - `rename <symbol> <js_name>`
  - `specialize <symbol> <js_name> <bindings>`
- `<bindings>` is comma-separated `name=value` pairs for compile-time params.

example:

```
# hide symbol from JS
exclude _internal_only

# rename generated JS function name
rename fps get_fps

# expose a concrete generic specialization
specialize transform transform_vec2 T=vec2
specialize transform transform_vec3 T=vec3
```
