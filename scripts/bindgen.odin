package main

import "core:fmt"
import ast "core:odin/ast"
import parser "core:odin/parser"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

GEN_FILE_NAME :: "jsc_bindings.generated.odin"
GEN_FILE_SUFFIX :: "_jsc.generated.odin"
DTS_FILE_NAME :: "jsc_bindings.generated.d.ts"
SPEC_FILE_NAME :: "jsc_bindgen.spec"

Param_Info :: struct {
    name:            string,
    local_name:      string,
    odin_type:       string,
    default_expr:    string,
    runtime_exposed: bool,
    has_default:     bool,
    is_comptime:     bool,
    is_implicit:     bool,
    unsupported:     bool,
    unsupported_msg: string,
}

Result_Info :: struct {
    odin_type:       string,
    unsupported:     bool,
    unsupported_msg: string,
}

Proc_Template :: struct {
    symbol:                string,
    source_name:           string,
    source_fullpath:       string,
    source_generated_name: string,
    source_directives:     []string,
    params:                []Param_Info,
    results:               []Result_Info,
    generic:               bool,
    diverging:             bool,
    private:               bool,
    underscore:            bool,
    invalid:               bool,
    invalid_msg:           string,
}

Proc_Binding :: struct {
    symbol:                  string,
    js_name:                 string,
    wrapper_name:            string,
    source_name:             string,
    source_fullpath:         string,
    source_generated_name:   string,
    source_directives:       []string,
    params:                  []Param_Info,
    results:                 []Result_Info,
    call_args:               [dynamic]string,
    required_runtime_params: int,
    total_runtime_params:    int,
    supported:               bool,
    unsupported_reason:      string,
    diverging:               bool,
}

Generated_File_Bindings :: struct {
    source_name:     string,
    source_fullpath: string,
    generated_name:  string,
    register_name:   string,
    directives:      []string,
    bindings:        [dynamic]Proc_Binding,
}

Specialize_Directive :: struct {
    symbol:   string,
    js_name:  string,
    bindings: map[string]string,
    line:     int,
}

Spec_Config :: struct {
    target_import_alias: string,
    excludes:            map[string]bool,
    renames:             map[string]string,
    specializes:         [dynamic]Specialize_Directive,
}

Named_Type_Kind :: enum u8 {
    Alias,
    Struct,
    Enum,
    Bit_Set,
}

Named_Type_Field :: struct {
    name:      string,
    odin_type: string,
}

Named_Type_Def :: struct {
    name:      string,
    kind:      Named_Type_Kind,
    odin_type: string,
    fields:    []Named_Type_Field,
}

TS_Render_Context :: struct {
    named_defs:       map[string]Named_Type_Def,
    named_ts_exprs:   map[string]string,
    named_alias_name: map[string]string,
    resolving_named:  map[string]bool,
}

Import_Pair :: struct {
    alias: string,
    path:  string,
}

print_usage :: proc() {
    fmt.eprintln("Usage: odin run jsc_bindgen.odin -file -- <lib-name-or-path>")
    fmt.eprintln("Example: odin run jsc_bindgen.odin -file -- ./path/to/module")
    fmt.eprintln("Example: odin run jsc_bindgen.odin -file -- ../game/runtime")
}

is_path_like :: proc(arg: string) -> bool {
    if filepath.is_abs(arg) do return true
    if strings.has_prefix(arg, ".") do return true
    for c in arg {
        if c == '/' || c == '\\' do return true
    }
    return false
}

is_ascii_letter :: proc(c: byte) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

is_ascii_digit :: proc(c: byte) -> bool {
    return c >= '0' && c <= '9'
}

sanitize_identifier :: proc(raw: string) -> string {
    if len(raw) == 0 do return "sym"
    out := make([dynamic]byte, 0, len(raw) + 1)
    for i := 0; i < len(raw); i += 1 {
        c := raw[i]
        if !is_ascii_letter(c) && !is_ascii_digit(c) && c != '_' {
            c = '_'
        }
        if i == 0 && is_ascii_digit(c) {
            append(&out, '_')
        }
        append(&out, c)
    }
    if len(out) == 0 {
        append(&out, 's', 'y', 'm')
    }
    return string(out[:])
}

sanitize_local_identifier :: proc(raw: string, fallback: string) -> string {
    base := raw
    if strings.has_prefix(base, "$") {
        base = base[1:]
    }
    id := sanitize_identifier(base)
    if id == "" || id == "_" {
        return sanitize_identifier(fallback)
    }
    return id
}

has_generated_file_suffix :: proc(name: string) -> bool {
    return strings.has_suffix(name, GEN_FILE_SUFFIX)
}

source_file_to_generated_name :: proc(source_name: string) -> string {
    if strings.has_suffix(source_name, ".odin") {
        stem := source_name[:len(source_name) - len(".odin")]
        return fmt.aprintf("%s%s", stem, GEN_FILE_SUFFIX, allocator = context.allocator)
    }
    return fmt.aprintf("%s%s", source_name, GEN_FILE_SUFFIX, allocator = context.allocator)
}

join2 :: proc(a, b: string) -> (string, bool) {
    parts := [2]string{a, b}
    joined, err := filepath.join(parts[:])
    if err != nil {
        return "", false
    }
    return joined, true
}

resolve_module_path :: proc(lib_arg: string) -> (module_abs, module_name: string, ok: bool) {
    module_input := lib_arg

    resolved_abs, abs_err := os.get_absolute_path(module_input, context.allocator)
    if abs_err != nil {
        fmt.eprintf("jsc_bindgen: failed to resolve path '%s': %v\n", module_input, abs_err)
        return
    }
    module_abs = resolved_abs
    if !os.exists(module_abs) || !os.is_directory(module_abs) {
        fmt.eprintf("jsc_bindgen: module path does not exist or is not a directory: %s\n", module_abs)
        return
    }

    module_name = sanitize_identifier(filepath.base(module_abs))
    ok = true
    return
}

derive_default_namespace_root :: proc(module_abs: string) -> string {
    // DUMBAI: infer namespace root from the module's parent folder so bindgen avoids monorepo-specific constants.
    parent_dir := filepath.dir(module_abs)
    root := sanitize_identifier(filepath.base(parent_dir))
    if root == "" {
        root = "bindings"
    }
    return root
}

resolve_generator_jsc_root :: proc(loc := #caller_location) -> (jsc_root_abs: string, ok: bool) {
    source_file_abs, abs_err := os.get_absolute_path(loc.file_path, context.allocator)
    if abs_err != nil {
        fmt.eprintf("jsc_bindgen: failed to resolve generator source path '%s': %v\n", loc.file_path, abs_err)
        return
    }

    scripts_dir := filepath.dir(source_file_abs)
    jsc_root_abs = filepath.dir(scripts_dir)
    if !os.exists(jsc_root_abs) || !os.is_directory(jsc_root_abs) {
        fmt.eprintf("jsc_bindgen: resolved JSC root is not a directory: %s\n", jsc_root_abs)
        return
    }

    ok = true
    return
}

resolve_jsc_import :: proc(module_abs: string, jsc_root_abs: string) -> (jsc_import: string, ok: bool) {

    rel_path, rel_err := filepath.rel(module_abs, jsc_root_abs, context.allocator)
    if rel_err != .None {
        fmt.eprintf("jsc_bindgen: failed to compute import path from %s to %s\n", module_abs, jsc_root_abs)
        return
    }
    normalized, _ := strings.replace_all(rel_path, "\\", "/", context.allocator)
    jsc_import = normalized
    ok = true
    return
}

is_ignored_source_file :: proc(fullpath: string, output_abs: string) -> bool {
    if fullpath == output_abs do return true
    name := filepath.base(fullpath)
    if name == GEN_FILE_NAME do return true
    // DUMBAI: skip any pre-generated source units (V8/JSC/etc.) to avoid recursive wrapper generation.
    if strings.has_suffix(name, ".generated.odin") do return true
    if has_generated_file_suffix(name) do return true
    if strings.has_suffix(name, "_test.odin") do return true
    if strings.has_suffix(name, "_shd.odin") do return true
    return false
}

extract_source_directives :: proc(src: string) -> []string {
    directives := make([dynamic]string)
    lines, _ := strings.split(src, "\n", context.temp_allocator)
    for line in lines {
        trimmed := strings.trim_space(line)
        if strings.has_prefix(trimmed, "package ") || trimmed == "package" {
            break
        }
        if strings.has_prefix(trimmed, "#+") {
            // DUMBAI: preserve top-of-file build/feature directives so generated wrappers follow original compile constraints.
            append(&directives, trimmed)
        }
    }
    return directives[:]
}

extract_expr_text :: proc(src: string, expr: ^ast.Expr) -> string {
    if expr == nil do return ""
    start := clamp(expr.pos.offset, 0, len(src))
    end := clamp(expr.end.offset, start, len(src))
    return strings.trim_space(src[start:end])
}

extract_attribute_text :: proc(src: string, attribute: ^ast.Attribute) -> string {
    if attribute == nil do return ""
    start := clamp(attribute.pos.offset, 0, len(src))
    end := clamp(attribute.end.offset, start, len(src))
    return strings.trim_space(src[start:end])
}

compact_type_text :: proc(type_text: string) -> string {
    out := make([dynamic]byte, 0, len(type_text))
    for i := 0; i < len(type_text); i += 1 {
        if i + 1 < len(type_text) && type_text[i] == '/' && type_text[i + 1] == '/' {
            i += 2
            for i < len(type_text) && type_text[i] != '\n' {
                i += 1
            }
            i -= 1
            continue
        }
        if i + 1 < len(type_text) && type_text[i] == '/' && type_text[i + 1] == '*' {
            i += 2
            for i + 1 < len(type_text) {
                if type_text[i] == '*' && type_text[i + 1] == '/' {
                    i += 1
                    break
                }
                i += 1
            }
            continue
        }
        c := type_text[i]
        if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
            continue
        }
        append(&out, c)
    }
    return string(out[:])
}

trim_wrapping_quotes :: proc(text: string) -> string {
    if len(text) >= 2 {
        if (text[0] == '"' && text[len(text) - 1] == '"') || (text[0] == '`' && text[len(text) - 1] == '`') {
            return text[1:len(text) - 1]
        }
    }
    return text
}

default_import_alias :: proc(path: string) -> string {
    p := path
    if idx := strings.last_index(p, ":"); idx >= 0 {
        p = p[idx + 1:]
    }
    if idx := strings.last_index(p, "/"); idx >= 0 {
        p = p[idx + 1:]
    }
    return sanitize_identifier(strings.trim_space(p))
}

resolve_relative_import_alias :: proc(
    importing_file_abs: string,
    import_path: string,
    cache: ^map[string]string,
) -> (
    alias: string,
    ok: bool,
) {
    if !strings.has_prefix(import_path, ".") {
        return "", false
    }

    importer_dir := filepath.dir(importing_file_abs)
    target_path, joined := join2(importer_dir, import_path)
    if !joined {
        return "", false
    }

    target_abs, abs_err := os.get_absolute_path(target_path, context.allocator)
    if abs_err != nil {
        return "", false
    }

    if cached_alias, cached := cache^[target_abs]; cached {
        return cached_alias, cached_alias != ""
    }

    if !os.exists(target_abs) || !os.is_directory(target_abs) {
        cache^[target_abs] = ""
        return "", false
    }

    // DUMBAI: Odin import defaults follow path hierarchy; derive alias from resolved relative path basename.
    alias = sanitize_identifier(filepath.base(target_abs))
    cache^[target_abs] = alias
    if alias == "" {
        return "", false
    }
    return alias, true
}

extract_explicit_import_alias :: proc(src: string, import_decl: ^ast.Import_Decl) -> string {
    if import_decl == nil {
        return ""
    }

    start := clamp(import_decl.pos.offset, 0, len(src))
    path_start := clamp(import_decl.relpath.pos.offset, start, len(src))
    if path_start <= start {
        return ""
    }

    header := strings.trim_space(src[start:path_start])
    if header == "" {
        return ""
    }

    import_idx := strings.last_index(header, "import")
    if import_idx < 0 {
        return ""
    }

    after_import := strings.trim_space(header[import_idx + len("import"):])
    if after_import == "" {
        return ""
    }

    alias, _, ok := split_head_token(after_import)
    if !ok || alias == "" {
        return ""
    }
    if alias[0] == '"' || alias[0] == '`' {
        return ""
    }

    return sanitize_identifier(alias)
}

collect_import_aliases :: proc(pkg: ^ast.Package, output_abs: string) -> map[string]string {
    imports := make(map[string]string)
    import_alias_cache := make(map[string]string)
    for _, file in pkg.files {
        if file == nil do continue
        if is_ignored_source_file(file.fullpath, output_abs) do continue

        for stmt in file.decls {
            import_decl, is_import := stmt.derived_stmt.(^ast.Import_Decl)
            if !is_import || import_decl == nil {
                continue
            }

            path := trim_wrapping_quotes(strings.trim_space(import_decl.relpath.text))
            if path == "" {
                continue
            }

            alias := extract_explicit_import_alias(file.src, import_decl)
            if alias == "" {
                // DUMBAI: relative imports without explicit aliases resolve via filesystem hierarchy (e.g. `..` -> `rt`).
                if resolved_alias, resolved := resolve_relative_import_alias(file.fullpath, path, &import_alias_cache);
                   resolved {
                    alias = resolved_alias
                } else {
                    alias = default_import_alias(path)
                }
            }
            if alias == "" {
                continue
            }

            imports[alias] = path
        }
    }
    return imports
}

collect_aliases_from_type_text :: proc(type_text: string, required: ^map[string]bool) {
    text := compact_type_text(type_text)
    i := 0
    for i < len(text) {
        c := text[i]
        if !is_ascii_letter(c) && c != '_' {
            i += 1
            continue
        }
        start := i
        i += 1
        for i < len(text) {
            ch := text[i]
            if !is_ascii_letter(ch) && !is_ascii_digit(ch) && ch != '_' {
                break
            }
            i += 1
        }
        ident := text[start:i]
        if i < len(text) && text[i] == '.' {
            required^[ident] = true
        }
    }
}

collect_required_aliases :: proc(bindings: []Proc_Binding) -> map[string]bool {
    required := make(map[string]bool)
    for binding in bindings {
        for p in binding.params {
            collect_aliases_from_type_text(p.odin_type, &required)
            if p.has_default {
                // DUMBAI: defaults like `glm.TAU` need matching imports in generated wrapper file.
                collect_aliases_from_type_text(p.default_expr, &required)
            }
        }
        for r in binding.results {
            collect_aliases_from_type_text(r.odin_type, &required)
        }
    }
    return required
}

resolve_extra_imports :: proc(imports: map[string]string, required: map[string]bool) -> []Import_Pair {
    pairs := make([dynamic]Import_Pair)
    for alias, _ in required {
        if alias == "" do continue
        if alias == "c" || alias == "runtime" || alias == "jsc" {
            continue
        }
        if path, ok := imports[alias]; ok {
            append(&pairs, Import_Pair{alias = alias, path = path})
        }
    }

    slice.sort_by(pairs[:], proc(lhs, rhs: Import_Pair) -> bool {
        return lhs.alias < rhs.alias
    })
    return pairs[:]
}

count_field_instances :: proc(field: ^ast.Field) -> int {
    if field == nil do return 0
    if len(field.names) == 0 {
        return 1
    }
    return len(field.names)
}

split_head_token :: proc(line: string) -> (head, tail: string, ok: bool) {
    src := strings.trim_space(line)
    if src == "" {
        return "", "", false
    }

    start := 0
    for start < len(src) {
        c := src[start]
        if c != ' ' && c != '\t' {
            break
        }
        start += 1
    }

    end := start
    for end < len(src) {
        c := src[end]
        if c == ' ' || c == '\t' {
            break
        }
        end += 1
    }

    head = src[start:end]
    tail = strings.trim_space(src[end:])
    ok = head != ""
    return
}

parse_bindings_map :: proc(raw: string, line_no: int) -> (map[string]string, bool) {
    bindings := make(map[string]string)
    text := strings.trim_space(raw)
    if text == "" {
        return bindings, true
    }

    chunks, _ := strings.split(text, ",", context.temp_allocator)
    for chunk in chunks {
        part := strings.trim_space(chunk)
        if part == "" {
            continue
        }
        eq := strings.index(part, "=")
        if eq <= 0 || eq >= len(part) - 1 {
            fmt.eprintf("jsc_bindgen: invalid specialize binding on line %d: %s\n", line_no, part)
            return bindings, false
        }
        key := strings.trim_space(part[:eq])
        value := strings.trim_space(part[eq + 1:])
        if key == "" || value == "" {
            fmt.eprintf("jsc_bindgen: invalid specialize binding on line %d: %s\n", line_no, part)
            return bindings, false
        }
        bindings[key] = value
    }

    return bindings, true
}

normalize_spec_target_symbol :: proc(raw: string, line_no: int) -> (symbol: string, ok: bool) {
    target := strings.trim_space(raw)
    if target == "" {
        fmt.eprintf("jsc_bindgen: missing target symbol on line %d\n", line_no)
        return "", false
    }
    if dot := strings.last_index(target, "."); dot >= 0 {
        // DUMBAI: spec targets are always resolved against the current package; any `alias.` prefix is ignored.
        target = strings.trim_space(target[dot + 1:])
    }
    if target == "" {
        fmt.eprintf("jsc_bindgen: invalid target symbol `%s` on line %d\n", raw, line_no)
        return "", false
    }
    return target, true
}

parse_spec_file :: proc(module_abs: string) -> (spec: Spec_Config, ok: bool) {
    spec.target_import_alias = sanitize_identifier(filepath.base(module_abs))
    spec.excludes = make(map[string]bool)
    spec.renames = make(map[string]string)
    spec.specializes = make([dynamic]Specialize_Directive)

    spec_abs, joined := join2(module_abs, SPEC_FILE_NAME)
    if !joined {
        fmt.eprintln("jsc_bindgen: failed to allocate spec path")
        return spec, false
    }

    if !os.exists(spec_abs) {
        return spec, true
    }

    bytes, read_err := os.read_entire_file(spec_abs, context.allocator)
    if read_err != nil {
        fmt.eprintf("jsc_bindgen: failed to read %s: %v\n", spec_abs, read_err)
        return spec, false
    }

    lines, _ := strings.split(string(bytes), "\n", context.temp_allocator)
    for raw_line, i in lines {
        line_no := i + 1
        line := strings.trim_space(raw_line)
        if line == "" do continue
        if strings.has_prefix(line, "#") || strings.has_prefix(line, "//") do continue

        directive, tail, head_ok := split_head_token(line)
        if !head_ok {
            continue
        }

        switch directive {
        case "target_rename":
            source_or_alias, rest, tok_ok := split_head_token(tail)
            if !tok_ok {
                fmt.eprintf("jsc_bindgen: invalid target_rename directive on line %d\n", line_no)
                return spec, false
            }
            alias := source_or_alias
            if renamed_alias, _, has_renamed_alias := split_head_token(rest); has_renamed_alias {
                alias = renamed_alias
            }
            alias = sanitize_identifier(alias)
            if alias == "" {
                fmt.eprintf("jsc_bindgen: invalid target_rename alias on line %d\n", line_no)
                return spec, false
            }
            // DUMBAI: spec-level target_rename makes import alias selection explicit and avoids hidden parser hardcodes.
            spec.target_import_alias = alias

        case "exclude":
            raw_symbol, _, tok_ok := split_head_token(tail)
            if !tok_ok {
                fmt.eprintf("jsc_bindgen: invalid exclude directive on line %d\n", line_no)
                return spec, false
            }
            symbol, symbol_ok := normalize_spec_target_symbol(raw_symbol, line_no)
            if !symbol_ok {
                return spec, false
            }
            spec.excludes[symbol] = true

        case "rename":
            raw_symbol, rest, tok_ok := split_head_token(tail)
            if !tok_ok {
                fmt.eprintf("jsc_bindgen: invalid rename directive on line %d\n", line_no)
                return spec, false
            }
            symbol, symbol_ok := normalize_spec_target_symbol(raw_symbol, line_no)
            if !symbol_ok {
                return spec, false
            }
            js_name, _, name_ok := split_head_token(rest)
            if !name_ok {
                fmt.eprintf("jsc_bindgen: invalid rename directive on line %d\n", line_no)
                return spec, false
            }
            spec.renames[symbol] = js_name

        case "specialize":
            raw_symbol, rest, sym_ok := split_head_token(tail)
            if !sym_ok {
                fmt.eprintf("jsc_bindgen: invalid specialize directive on line %d\n", line_no)
                return spec, false
            }
            symbol, symbol_ok := normalize_spec_target_symbol(raw_symbol, line_no)
            if !symbol_ok {
                return spec, false
            }
            js_name, binding_text, name_ok := split_head_token(rest)
            if !name_ok {
                fmt.eprintf("jsc_bindgen: invalid specialize directive on line %d\n", line_no)
                return spec, false
            }
            bindings, parsed := parse_bindings_map(binding_text, line_no)
            if !parsed {
                return spec, false
            }
            append(
                &spec.specializes,
                Specialize_Directive{symbol = symbol, js_name = js_name, bindings = bindings, line = line_no},
            )

        case:
            fmt.eprintf("jsc_bindgen: unknown directive `%s` on line %d\n", directive, line_no)
            return spec, false
        }
    }

    return spec, true
}

contains_unmappable_text :: proc(type_text: string) -> (bool, string) {
    t := compact_type_text(type_text)
    if strings.contains(t, "$") {
        return true, "polymorphic types require explicit specialization"
    }
    if strings.has_prefix(t, "proc") {
        return true, "procedure types are not auto-bindable"
    }
    if strings.has_prefix(t, "map[") {
        return true, "map types are not auto-bindable"
    }
    if strings.has_prefix(t, "union") {
        return true, "union types are not auto-bindable"
    }
    return false, ""
}

decl_has_private_attribute :: proc(file: ^ast.File, decl: ^ast.Value_Decl) -> bool {
    if decl == nil {
        return false
    }
    for attribute in decl.attributes {
        if attribute == nil {
            continue
        }
        attribute_text := extract_attribute_text(file.src, attribute)
        if strings.contains(attribute_text, "private") {
            return true
        }
    }
    return false
}

extract_ident_name :: proc(expr: ^ast.Expr) -> (symbol: string, ok: bool) {
    if expr == nil {
        return "", false
    }
    ident, is_ident := expr.derived.(^ast.Ident)
    if !is_ident || ident == nil {
        return "", false
    }
    if ident.name == "" || ident.name == "_" {
        return "", false
    }
    return ident.name, true
}

field_instance_name :: proc(field: ^ast.Field, idx, fallback_idx: int) -> string {
    if field != nil && idx < len(field.names) {
        name_expr := field.names[idx]
        if name, ok := extract_ident_name(name_expr); ok {
            return name
        }
        if poly, is_poly := name_expr.derived.(^ast.Poly_Type); is_poly && poly != nil && poly.type != nil {
            return fmt.aprintf("$%s", poly.type.name, allocator = context.allocator)
        }
    }
    return fmt.aprintf("p%d", fallback_idx, allocator = context.allocator)
}

field_is_comptime :: proc(src: string, field: ^ast.Field) -> bool {
    if field == nil {
        return false
    }
    if .Typeid_Token in field.flags {
        return true
    }
    if field.type != nil {
        if _, is_poly := field.type.derived.(^ast.Poly_Type); is_poly {
            return true
        }
    }
    for name_expr in field.names {
        if name_expr == nil {
            continue
        }
        ident, is_ident := name_expr.derived.(^ast.Ident)
        if is_ident && ident != nil && strings.has_prefix(ident.name, "$") {
            return true
        }
        if _, is_poly := name_expr.derived.(^ast.Poly_Type); is_poly {
            return true
        }
    }

    if field.type != nil {
        start := clamp(field.pos.offset, 0, len(src))
        finish := clamp(field.type.pos.offset, start, len(src))
        prefix := src[start:finish]
        if strings.contains(prefix, "$") {
            return true
        }
    }
    return false
}

is_implicit_default :: proc(default_expr: string) -> bool {
    if default_expr == "" {
        return false
    }
    if strings.contains(default_expr, "#caller_location") {
        return true
    }
    if strings.contains(default_expr, "context.") && strings.contains(default_expr, "allocator") {
        return true
    }
    return false
}

rewrite_alias_selector :: proc(expr, from_alias, to_alias: string) -> string {
    if expr == "" || from_alias == "" || to_alias == "" || from_alias == to_alias {
        return expr
    }

    out := strings.builder_make_len_cap(0, len(expr) + len(to_alias))
    i := 0
    for i < len(expr) {
        c := expr[i]
        if !is_ascii_letter(c) && c != '_' {
            strings.write_byte(&out, c)
            i += 1
            continue
        }

        start := i
        i += 1
        for i < len(expr) {
            ch := expr[i]
            if !is_ascii_letter(ch) && !is_ascii_digit(ch) && ch != '_' {
                break
            }
            i += 1
        }

        ident := expr[start:i]
        if ident == from_alias && i < len(expr) && expr[i] == '.' {
            // DUMBAI: normalize `rt.*` selectors to `runtime.*` so generated wrappers don't import the `rt` package alias.
            strings.write_string(&out, to_alias)
            continue
        }

        strings.write_string(&out, ident)
    }

    return strings.to_string(out)
}

analyze_params :: proc(
    file: ^ast.File,
    proc_type: ^ast.Proc_Type,
) -> (
    params: []Param_Info,
    invalid: bool,
    invalid_msg: string,
) {
    params_dyn := make([dynamic]Param_Info)
    if proc_type == nil || proc_type.params == nil {
        return params_dyn[:], false, ""
    }

    auto_idx := 0
    for field in proc_type.params.list {
        if field == nil {
            continue
        }

        if .Ellipsis in field.flags || .C_Vararg in field.flags {
            invalid = true
            invalid_msg = "variadic parameters are not supported"
        }

        if field.type == nil {
            has_default := field.default_value != nil
            default_expr := strings.trim_space(extract_expr_text(file.src, field.default_value))
            default_expr = rewrite_alias_selector(default_expr, "rt", "runtime")
            implicit := has_default && is_implicit_default(default_expr)
            if implicit {
                repeats := count_field_instances(field)
                for i := 0; i < repeats; i += 1 {
                    raw_name := field_instance_name(field, i, auto_idx)
                    // DUMBAI: untyped implicit defaults (e.g. `loc := #caller_location`) are kept hidden from JS and inlined at call-site.
                    append(
                        &params_dyn,
                        Param_Info {
                            name = raw_name,
                            local_name = "",
                            odin_type = "",
                            default_expr = default_expr,
                            runtime_exposed = false,
                            has_default = true,
                            is_comptime = false,
                            is_implicit = true,
                            unsupported = false,
                            unsupported_msg = "",
                        },
                    )
                    auto_idx += 1
                }
                continue
            }
            invalid = true
            invalid_msg = "parameter missing type"
            continue
        }

        type_text := compact_type_text(extract_expr_text(file.src, field.type))
        type_text = rewrite_alias_selector(type_text, "rt", "runtime")
        if strings.has_prefix(type_text, "..") {
            invalid = true
            invalid_msg = "variadic parameters are not supported"
        }
        if field.type != nil {
            prefix_start := clamp(field.pos.offset, 0, len(file.src))
            prefix_end := clamp(field.type.pos.offset, prefix_start, len(file.src))
            if strings.contains(file.src[prefix_start:prefix_end], "..") {
                invalid = true
                invalid_msg = "variadic parameters are not supported"
            }
        }
        has_default := field.default_value != nil
        default_expr := strings.trim_space(extract_expr_text(file.src, field.default_value))
        default_expr = rewrite_alias_selector(default_expr, "rt", "runtime")
        implicit := has_default && is_implicit_default(default_expr)
        comptime := field_is_comptime(file.src, field)
        unsupported_type, unsupported_msg := contains_unmappable_text(type_text)

        repeats := count_field_instances(field)
        for i := 0; i < repeats; i += 1 {
            raw_name := field_instance_name(field, i, auto_idx)
            local_name := fmt.aprintf(
                "arg_%s_%d",
                sanitize_local_identifier(raw_name, fmt.aprintf("p%d", auto_idx, allocator = context.allocator)),
                auto_idx,
                allocator = context.allocator,
            )
            instance_comptime := comptime || strings.has_prefix(raw_name, "$")
            runtime_exposed := !instance_comptime && !implicit

            append(
                &params_dyn,
                Param_Info {
                    name = raw_name,
                    local_name = local_name,
                    odin_type = type_text,
                    default_expr = default_expr,
                    runtime_exposed = runtime_exposed,
                    has_default = has_default,
                    is_comptime = instance_comptime,
                    is_implicit = implicit,
                    unsupported = unsupported_type,
                    unsupported_msg = unsupported_msg,
                },
            )
            auto_idx += 1
        }
    }

    params = params_dyn[:]
    return
}

analyze_results :: proc(
    file: ^ast.File,
    proc_type: ^ast.Proc_Type,
) -> (
    results: []Result_Info,
    invalid: bool,
    invalid_msg: string,
) {
    results_dyn := make([dynamic]Result_Info)
    if proc_type == nil || proc_type.results == nil {
        return results_dyn[:], false, ""
    }

    for field in proc_type.results.list {
        if field == nil {
            continue
        }
        if field.type == nil {
            invalid = true
            invalid_msg = "result missing type"
            continue
        }

        type_text := compact_type_text(extract_expr_text(file.src, field.type))
        type_text = rewrite_alias_selector(type_text, "rt", "runtime")
        unsupported_type, unsupported_msg := contains_unmappable_text(type_text)
        repeats := count_field_instances(field)
        for _ in 0 ..< repeats {
            append(
                &results_dyn,
                Result_Info{odin_type = type_text, unsupported = unsupported_type, unsupported_msg = unsupported_msg},
            )
        }
    }

    results = results_dyn[:]
    return
}

collect_proc_templates :: proc(pkg: ^ast.Package, output_abs: string) -> []Proc_Template {
    files := make([dynamic]^ast.File, 0, len(pkg.files))
    for _, file in pkg.files {
        if file == nil do continue
        if is_ignored_source_file(file.fullpath, output_abs) do continue
        append(&files, file)
    }

    slice.sort_by(files[:], proc(lhs, rhs: ^ast.File) -> bool {
        return lhs.fullpath < rhs.fullpath
    })

    templates := make([dynamic]Proc_Template)

    for file in files {
        source_name := filepath.base(file.fullpath)
        generated_name := source_file_to_generated_name(source_name)
        directives := extract_source_directives(file.src)

        for stmt in file.decls {
            decl, is_value_decl := stmt.derived_stmt.(^ast.Value_Decl)
            if !is_value_decl || decl == nil {
                continue
            }
            count := min(len(decl.names), len(decl.values))
            for i := 0; i < count; i += 1 {
                symbol, symbol_ok := extract_ident_name(decl.names[i])
                if !symbol_ok do continue

                proc_lit, is_proc_lit := decl.values[i].derived_expr.(^ast.Proc_Lit)
                if !is_proc_lit || proc_lit == nil {
                    continue
                }

                params, params_invalid, params_msg := analyze_params(file, proc_lit.type)
                results, results_invalid, results_msg := analyze_results(file, proc_lit.type)
                invalid := params_invalid || results_invalid
                invalid_msg := ""
                if params_invalid {
                    invalid_msg = params_msg
                }
                if invalid_msg == "" && results_invalid {
                    invalid_msg = results_msg
                }

                append(
                    &templates,
                    Proc_Template {
                        symbol = symbol,
                        source_name = source_name,
                        source_fullpath = file.fullpath,
                        source_generated_name = generated_name,
                        source_directives = directives,
                        params = params,
                        results = results,
                        generic = proc_lit.type != nil && proc_lit.type.generic,
                        diverging = proc_lit.type != nil && proc_lit.type.diverging,
                        private = decl_has_private_attribute(file, decl),
                        underscore = strings.has_prefix(symbol, "_"),
                        invalid = invalid,
                        invalid_msg = invalid_msg,
                    },
                )
            }
        }
    }

    slice.sort_by(templates[:], proc(lhs, rhs: Proc_Template) -> bool {
        if lhs.symbol == rhs.symbol {
            if lhs.source_fullpath == rhs.source_fullpath {
                return lhs.source_name < rhs.source_name
            }
            return lhs.source_fullpath < rhs.source_fullpath
        }
        return lhs.symbol < rhs.symbol
    })

    return templates[:]
}

is_type_keyword_ident :: proc(ident: string) -> bool {
    switch ident {
    case "auto_cast",
         "bit_field",
         "bit_set",
         "cast",
         "distinct",
         "dynamic",
         "enum",
         "fixed",
         "map",
         "matrix",
         "no_nil",
         "or_else",
         "or_return",
         "proc",
         "raw_union",
         "shared_nil",
         "struct",
         "typeid",
         "union",
         "using",
         "where":
        return true
    }
    return false
}

collect_type_identifiers_from_text :: proc(type_text: string, out: ^map[string]bool) {
    text := compact_type_text(type_text)
    i := 0
    for i < len(text) {
        c := text[i]
        if !is_ascii_letter(c) && c != '_' {
            i += 1
            continue
        }

        start := i
        i += 1
        for i < len(text) {
            ch := text[i]
            if !is_ascii_letter(ch) && !is_ascii_digit(ch) && ch != '_' {
                break
            }
            i += 1
        }

        ident := text[start:i]
        if ident == "" || is_type_keyword_ident(ident) {
            continue
        }

        // DUMBAI: skip package aliases in selector syntax (e.g. `sg.Range` -> skip `sg`, keep `Range`).
        if i < len(text) && text[i] == '.' {
            continue
        }

        out^[ident] = true
    }
}

collect_used_type_names :: proc(bindings: []Proc_Binding) -> map[string]bool {
    used := make(map[string]bool)
    for binding in bindings {
        for p in binding.params {
            collect_type_identifiers_from_text(p.odin_type, &used)
        }
        for r in binding.results {
            collect_type_identifiers_from_text(r.odin_type, &used)
        }
    }
    return used
}

unwrap_paren_expr :: proc(expr: ^ast.Expr) -> ^ast.Expr {
    current := expr
    for current != nil {
        paren, is_paren := current.derived_expr.(^ast.Paren_Expr)
        if !is_paren || paren == nil || paren.expr == nil {
            break
        }
        current = paren.expr
    }
    return current
}

is_explicit_type_decl_expr :: proc(expr: ^ast.Expr) -> bool {
    if expr == nil {
        return false
    }
    node := unwrap_paren_expr(expr)
    if node == nil {
        return false
    }
    if _, ok := node.derived_expr.(^ast.Typeid_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Helper_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Distinct_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Poly_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Proc_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Pointer_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Multi_Pointer_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Array_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Dynamic_Array_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Fixed_Capacity_Dynamic_Array_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Struct_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Union_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Enum_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Bit_Set_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Map_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Relative_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Matrix_Type); ok do return true
    if _, ok := node.derived_expr.(^ast.Bit_Field_Type); ok do return true
    return false
}

is_alias_type_decl_expr :: proc(expr: ^ast.Expr) -> bool {
    if expr == nil {
        return false
    }
    node := unwrap_paren_expr(expr)
    if node == nil {
        return false
    }
    if _, ok := node.derived_expr.(^ast.Ident); ok do return true
    if _, ok := node.derived_expr.(^ast.Selector_Expr); ok do return true
    if _, ok := node.derived_expr.(^ast.Index_Expr); ok do return true
    return false
}

collect_struct_fields :: proc(file: ^ast.File, struct_type: ^ast.Struct_Type) -> []Named_Type_Field {
    fields := make([dynamic]Named_Type_Field)
    if struct_type == nil || struct_type.fields == nil {
        return fields[:]
    }

    for field in struct_type.fields.list {
        if field == nil || field.type == nil {
            continue
        }

        type_text := compact_type_text(extract_expr_text(file.src, field.type))
        if type_text == "" {
            continue
        }

        if len(field.names) == 0 {
            // DUMBAI: anonymous/using fields don't have stable JS object keys in generated decode contracts.
            continue
        }

        for name_expr in field.names {
            name, ok := extract_ident_name(name_expr)
            if !ok || name == "_" {
                continue
            }
            append(&fields, Named_Type_Field{name = name, odin_type = type_text})
        }
    }

    return fields[:]
}

build_named_type_def :: proc(file: ^ast.File, name: string, expr: ^ast.Expr) -> Named_Type_Def {
    def := Named_Type_Def {
        name      = name,
        kind      = .Alias,
        odin_type = compact_type_text(extract_expr_text(file.src, expr)),
    }

    node := unwrap_paren_expr(expr)
    if node == nil {
        return def
    }

    if struct_type, ok := node.derived_expr.(^ast.Struct_Type); ok {
        def.kind = .Struct
        def.fields = collect_struct_fields(file, struct_type)
        return def
    }
    if _, ok := node.derived_expr.(^ast.Enum_Type); ok {
        def.kind = .Enum
        return def
    }
    if _, ok := node.derived_expr.(^ast.Bit_Set_Type); ok {
        def.kind = .Bit_Set
        return def
    }
    // DUMBAI: other declaration expressions remain treated as plain aliases.

    return def
}

collect_named_type_defs :: proc(
    pkg: ^ast.Package,
    output_abs: string,
    bindings: []Proc_Binding,
) -> map[string]Named_Type_Def {
    defs := make(map[string]Named_Type_Def)
    used_names := collect_used_type_names(bindings)

    files := make([dynamic]^ast.File, 0, len(pkg.files))
    for _, file in pkg.files {
        if file == nil do continue
        if is_ignored_source_file(file.fullpath, output_abs) do continue
        append(&files, file)
    }
    slice.sort_by(files[:], proc(lhs, rhs: ^ast.File) -> bool {
        return lhs.fullpath < rhs.fullpath
    })

    changed := true
    for changed {
        changed = false
        for file in files {
            for stmt in file.decls {
                decl, is_value_decl := stmt.derived_stmt.(^ast.Value_Decl)
                if !is_value_decl || decl == nil {
                    continue
                }
                if decl.is_mutable || decl.type != nil {
                    continue
                }

                count := min(len(decl.names), len(decl.values))
                for i := 0; i < count; i += 1 {
                    name, ok := extract_ident_name(decl.names[i])
                    if !ok {
                        continue
                    }
                    if _, exists := defs[name]; exists {
                        continue
                    }

                    value_expr := decl.values[i]
                    if value_expr == nil {
                        continue
                    }
                    if _, is_proc := value_expr.derived_expr.(^ast.Proc_Lit); is_proc {
                        continue
                    }

                    explicit := is_explicit_type_decl_expr(value_expr)
                    if !explicit {
                        if !used_names[name] || !is_alias_type_decl_expr(value_expr) {
                            continue
                        }
                    }

                    def := build_named_type_def(file, name, value_expr)
                    defs[name] = def
                    changed = true

                    if def.kind == .Struct {
                        for field in def.fields {
                            collect_type_identifiers_from_text(field.odin_type, &used_names)
                        }
                    } else {
                        collect_type_identifiers_from_text(def.odin_type, &used_names)
                    }
                }
            }
        }
    }

    return defs
}

quote_odin_string :: proc(raw: string) -> string {
    sb := strings.builder_make_len_cap(0, len(raw) + 16)
    strings.write_byte(&sb, '"')
    for i := 0; i < len(raw); i += 1 {
        switch c := raw[i]; c {
        case '\\':
            strings.write_string(&sb, "\\\\")
        case '"':
            strings.write_string(&sb, "\\\"")
        case '\n':
            strings.write_string(&sb, "\\n")
        case '\r':
            strings.write_string(&sb, "\\r")
        case '\t':
            strings.write_string(&sb, "\\t")
        case:
            strings.write_byte(&sb, c)
        }
    }
    strings.write_byte(&sb, '"')
    return strings.to_string(sb)
}

write_line :: proc(sb: ^strings.Builder, line := "") {
    strings.write_string(sb, line)
    strings.write_byte(sb, '\n')
}

write_non_web_build_tags :: proc(sb: ^strings.Builder) {
    // DUMBAI: generated JS engine bindings are native-only and should be excluded from web targets.
    write_line(sb, "#+build !js")
    write_line(sb, "#+build !wasi")
    write_line(sb, "#+build !orca")
    write_line(sb)
}

with_open_brace :: proc(line: string) -> string {
    out := strings.builder_make_len_cap(0, len(line) + 1)
    strings.write_string(&out, line)
    strings.write_byte(&out, '{')
    return strings.to_string(out)
}

contains_substring :: proc(text, needle: string) -> bool {
    if len(needle) == 0 do return true
    if len(needle) > len(text) do return false
    for i := 0; i + len(needle) <= len(text); i += 1 {
        if text[i:i + len(needle)] == needle {
            return true
        }
    }
    return false
}

is_ts_identifier :: proc(raw: string) -> bool {
    if len(raw) == 0 do return false
    first := raw[0]
    if !(is_ascii_letter(first) || first == '_' || first == '$') {
        return false
    }
    for i := 1; i < len(raw); i += 1 {
        c := raw[i]
        if !(is_ascii_letter(c) || is_ascii_digit(c) || c == '_' || c == '$') {
            return false
        }
    }
    return true
}

ts_param_name :: proc(raw: string, fallback: string) -> string {
    cleaned := raw
    if strings.has_prefix(cleaned, "$") {
        cleaned = cleaned[1:]
    }
    out := sanitize_identifier(cleaned)
    if out == "" || out == "_" || !is_ts_identifier(out) {
        out = sanitize_identifier(fallback)
    }
    if out == "" || out == "_" || !is_ts_identifier(out) {
        out = "arg"
    }
    return out
}

parse_odin_fixed_array_type :: proc(text: string) -> (count_text, elem: string, ok: bool) {
    if len(text) < 3 || text[0] != '[' {
        return
    }

    close_idx := -1
    for i := 1; i < len(text); i += 1 {
        if text[i] == ']' {
            close_idx = i
            break
        }
    }
    if close_idx < 0 || close_idx + 1 >= len(text) {
        return
    }

    count_text = strings.trim_space(text[1:close_idx])
    elem = strings.trim_space(text[close_idx + 1:])
    ok = count_text != "" && elem != ""
    return
}

parse_odin_matrix_type :: proc(text: string) -> (rows_text, cols_text, elem: string, ok: bool) {
    if !strings.has_prefix(text, "matrix[") {
        return
    }

    start := len("matrix[")
    close_idx := -1
    for i := start; i < len(text); i += 1 {
        if text[i] == ']' {
            close_idx = i
            break
        }
    }
    if close_idx < 0 || close_idx + 1 >= len(text) {
        return
    }

    dims := strings.trim_space(text[start:close_idx])
    comma := strings.index(dims, ",")
    if comma <= 0 || comma >= len(dims) - 1 {
        return
    }

    rows_text = strings.trim_space(dims[:comma])
    cols_text = strings.trim_space(dims[comma + 1:])
    elem = strings.trim_space(text[close_idx + 1:])
    ok = rows_text != "" && cols_text != "" && elem != ""
    return
}

parse_decimal_int :: proc(text: string) -> (value: int, ok: bool) {
    t := strings.trim_space(text)
    if t == "" {
        return
    }
    for i := 0; i < len(t); i += 1 {
        c := t[i]
        if !is_ascii_digit(c) {
            return
        }
        value = value * 10 + int(c - '0')
    }
    ok = true
    return
}

ts_tuple_type :: proc(elem_ts: string, count: int) -> string {
    if count <= 0 {
        return "[]"
    }
    if count > 32 {
        return fmt.aprintf("Array<%s>", elem_ts, allocator = context.allocator)
    }
    parts := make([dynamic]string, 0, count)
    for _ in 0 ..< count {
        append(&parts, elem_ts)
    }
    return fmt.aprintf("[%s]", join_csv(parts[:]), allocator = context.allocator)
}

is_odin_identifier :: proc(raw: string) -> bool {
    if len(raw) == 0 {
        return false
    }
    first := raw[0]
    if !(is_ascii_letter(first) || first == '_') {
        return false
    }
    for i := 1; i < len(raw); i += 1 {
        c := raw[i]
        if !(is_ascii_letter(c) || is_ascii_digit(c) || c == '_') {
            return false
        }
    }
    return true
}

ts_alias_name_for_odin :: proc(name: string, ts_ctx: ^TS_Render_Context) -> string {
    if ts_ctx == nil {
        return name
    }
    if alias, ok := ts_ctx.named_alias_name[name]; ok {
        return alias
    }

    alias := name
    if !is_ts_identifier(alias) {
        alias = sanitize_identifier(alias)
    }
    if alias == "" || !is_ts_identifier(alias) {
        alias = fmt.aprintf("Odin_%s", sanitize_identifier(name), allocator = context.allocator)
    }
    ts_ctx.named_alias_name[name] = alias
    return alias
}

ts_guess_named_type :: proc(name: string) -> (ts: string, ok: bool) {
    if strings.has_suffix(name, "vec2") || name == "vec2" {
        return "[number, number]", true
    }
    if strings.has_suffix(name, "vec3") || name == "vec3" {
        return "[number, number, number]", true
    }
    if strings.has_suffix(name, "vec4") || name == "vec4" {
        return "[number, number, number, number]", true
    }
    if strings.has_suffix(name, "mat2") || name == "mat2" {
        return "[number, number, number, number]", true
    }
    if strings.has_suffix(name, "mat3") || name == "mat3" {
        return "[number, number, number, number, number, number, number, number, number]", true
    }
    if strings.has_suffix(name, "mat4") || name == "mat4" {
        return "[number, number, number, number, number, number, number, number, number, number, number, number, number, number, number, number]",
            true
    }
    if name == "Color" || strings.has_suffix(name, "Color") {
        return "[number, number, number, number]", true
    }
    if name == "Rect" || strings.has_suffix(name, "Rect") {
        return "{ pos: [number, number]; size: [number, number] }", true
    }
    return "", false
}

ensure_named_ts_type :: proc(name: string, ts_ctx: ^TS_Render_Context) -> string {
    if ts_ctx == nil {
        if guessed, ok := ts_guess_named_type(name); ok {
            return guessed
        }
        return "JscObject"
    }

    alias_name := ts_alias_name_for_odin(name, ts_ctx)
    if _, exists := ts_ctx.named_ts_exprs[alias_name]; exists {
        return alias_name
    }

    if resolving, exists := ts_ctx.resolving_named[name]; exists && resolving {
        // DUMBAI: break recursive aliases by degrading the cycle edge to unknown.
        ts_ctx.named_ts_exprs[alias_name] = "unknown"
        return alias_name
    }
    ts_ctx.resolving_named[name] = true

    expr := ""
    if guessed, ok := ts_guess_named_type(name); ok {
        expr = guessed
    } else if def, ok := ts_ctx.named_defs[name]; ok {
        switch def.kind {
        case .Enum, .Bit_Set:
            expr = "number"

        case .Struct:
            if len(def.fields) == 0 {
                expr = "JscObject"
            } else {
                fields := make([dynamic]string)
                for field in def.fields {
                    field_name := field.name
                    if !is_ts_identifier(field_name) {
                        field_name = quote_odin_string(field_name)
                    }
                    field_type := map_odin_type_to_ts(field.odin_type, ts_ctx)
                    append(&fields, fmt.aprintf("%s: %s", field_name, field_type, allocator = context.allocator))
                }
                expr_builder := strings.builder_make()
                // DUMBAI: avoid formatter brace parsing edge-cases when emitting TS object literal types.
                strings.write_string(&expr_builder, "{ ")
                strings.write_string(&expr_builder, join_csv(fields[:]))
                strings.write_string(&expr_builder, " }")
                expr = strings.to_string(expr_builder)
            }

        case .Alias:
            expr = map_odin_type_to_ts(def.odin_type, ts_ctx)
            if expr == alias_name {
                expr = "unknown"
            }
        }
    } else {
        expr = "JscObject"
    }

    if expr == "" {
        expr = "unknown"
    }

    ts_ctx.named_ts_exprs[alias_name] = expr
    ts_ctx.resolving_named[name] = false
    return alias_name
}

map_odin_type_to_ts :: proc(odin_type: string, ts_ctx: ^TS_Render_Context) -> string {
    t := compact_type_text(strings.trim_space(odin_type))
    if t == "" {
        return "unknown"
    }

    if strings.has_prefix(t, "distinct") {
        rest := strings.trim_space(t[len("distinct"):])
        if rest != "" {
            return map_odin_type_to_ts(rest, ts_ctx)
        }
    }

    if t == "bool" do return "boolean"
    if t == "string" || t == "cstring" do return "string"
    if t == "rawptr" do return "JscOpaqueHandle<\"rawptr\"> | null"

    if t == "byte" ||
       t == "rune" ||
       t == "i8" ||
       t == "i16" ||
       t == "i32" ||
       t == "i64" ||
       t == "i128" ||
       t == "int" ||
       t == "u8" ||
       t == "u16" ||
       t == "u32" ||
       t == "u64" ||
       t == "u128" ||
       t == "uint" ||
       t == "uintptr" ||
       t == "f16" ||
       t == "f32" ||
       t == "f64" ||
       t == "complex64" ||
       t == "complex128" ||
       t == "quaternion128" ||
       t == "quaternion256" {
        return "number"
    }

    if strings.has_prefix(t, "^") {
        pointee := strings.trim_space(t[1:])
        if pointee == "" {
            pointee = "rawptr"
        }
        return fmt.aprintf("JscOpaqueHandle<%s> | null", quote_odin_string(pointee), allocator = context.allocator)
    }
    if strings.has_prefix(t, "[^]") {
        pointee := strings.trim_space(t[len("[^]"):])
        if pointee == "" {
            pointee = "rawptr"
        }
        return fmt.aprintf("JscOpaqueHandle<%s> | null", quote_odin_string(pointee), allocator = context.allocator)
    }

    if strings.has_prefix(t, "[]u8") {
        return "Uint8Array | number[]"
    }
    if strings.has_prefix(t, "[]") {
        elem_ts := map_odin_type_to_ts(strings.trim_space(t[2:]), ts_ctx)
        return fmt.aprintf("Array<%s>", elem_ts, allocator = context.allocator)
    }

    if count_text, elem, ok := parse_odin_fixed_array_type(t); ok {
        elem_ts := map_odin_type_to_ts(elem, ts_ctx)
        if count, is_numeric := parse_decimal_int(count_text); is_numeric {
            return ts_tuple_type(elem_ts, count)
        }
        return fmt.aprintf("Array<%s>", elem_ts, allocator = context.allocator)
    }

    if rows_text, cols_text, elem, ok := parse_odin_matrix_type(t); ok {
        elem_ts := map_odin_type_to_ts(elem, ts_ctx)
        rows, rows_ok := parse_decimal_int(rows_text)
        cols, cols_ok := parse_decimal_int(cols_text)
        if rows_ok && cols_ok {
            return ts_tuple_type(elem_ts, rows * cols)
        }
        return fmt.aprintf("Array<%s>", elem_ts, allocator = context.allocator)
    }

    if strings.has_prefix(t, "enum") || strings.has_prefix(t, "bit_set[") {
        return "number"
    }
    if strings.has_prefix(t, "map[") {
        return "Record<string, unknown>"
    }
    if strings.has_prefix(t, "proc") || contains_substring(t, "#typeproc") {
        return "(...args: unknown[]) => unknown"
    }
    if strings.has_prefix(t, "any") || contains_substring(t, "Type_Info") {
        return "unknown"
    }
    if strings.has_prefix(t, "struct{") {
        return "JscObject"
    }

    if dot := strings.last_index(t, "."); dot >= 0 && dot + 1 < len(t) {
        trailing := t[dot + 1:]
        if guessed, ok := ts_guess_named_type(trailing); ok {
            return guessed
        }
        return "JscObject"
    }

    if is_odin_identifier(t) {
        return ensure_named_ts_type(t, ts_ctx)
    }

    return "unknown"
}

join_csv :: proc(parts: []string) -> string {
    if len(parts) == 0 do return ""
    sb := strings.builder_make()
    for p, i in parts {
        if i > 0 {
            strings.write_string(&sb, ", ")
        }
        strings.write_string(&sb, p)
    }
    return strings.to_string(sb)
}

ts_namespace_type_name :: proc(namespace: string) -> string {
    out := make([dynamic]byte, 0, len(namespace) + len("Bindings") + 4)
    upper_next := true
    for i := 0; i < len(namespace); i += 1 {
        c := namespace[i]
        if is_ascii_letter(c) || is_ascii_digit(c) {
            ch := c
            if upper_next && ch >= 'a' && ch <= 'z' {
                ch = ch - ('a' - 'A')
            }
            append(&out, ch)
            upper_next = false
        } else {
            upper_next = true
        }
    }
    if len(out) == 0 || is_ascii_digit(out[0]) {
        prefixed := make([dynamic]byte, 0, len(out) + 3)
        append(&prefixed, 'L', 'i', 'b')
        append(&prefixed, ..out[:])
        out = prefixed
    }
    base := string(out[:])
    return fmt.aprintf("%sBindings", base, allocator = context.allocator)
}

prime_dts_type_context :: proc(bindings: []Proc_Binding, ts_ctx: ^TS_Render_Context) {
    for info in bindings {
        if !info.supported {
            continue
        }
        for p in info.params {
            if !p.runtime_exposed || p.unsupported {
                continue
            }
            _ = map_odin_type_to_ts(p.odin_type, ts_ctx)
        }
        for r in info.results {
            if r.unsupported {
                continue
            }
            _ = map_odin_type_to_ts(r.odin_type, ts_ctx)
        }
    }
}

render_dts_function_entry :: proc(sb: ^strings.Builder, info: Proc_Binding, ts_ctx: ^TS_Render_Context) {
    prop_name := info.js_name
    use_method_syntax := is_ts_identifier(prop_name)
    render_name := prop_name if use_method_syntax else quote_odin_string(prop_name)

    if !info.supported {
        write_line(sb, fmt.aprintf("    // unsupported: %s", info.unsupported_reason, allocator = context.allocator))
        write_line(
            sb,
            fmt.aprintf("    %s: (...args: unknown[]) => never;", render_name, allocator = context.allocator),
        )
        return
    }

    param_parts := make([dynamic]string)
    runtime_idx := 0
    for p in info.params {
        if !p.runtime_exposed {
            continue
        }
        pname := ts_param_name(p.name, fmt.aprintf("arg%d", runtime_idx, allocator = context.temp_allocator))
        ptype := "unknown"
        if !p.unsupported {
            ptype = map_odin_type_to_ts(p.odin_type, ts_ctx)
        }
        optional := "?" if p.has_default else ""
        append(&param_parts, fmt.aprintf("%s%s: %s", pname, optional, ptype, allocator = context.allocator))
        runtime_idx += 1
    }
    params_joined := join_csv(param_parts[:])

    return_type := "void"
    if info.diverging {
        return_type = "never"
    } else if len(info.results) == 1 {
        if info.results[0].unsupported {
            return_type = "unknown"
        } else {
            return_type = map_odin_type_to_ts(info.results[0].odin_type, ts_ctx)
        }
    } else if len(info.results) > 1 {
        parts := make([dynamic]string)
        for r in info.results {
            if r.unsupported {
                append(&parts, "unknown")
            } else {
                append(&parts, map_odin_type_to_ts(r.odin_type, ts_ctx))
            }
        }
        return_type = fmt.aprintf("[%s]", join_csv(parts[:]), allocator = context.allocator)
    }

    if use_method_syntax {
        write_line(
            sb,
            fmt.aprintf("    %s(%s): %s;", render_name, params_joined, return_type, allocator = context.allocator),
        )
    } else {
        write_line(
            sb,
            fmt.aprintf("    %s: (%s) => %s;", render_name, params_joined, return_type, allocator = context.allocator),
        )
    }
}

render_dts_output :: proc(
    namespace_root: string,
    namespace_leaf: string,
    bindings: []Proc_Binding,
    named_defs: map[string]Named_Type_Def,
) -> string {
    sb := strings.builder_make()
    root_name := sanitize_identifier(namespace_root)
    leaf_name := sanitize_identifier(namespace_leaf)
    type_name := ts_namespace_type_name(leaf_name)
    ts_ctx := TS_Render_Context {
        named_defs       = named_defs,
        named_ts_exprs   = make(map[string]string),
        named_alias_name = make(map[string]string),
        resolving_named  = make(map[string]bool),
    }

    prime_dts_type_context(bindings, &ts_ctx)

    write_line(&sb, "// DUMBAI: generated by jsc_bindgen.odin; do not edit by hand.")
    write_line(&sb, "export type JscObject = Record<string, unknown>;")
    write_line(&sb, "export type JscOpaqueHandle<T extends string = string> = { readonly __jscOpaqueType?: T };")
    write_line(&sb)

    alias_names := make([dynamic]string)
    for alias, _ in ts_ctx.named_ts_exprs {
        append(&alias_names, alias)
    }
    slice.sort_by(alias_names[:], proc(lhs, rhs: string) -> bool {
        return lhs < rhs
    })
    for alias in alias_names {
        expr := ts_ctx.named_ts_exprs[alias]
        write_line(&sb, fmt.aprintf("export type %s = %s;", alias, expr, allocator = context.allocator))
    }
    if len(alias_names) > 0 {
        write_line(&sb)
    }

    write_line(&sb, fmt.aprintf("export type %s = ", type_name, allocator = context.allocator))
    write_line(&sb, "{")
    for info in bindings {
        render_dts_function_entry(&sb, info, &ts_ctx)
    }
    write_line(&sb, "};")
    write_line(&sb)
    write_line(&sb, "declare global {")
    write_line(&sb, with_open_brace(fmt.aprintf("    var %s: ", root_name, allocator = context.allocator)))
    write_line(&sb, fmt.aprintf("        %s: %s;", leaf_name, type_name, allocator = context.allocator))
    write_line(&sb, "    };")
    write_line(&sb, "    interface GlobalThis {")
    write_line(&sb, with_open_brace(fmt.aprintf("        %s: ", root_name, allocator = context.allocator)))
    write_line(&sb, fmt.aprintf("            %s: %s;", leaf_name, type_name, allocator = context.allocator))
    write_line(&sb, "        };")
    write_line(&sb, "    }")
    write_line(&sb, "}")
    write_line(&sb)
    write_line(&sb, "export {}")

    return strings.to_string(sb)
}

render_stub_wrapper :: proc(sb: ^strings.Builder, info: Proc_Binding) {
    write_line(sb, fmt.aprintf("%s :: proc \"c\" (", info.wrapper_name, allocator = context.allocator))
    write_line(sb, "    ctx: jsc.JSContextRef,")
    write_line(sb, "    function: jsc.JSObjectRef,")
    write_line(sb, "    thisObject: jsc.JSObjectRef,")
    write_line(sb, "    argc: c.size_t,")
    write_line(sb, "    argv: [^]jsc.JSValueRef,")
    write_line(sb, "    exception: ^jsc.JSValueRef,")
    write_line(sb, ") -> jsc.JSValueRef {")
    write_line(sb, "    _ = function")
    write_line(sb, "    _ = thisObject")
    write_line(sb, "    _ = argc")
    write_line(sb, "    _ = argv")
    write_line(sb, "    context = runtime.default_context()")
    msg := fmt.aprintf("%s is not bindable (%s)", info.js_name, info.unsupported_reason, allocator = context.allocator)
    write_line(
        sb,
        fmt.aprintf(
            "    jsc_set_exception_text(ctx, exception, %s)",
            quote_odin_string(msg),
            allocator = context.allocator,
        ),
    )
    write_line(sb, "    return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "}")
}

render_supported_wrapper :: proc(sb: ^strings.Builder, info: Proc_Binding) {
    write_line(sb, fmt.aprintf("%s :: proc \"c\" (", info.wrapper_name, allocator = context.allocator))
    write_line(sb, "    ctx: jsc.JSContextRef,")
    write_line(sb, "    function: jsc.JSObjectRef,")
    write_line(sb, "    thisObject: jsc.JSObjectRef,")
    write_line(sb, "    argc: c.size_t,")
    write_line(sb, "    argv: [^]jsc.JSValueRef,")
    write_line(sb, "    exception: ^jsc.JSValueRef,")
    write_line(sb, ") -> jsc.JSValueRef {")
    write_line(sb, "    _ = function")
    write_line(sb, "    _ = thisObject")
    write_line(sb, "    context = runtime.default_context()")

    if info.total_runtime_params == info.required_runtime_params {
        write_line(
            sb,
            with_open_brace(
                fmt.aprintf("    if argc != c.size_t(%d) ", info.total_runtime_params, allocator = context.allocator),
            ),
        )
        msg := fmt.aprintf(
            "%s expects exactly %d argument(s)",
            info.js_name,
            info.total_runtime_params,
            allocator = context.allocator,
        )
        write_line(
            sb,
            fmt.aprintf(
                "        jsc_set_exception_text(ctx, exception, %s)",
                quote_odin_string(msg),
                allocator = context.allocator,
            ),
        )
        write_line(sb, "        return jsc.ValueMakeUndefined(ctx)")
        write_line(sb, "    }")
    } else {
        write_line(
            sb,
            with_open_brace(
                fmt.aprintf(
                    "    if argc < c.size_t(%d) || argc > c.size_t(%d) ",
                    info.required_runtime_params,
                    info.total_runtime_params,
                    allocator = context.allocator,
                ),
            ),
        )
        msg := fmt.aprintf(
            "%s expects %d..%d argument(s)",
            info.js_name,
            info.required_runtime_params,
            info.total_runtime_params,
            allocator = context.allocator,
        )
        write_line(
            sb,
            fmt.aprintf(
                "        jsc_set_exception_text(ctx, exception, %s)",
                quote_odin_string(msg),
                allocator = context.allocator,
            ),
        )
        write_line(sb, "        return jsc.ValueMakeUndefined(ctx)")
        write_line(sb, "    }")
    }

    runtime_idx := 0
    for p in info.params {
        if p.is_comptime && !p.runtime_exposed && !p.is_implicit {
            // DUMBAI: compile-time params are injected directly into the call expression.
            continue
        }
        if p.is_implicit && p.odin_type == "" {
            // DUMBAI: untyped implicit defaults are injected directly into call args, no local wrapper variable needed.
            continue
        }
        write_line(sb, fmt.aprintf("    %s: %s", p.local_name, p.odin_type, allocator = context.allocator))
        if p.runtime_exposed {
            write_line(
                sb,
                with_open_brace(
                    fmt.aprintf("    if argc > c.size_t(%d) ", runtime_idx, allocator = context.allocator),
                ),
            )
            write_line(
                sb,
                fmt.aprintf(
                    "        if !jsc_decode_value(ctx, argv[%d], exception, &%s) do return jsc.ValueMakeUndefined(ctx)",
                    runtime_idx,
                    p.local_name,
                    allocator = context.allocator,
                ),
            )
            write_line(sb, "    } else {")
            if p.has_default {
                write_line(
                    sb,
                    fmt.aprintf("        %s = %s", p.local_name, p.default_expr, allocator = context.allocator),
                )
            } else {
                msg := fmt.aprintf(
                    "internal bindgen error: missing required argument for %s",
                    p.name,
                    allocator = context.allocator,
                )
                write_line(
                    sb,
                    fmt.aprintf(
                        "        jsc_set_exception_text(ctx, exception, %s)",
                        quote_odin_string(msg),
                        allocator = context.allocator,
                    ),
                )
                write_line(sb, "        return jsc.ValueMakeUndefined(ctx)")
            }
            write_line(sb, "    }")
            runtime_idx += 1
            continue
        }

        if p.is_implicit && p.has_default {
            write_line(sb, fmt.aprintf("    %s = %s", p.local_name, p.default_expr, allocator = context.allocator))
            continue
        }

        // DUMBAI: non-runtime params are pre-bound during wrapper planning; this fallback keeps emitted code explicit.
        write_line(sb, fmt.aprintf("    %s = %s", p.local_name, p.default_expr, allocator = context.allocator))
    }

    call_sb := strings.builder_make()
    strings.write_string(&call_sb, info.symbol)
    strings.write_string(&call_sb, "(")
    for arg, i in info.call_args {
        if i > 0 {
            strings.write_string(&call_sb, ", ")
        }
        strings.write_string(&call_sb, arg)
    }
    strings.write_string(&call_sb, ")")
    call_expr := strings.to_string(call_sb)

    if info.diverging {
        // DUMBAI: diverging targets (`-> !`) never return, so wrapper must not emit an unreachable return.
        write_line(sb, fmt.aprintf("    %s", call_expr, allocator = context.allocator))
        write_line(sb, "}")
        return
    }

    if len(info.results) == 0 {
        write_line(sb, fmt.aprintf("    %s", call_expr, allocator = context.allocator))
        write_line(sb, "    return jsc.ValueMakeUndefined(ctx)")
        write_line(sb, "}")
        return
    }

    if len(info.results) == 1 {
        write_line(sb, fmt.aprintf("    result := %s", call_expr, allocator = context.allocator))
        write_line(
            sb,
            fmt.aprintf("    return jsc_encode_value(ctx, result, exception)", allocator = context.allocator),
        )
        write_line(sb, "}")
        return
    }

    names := make([dynamic]string)
    for i := 0; i < len(info.results); i += 1 {
        append(&names, fmt.aprintf("ret_%d", i, allocator = context.allocator))
    }
    assign_list := strings.join(names[:], ", ", context.allocator)
    write_line(sb, fmt.aprintf("    %s := %s", assign_list, call_expr, allocator = context.allocator))

    arr_name := fmt.aprintf("result_values_%s", sanitize_identifier(info.wrapper_name), allocator = context.allocator)
    write_line(
        sb,
        with_open_brace(
            fmt.aprintf("    %s := [%d]jsc.JSValueRef", arr_name, len(info.results), allocator = context.allocator),
        ),
    )
    for i := 0; i < len(info.results); i += 1 {
        write_line(
            sb,
            fmt.aprintf("        jsc_encode_value(ctx, ret_%d, exception),", i, allocator = context.allocator),
        )
    }
    write_line(sb, "    }")
    write_line(sb, "    if jsc_has_exception(exception) do return jsc.ValueMakeUndefined(ctx)")
    write_line(
        sb,
        fmt.aprintf(
            "    arr := jsc.ObjectMakeArray(ctx, c.size_t(%d), raw_data(%s[:]), exception)",
            len(info.results),
            arr_name,
            allocator = context.allocator,
        ),
    )
    write_line(sb, "    if jsc_has_exception(exception) do return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "    return jsc.JSValueRef(arr)")
    write_line(sb, "}")
}

render_wrapper :: proc(sb: ^strings.Builder, info: Proc_Binding) {
    if !info.supported {
        render_stub_wrapper(sb, info)
        return
    }
    render_supported_wrapper(sb, info)
}

render_support_block :: proc(sb: ^strings.Builder) {
    // DUMBAI: support helpers are generated once and shared by all wrappers.
    write_line(sb, "Raw_Slice_Header :: struct {")
    write_line(sb, "    data: rawptr,")
    write_line(sb, "    len:  int,")
    write_line(sb, "}")
    write_line(sb)

    write_line(sb, "jsc_pointer_classes: map[typeid]jsc.JSClassRef")
    write_line(sb, "jsc_pointer_class_names: map[typeid]cstring")
    write_line(sb)

    write_line(
        sb,
        "jsc_set_exception_message :: proc(ctx: jsc.JSContextRef, exception: ^jsc.JSValueRef, message: cstring) {",
    )
    write_line(sb, "    context = runtime.default_context()")
    write_line(sb, "    if exception == nil do return")
    write_line(sb, "    msg := jsc.StringCreateWithUTF8CString(message)")
    write_line(sb, "    defer jsc.StringRelease(msg)")
    write_line(sb, "    exception^ = jsc.ValueMakeString(ctx, msg)")
    write_line(sb, "}")
    write_line(sb)

    write_line(sb, "jsc_set_exception_text :: proc(ctx: jsc.JSContextRef, exception: ^jsc.JSValueRef, text: string) {")
    write_line(sb, "    context = runtime.default_context()")
    write_line(sb, "    if exception == nil do return")
    write_line(sb, "    cmsg, cerr := strings.clone_to_cstring(text, context.temp_allocator)")
    write_line(sb, "    if cerr != nil do return")
    write_line(sb, "    jsc_set_exception_message(ctx, exception, cmsg)")
    write_line(sb, "}")
    write_line(sb)

    write_line(sb, "jsc_has_exception :: proc(exception: ^jsc.JSValueRef) -> bool {")
    write_line(sb, "    return exception != nil && exception^ != nil")
    write_line(sb, "}")
    write_line(sb)

    write_line(sb, "jsc_type_name :: proc(info: ^runtime.Type_Info) -> string {")
    write_line(sb, "    if info == nil do return \"<nil>\"")
    write_line(sb, "    return fmt.aprintf(\"%v\", info.id, allocator = context.temp_allocator)")
    write_line(sb, "}")
    write_line(sb)

    write_line(sb, "jsc_make_js_string :: proc(text: string) -> (jsc.JSStringRef, bool) {")
    write_line(sb, "    ctext, cerr := strings.clone_to_cstring(text, context.temp_allocator)")
    write_line(sb, "    if cerr != nil {")
    write_line(sb, "        return nil, false")
    write_line(sb, "    }")
    write_line(sb, "    return jsc.StringCreateWithUTF8CString(ctext), true")
    write_line(sb, "}")
    write_line(sb)

    write_line(
        sb,
        "jsc_value_to_string :: proc(ctx: jsc.JSContextRef, value: jsc.JSValueRef, exception: ^jsc.JSValueRef) -> (string, bool) {",
    )
    write_line(sb, "    js := jsc.ValueToStringCopy(ctx, value, exception)")
    write_line(sb, "    if jsc_has_exception(exception) || js == nil {")
    write_line(sb, "        return \"\", false")
    write_line(sb, "    }")
    write_line(sb, "    defer jsc.StringRelease(js)")
    write_line(sb, "    cap := jsc.StringGetMaximumUTF8CStringSize(js)")
    write_line(sb, "    if cap <= 0 {")
    write_line(sb, "        return \"\", true")
    write_line(sb, "    }")
    write_line(sb, "    buf := make([]c.char, int(cap), context.temp_allocator)")
    write_line(sb, "    n := jsc.StringGetUTF8CString(js, raw_data(buf), cap)")
    write_line(sb, "    if n <= 0 {")
    write_line(sb, "        return \"\", true")
    write_line(sb, "    }")
    write_line(sb, "    return string(cstring(raw_data(buf))), true")
    write_line(sb, "}")
    write_line(sb)

    write_line(sb, "jsc_string_to_value :: proc(ctx: jsc.JSContextRef, text: string) -> jsc.JSValueRef {")
    write_line(sb, "    js, ok := jsc_make_js_string(text)")
    write_line(sb, "    if !ok do return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "    defer jsc.StringRelease(js)")
    write_line(sb, "    return jsc.ValueMakeString(ctx, js)")
    write_line(sb, "}")
    write_line(sb)

    write_line(
        sb,
        "jsc_get_array_like_length :: proc(ctx: jsc.JSContextRef, object: jsc.JSObjectRef, exception: ^jsc.JSValueRef) -> (int, bool) {",
    )
    write_line(sb, "    if object == nil {")
    write_line(sb, "        return 0, false")
    write_line(sb, "    }")
    write_line(sb, "    length_name := jsc.StringCreateWithUTF8CString(\"length\")")
    write_line(sb, "    defer jsc.StringRelease(length_name)")
    write_line(sb, "    length_value := jsc.ObjectGetProperty(ctx, object, length_name, exception)")
    write_line(sb, "    if jsc_has_exception(exception) {")
    write_line(sb, "        return 0, false")
    write_line(sb, "    }")
    write_line(sb, "    length_number := jsc.ValueToNumber(ctx, length_value, exception)")
    write_line(sb, "    if jsc_has_exception(exception) {")
    write_line(sb, "        return 0, false")
    write_line(sb, "    }")
    write_line(sb, "    if length_number < 0 {")
    write_line(sb, "        return 0, false")
    write_line(sb, "    }")
    write_line(sb, "    return int(length_number), true")
    write_line(sb, "}")
    write_line(sb)

    write_line(sb, "jsc_write_integer :: proc(out: rawptr, signed: bool, size: int, value: f64) -> bool {")
    write_line(sb, "    if signed {")
    write_line(sb, "        iv := i64(value)")
    write_line(sb, "        switch size {")
    write_line(sb, "        case 1: (^i8)(out)^ = i8(iv)")
    write_line(sb, "        case 2: (^i16)(out)^ = i16(iv)")
    write_line(sb, "        case 4: (^i32)(out)^ = i32(iv)")
    write_line(sb, "        case 8: (^i64)(out)^ = i64(iv)")
    write_line(sb, "        case:")
    write_line(sb, "            return false")
    write_line(sb, "        }")
    write_line(sb, "        return true")
    write_line(sb, "    }")
    write_line(sb, "")
    write_line(sb, "    uv := u64(value)")
    write_line(sb, "    switch size {")
    write_line(sb, "    case 1: (^u8)(out)^ = u8(uv)")
    write_line(sb, "    case 2: (^u16)(out)^ = u16(uv)")
    write_line(sb, "    case 4: (^u32)(out)^ = u32(uv)")
    write_line(sb, "    case 8: (^u64)(out)^ = u64(uv)")
    write_line(sb, "    case:")
    write_line(sb, "        return false")
    write_line(sb, "    }")
    write_line(sb, "    return true")
    write_line(sb, "}")
    write_line(sb)

    write_line(sb, "jsc_read_integer :: proc(value: rawptr, signed: bool, size: int) -> (f64, bool) {")
    write_line(sb, "    if signed {")
    write_line(sb, "        switch size {")
    write_line(sb, "        case 1: return f64((^i8)(value)^), true")
    write_line(sb, "        case 2: return f64((^i16)(value)^), true")
    write_line(sb, "        case 4: return f64((^i32)(value)^), true")
    write_line(sb, "        case 8: return f64((^i64)(value)^), true")
    write_line(sb, "        case:")
    write_line(sb, "            return 0, false")
    write_line(sb, "        }")
    write_line(sb, "    }")
    write_line(sb, "")
    write_line(sb, "    switch size {")
    write_line(sb, "    case 1: return f64((^u8)(value)^), true")
    write_line(sb, "    case 2: return f64((^u16)(value)^), true")
    write_line(sb, "    case 4: return f64((^u32)(value)^), true")
    write_line(sb, "    case 8: return f64((^u64)(value)^), true")
    write_line(sb, "    case:")
    write_line(sb, "        return 0, false")
    write_line(sb, "    }")
    write_line(sb, "}")
    write_line(sb)

    write_line(sb, "jsc_get_pointer_class :: proc(info: ^runtime.Type_Info) -> jsc.JSClassRef {")
    write_line(sb, "    context = runtime.default_context()")
    write_line(sb, "    if info == nil do return nil")
    write_line(sb, "")
    write_line(sb, "    id := info.id")
    write_line(sb, "    if jsc_pointer_classes != nil {")
    write_line(sb, "        if class, ok := jsc_pointer_classes[id]; ok {")
    write_line(sb, "            return class")
    write_line(sb, "        }")
    write_line(sb, "    }")
    write_line(sb, "")
    write_line(sb, "    if jsc_pointer_classes == nil {")
    write_line(sb, "        jsc_pointer_classes = make(map[typeid]jsc.JSClassRef)")
    write_line(sb, "    }")
    write_line(sb, "    if jsc_pointer_class_names == nil {")
    write_line(sb, "        jsc_pointer_class_names = make(map[typeid]cstring)")
    write_line(sb, "    }")
    write_line(sb, "")
    write_line(sb, "    name := fmt.aprintf(\"%v\", id, allocator = context.temp_allocator)")
    write_line(sb, "    cname, cerr := strings.clone_to_cstring(name, context.allocator)")
    write_line(sb, "    if cerr != nil {")
    write_line(sb, "        return nil")
    write_line(sb, "    }")
    write_line(sb, "")
    write_line(sb, "    def := jsc.kJSClassDefinitionEmpty")
    write_line(sb, "    def.className = cname")
    write_line(sb, "    class := jsc.ClassCreate(&def)")
    write_line(sb, "")
    write_line(sb, "    // DUMBAI: class names are retained for process lifetime so JSClass metadata remains valid.")
    write_line(sb, "    jsc_pointer_class_names[id] = cname")
    write_line(sb, "    jsc_pointer_classes[id] = class")
    write_line(sb, "    return class")
    write_line(sb, "}")
    write_line(sb)

    write_line(
        sb,
        "jsc_decode_slice_u8 :: proc(ctx: jsc.JSContextRef, value: jsc.JSValueRef, exception: ^jsc.JSValueRef, out: rawptr) -> bool {",
    )
    write_line(sb, "    if jsc.ValueIsNull(ctx, value) || jsc.ValueIsUndefined(ctx, value) {")
    write_line(sb, "        (^Raw_Slice_Header)(out)^ = Raw_Slice_Header{}")
    write_line(sb, "        return true")
    write_line(sb, "    }")
    write_line(sb, "")
    write_line(sb, "    typed_kind := jsc.ValueGetTypedArrayType(ctx, value, exception)")
    write_line(sb, "    if jsc_has_exception(exception) {")
    write_line(sb, "        return false")
    write_line(sb, "    }")
    write_line(sb, "")
    write_line(sb, "    object := jsc.ValueToObject(ctx, value, exception)")
    write_line(sb, "    if jsc_has_exception(exception) || object == nil {")
    write_line(sb, "        return false")
    write_line(sb, "    }")
    write_line(sb, "")
    write_line(sb, "    if typed_kind != .None {")
    write_line(sb, "        ptr: rawptr")
    write_line(sb, "        byte_len := 0")
    write_line(sb, "        if typed_kind == .ArrayBuffer {")
    write_line(sb, "            ptr = jsc.ObjectGetArrayBufferBytesPtr(ctx, object, exception)")
    write_line(sb, "            byte_len = int(jsc.ObjectGetArrayBufferByteLength(ctx, object, exception))")
    write_line(sb, "        } else {")
    write_line(sb, "            ptr = jsc.ObjectGetTypedArrayBytesPtr(ctx, object, exception)")
    write_line(sb, "            byte_len = int(jsc.ObjectGetTypedArrayByteLength(ctx, object, exception))")
    write_line(sb, "        }")
    write_line(sb, "        if jsc_has_exception(exception) {")
    write_line(sb, "            return false")
    write_line(sb, "        }")
    write_line(sb, "")
    write_line(sb, "        buf := make([]u8, byte_len, context.temp_allocator)")
    write_line(sb, "        if byte_len > 0 && ptr != nil {")
    write_line(sb, "            src := ([^]u8)(ptr)")
    write_line(sb, "            for i := 0; i < byte_len; i += 1 {")
    write_line(sb, "                buf[i] = src[i]")
    write_line(sb, "            }")
    write_line(sb, "        }")
    write_line(sb, "        (^Raw_Slice_Header)(out)^ = Raw_Slice_Header{raw_data(buf), byte_len}")
    write_line(sb, "        return true")
    write_line(sb, "    }")
    write_line(sb, "")
    write_line(sb, "    length, ok := jsc_get_array_like_length(ctx, object, exception)")
    write_line(sb, "    if !ok {")
    write_line(
        sb,
        "        jsc_set_exception_text(ctx, exception, \"expected Uint8Array/ArrayBuffer/array for []u8\")",
    )
    write_line(sb, "        return false")
    write_line(sb, "    }")
    write_line(sb, "")
    write_line(sb, "    buf := make([]u8, length, context.temp_allocator)")
    write_line(sb, "    for i := 0; i < length; i += 1 {")
    write_line(sb, "        elem := jsc.ObjectGetPropertyAtIndex(ctx, object, c.uint(i), exception)")
    write_line(sb, "        if jsc_has_exception(exception) {")
    write_line(sb, "            return false")
    write_line(sb, "        }")
    write_line(sb, "        num := jsc.ValueToNumber(ctx, elem, exception)")
    write_line(sb, "        if jsc_has_exception(exception) {")
    write_line(sb, "            return false")
    write_line(sb, "        }")
    write_line(sb, "        buf[i] = u8(num)")
    write_line(sb, "    }")
    write_line(sb, "")
    write_line(sb, "    (^Raw_Slice_Header)(out)^ = Raw_Slice_Header{raw_data(buf), length}")
    write_line(sb, "    return true")
    write_line(sb, "}")
    write_line(sb)

    write_line(
        sb,
        "jsc_encode_slice_u8 :: proc(ctx: jsc.JSContextRef, value: rawptr, exception: ^jsc.JSValueRef) -> jsc.JSValueRef {",
    )
    write_line(sb, "    header := (^Raw_Slice_Header)(value)^")
    write_line(sb, "    array := jsc.ObjectMakeTypedArray(ctx, .Uint8Array, c.size_t(header.len), exception)")
    write_line(sb, "    if jsc_has_exception(exception) {")
    write_line(sb, "        return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "    }")
    write_line(sb, "")
    write_line(sb, "    if header.len > 0 && header.data != nil {")
    write_line(sb, "        dst := ([^]u8)(jsc.ObjectGetTypedArrayBytesPtr(ctx, array, exception))")
    write_line(sb, "        if jsc_has_exception(exception) {")
    write_line(sb, "            return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "        }")
    write_line(sb, "        src := ([^]u8)(header.data)")
    write_line(sb, "        for i := 0; i < header.len; i += 1 {")
    write_line(sb, "            dst[i] = src[i]")
    write_line(sb, "        }")
    write_line(sb, "    }")
    write_line(sb, "")
    write_line(sb, "    return jsc.JSValueRef(array)")
    write_line(sb, "}")
    write_line(sb)

    write_line(
        sb,
        "jsc_decode_by_type :: proc(ctx: jsc.JSContextRef, value: jsc.JSValueRef, exception: ^jsc.JSValueRef, out: rawptr, info: ^runtime.Type_Info) -> bool {",
    )
    write_line(sb, "    if info == nil {")
    write_line(sb, "        jsc_set_exception_text(ctx, exception, \"missing type info\")")
    write_line(sb, "        return false")
    write_line(sb, "    }")
    write_line(sb, "")
    write_line(sb, "    base := runtime.type_info_base(info)")
    write_line(sb, "    switch t in base.variant {")
    write_line(sb, "    case runtime.Type_Info_Boolean:")
    write_line(sb, "        (^bool)(out)^ = jsc.ValueToBoolean(ctx, value)")
    write_line(sb, "        return true")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Integer:")
    write_line(sb, "        number := jsc.ValueToNumber(ctx, value, exception)")
    write_line(sb, "        if jsc_has_exception(exception) {")
    write_line(sb, "            return false")
    write_line(sb, "        }")
    write_line(sb, "        if !jsc_write_integer(out, t.signed, base.size, number) {")
    write_line(sb, "            jsc_set_exception_text(ctx, exception, \"unsupported integer size\")")
    write_line(sb, "            return false")
    write_line(sb, "        }")
    write_line(sb, "        return true")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Rune:")
    write_line(sb, "        number := jsc.ValueToNumber(ctx, value, exception)")
    write_line(sb, "        if jsc_has_exception(exception) {")
    write_line(sb, "            return false")
    write_line(sb, "        }")
    write_line(sb, "        (^rune)(out)^ = rune(number)")
    write_line(sb, "        return true")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Float:")
    write_line(sb, "        number := jsc.ValueToNumber(ctx, value, exception)")
    write_line(sb, "        if jsc_has_exception(exception) {")
    write_line(sb, "            return false")
    write_line(sb, "        }")
    write_line(sb, "        switch base.size {")
    write_line(sb, "        case 4: (^f32)(out)^ = f32(number)")
    write_line(sb, "        case 8: (^f64)(out)^ = f64(number)")
    write_line(sb, "        case:")
    write_line(sb, "            jsc_set_exception_text(ctx, exception, \"unsupported float size\")")
    write_line(sb, "            return false")
    write_line(sb, "        }")
    write_line(sb, "        return true")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_String:")
    write_line(sb, "        text, ok := jsc_value_to_string(ctx, value, exception)")
    write_line(sb, "        if !ok {")
    write_line(sb, "            return false")
    write_line(sb, "        }")
    write_line(sb, "        if t.is_cstring {")
    write_line(sb, "            ctext, cerr := strings.clone_to_cstring(text, context.temp_allocator)")
    write_line(sb, "            if cerr != nil {")
    write_line(sb, "                jsc_set_exception_text(ctx, exception, \"failed to allocate cstring\")")
    write_line(sb, "                return false")
    write_line(sb, "            }")
    write_line(sb, "            (^cstring)(out)^ = ctext")
    write_line(sb, "            return true")
    write_line(sb, "        }")
    write_line(sb, "        (^string)(out)^ = text")
    write_line(sb, "        return true")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Enum:")
    write_line(sb, "        number := jsc.ValueToNumber(ctx, value, exception)")
    write_line(sb, "        if jsc_has_exception(exception) {")
    write_line(sb, "            return false")
    write_line(sb, "        }")
    write_line(sb, "        core := runtime.type_info_core(base)")
    write_line(sb, "        signed := false")
    write_line(sb, "        if core != nil {")
    write_line(sb, "            if int_info, ok := core.variant.(runtime.Type_Info_Integer); ok {")
    write_line(sb, "                signed = int_info.signed")
    write_line(sb, "            }")
    write_line(sb, "        }")
    write_line(sb, "        if !jsc_write_integer(out, signed, base.size, number) {")
    write_line(sb, "            jsc_set_exception_text(ctx, exception, \"unsupported enum backing size\")")
    write_line(sb, "            return false")
    write_line(sb, "        }")
    write_line(sb, "        return true")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Array:")
    write_line(sb, "        obj := jsc.ValueToObject(ctx, value, exception)")
    write_line(sb, "        if jsc_has_exception(exception) || obj == nil {")
    write_line(
        sb,
        "            jsc_set_exception_text(ctx, exception, fmt.aprintf(\"expected JS array for %s\", jsc_type_name(base), allocator = context.temp_allocator))",
    )
    write_line(sb, "            return false")
    write_line(sb, "        }")
    write_line(sb, "        length, ok := jsc_get_array_like_length(ctx, obj, exception)")
    write_line(sb, "        if !ok || length != t.count {")
    write_line(
        sb,
        "            jsc_set_exception_text(ctx, exception, fmt.aprintf(\"expected array length %d\", t.count, allocator = context.temp_allocator))",
    )
    write_line(sb, "            return false")
    write_line(sb, "        }")
    write_line(sb, "        for i := 0; i < t.count; i += 1 {")
    write_line(sb, "            elem := jsc.ObjectGetPropertyAtIndex(ctx, obj, c.uint(i), exception)")
    write_line(sb, "            if jsc_has_exception(exception) {")
    write_line(sb, "                return false")
    write_line(sb, "            }")
    write_line(sb, "            elem_ptr := rawptr(uintptr(out) + uintptr(i*t.elem_size))")
    write_line(sb, "            if !jsc_decode_by_type(ctx, elem, exception, elem_ptr, t.elem) {")
    write_line(sb, "                return false")
    write_line(sb, "            }")
    write_line(sb, "        }")
    write_line(sb, "        return true")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Matrix:")
    write_line(sb, "        obj := jsc.ValueToObject(ctx, value, exception)")
    write_line(sb, "        if jsc_has_exception(exception) || obj == nil {")
    write_line(
        sb,
        "            jsc_set_exception_text(ctx, exception, fmt.aprintf(\"expected JS array for matrix %s\", jsc_type_name(base), allocator = context.temp_allocator))",
    )
    write_line(sb, "            return false")
    write_line(sb, "        }")
    write_line(sb, "        expected := t.row_count * t.column_count")
    write_line(sb, "        length, ok := jsc_get_array_like_length(ctx, obj, exception)")
    write_line(sb, "        if !ok || length != expected {")
    write_line(
        sb,
        "            jsc_set_exception_text(ctx, exception, fmt.aprintf(\"expected matrix array length %d\", expected, allocator = context.temp_allocator))",
    )
    write_line(sb, "            return false")
    write_line(sb, "        }")
    write_line(sb, "        idx := 0")
    write_line(sb, "        for r := 0; r < t.row_count; r += 1 {")
    write_line(sb, "            for cidx := 0; cidx < t.column_count; cidx += 1 {")
    write_line(sb, "                elem := jsc.ObjectGetPropertyAtIndex(ctx, obj, c.uint(idx), exception)")
    write_line(sb, "                if jsc_has_exception(exception) {")
    write_line(sb, "                    return false")
    write_line(sb, "                }")
    write_line(sb, "                storage_idx := 0")
    write_line(sb, "                if t.layout == .Column_Major {")
    write_line(sb, "                    storage_idx = cidx*t.elem_stride + r")
    write_line(sb, "                } else {")
    write_line(sb, "                    storage_idx = r*t.elem_stride + cidx")
    write_line(sb, "                }")
    write_line(sb, "                elem_ptr := rawptr(uintptr(out) + uintptr(storage_idx*t.elem_size))")
    write_line(sb, "                if !jsc_decode_by_type(ctx, elem, exception, elem_ptr, t.elem) {")
    write_line(sb, "                    return false")
    write_line(sb, "                }")
    write_line(sb, "                idx += 1")
    write_line(sb, "            }")
    write_line(sb, "        }")
    write_line(sb, "        return true")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Struct:")
    write_line(sb, "        obj := jsc.ValueToObject(ctx, value, exception)")
    write_line(sb, "        if jsc_has_exception(exception) || obj == nil {")
    write_line(
        sb,
        "            jsc_set_exception_text(ctx, exception, fmt.aprintf(\"expected JS object for struct %s\", jsc_type_name(base), allocator = context.temp_allocator))",
    )
    write_line(sb, "            return false")
    write_line(sb, "        }")
    write_line(sb, "        for i := 0; i < int(t.field_count); i += 1 {")
    write_line(sb, "            field_name := t.names[i]")
    write_line(sb, "            js_name, ok := jsc_make_js_string(field_name)")
    write_line(sb, "            if !ok {")
    write_line(sb, "                jsc_set_exception_text(ctx, exception, \"failed to allocate struct field name\")")
    write_line(sb, "                return false")
    write_line(sb, "            }")
    write_line(sb, "            field_value := jsc.ObjectGetProperty(ctx, obj, js_name, exception)")
    write_line(sb, "            jsc.StringRelease(js_name)")
    write_line(sb, "            if jsc_has_exception(exception) {")
    write_line(sb, "                return false")
    write_line(sb, "            }")
    write_line(sb, "            if jsc.ValueIsUndefined(ctx, field_value) {")
    write_line(
        sb,
        "                jsc_set_exception_text(ctx, exception, fmt.aprintf(\"missing field `%s`\", field_name, allocator = context.temp_allocator))",
    )
    write_line(sb, "                return false")
    write_line(sb, "            }")
    write_line(sb, "            field_ptr := rawptr(uintptr(out) + t.offsets[i])")
    write_line(sb, "            if !jsc_decode_by_type(ctx, field_value, exception, field_ptr, t.types[i]) {")
    write_line(sb, "                return false")
    write_line(sb, "            }")
    write_line(sb, "        }")
    write_line(sb, "        return true")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Pointer:")
    write_line(sb, "        if jsc.ValueIsNull(ctx, value) || jsc.ValueIsUndefined(ctx, value) {")
    write_line(sb, "            (^rawptr)(out)^ = nil")
    write_line(sb, "            return true")
    write_line(sb, "        }")
    write_line(sb, "        class := jsc_get_pointer_class(base)")
    write_line(sb, "        if class == nil {")
    write_line(sb, "            jsc_set_exception_text(ctx, exception, \"failed to create pointer wrapper class\")")
    write_line(sb, "            return false")
    write_line(sb, "        }")
    write_line(sb, "        if !jsc.ValueIsObjectOfClass(ctx, value, class) {")
    write_line(
        sb,
        "            jsc_set_exception_text(ctx, exception, fmt.aprintf(\"expected pointer wrapper object for %s\", jsc_type_name(base), allocator = context.temp_allocator))",
    )
    write_line(sb, "            return false")
    write_line(sb, "        }")
    write_line(sb, "        object := jsc.ValueToObject(ctx, value, exception)")
    write_line(sb, "        if jsc_has_exception(exception) || object == nil {")
    write_line(sb, "            return false")
    write_line(sb, "        }")
    write_line(sb, "        (^rawptr)(out)^ = jsc.ObjectGetPrivate(object)")
    write_line(sb, "        return true")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Slice:")
    write_line(sb, "        if t.elem != nil {")
    write_line(sb, "            core := runtime.type_info_core(t.elem)")
    write_line(sb, "            if core != nil {")
    write_line(sb, "                if int_info, ok := core.variant.(runtime.Type_Info_Integer); ok {")
    write_line(sb, "                    if !int_info.signed && t.elem_size == size_of(u8) {")
    write_line(sb, "                        return jsc_decode_slice_u8(ctx, value, exception, out)")
    write_line(sb, "                    }")
    write_line(sb, "                }")
    write_line(sb, "            }")
    write_line(sb, "        }")
    write_line(sb, "")
    write_line(sb, "        if jsc.ValueIsNull(ctx, value) || jsc.ValueIsUndefined(ctx, value) {")
    write_line(sb, "            (^Raw_Slice_Header)(out)^ = Raw_Slice_Header{}")
    write_line(sb, "            return true")
    write_line(sb, "        }")
    write_line(sb, "")
    write_line(sb, "        obj := jsc.ValueToObject(ctx, value, exception)")
    write_line(sb, "        if jsc_has_exception(exception) || obj == nil {")
    write_line(
        sb,
        "            jsc_set_exception_text(ctx, exception, fmt.aprintf(\"expected JS array for %s\", jsc_type_name(base), allocator = context.temp_allocator))",
    )
    write_line(sb, "            return false")
    write_line(sb, "        }")
    write_line(sb, "")
    write_line(sb, "        count, ok := jsc_get_array_like_length(ctx, obj, exception)")
    write_line(sb, "        if !ok {")
    write_line(sb, "            return false")
    write_line(sb, "        }")
    write_line(sb, "")
    write_line(sb, "        byte_len := count * t.elem_size")
    write_line(sb, "        storage := make([]u8, byte_len, context.temp_allocator)")
    write_line(sb, "        for i := 0; i < count; i += 1 {")
    write_line(sb, "            elem_value := jsc.ObjectGetPropertyAtIndex(ctx, obj, c.uint(i), exception)")
    write_line(sb, "            if jsc_has_exception(exception) {")
    write_line(sb, "                return false")
    write_line(sb, "            }")
    write_line(sb, "            elem_ptr := rawptr(uintptr(raw_data(storage)) + uintptr(i*t.elem_size))")
    write_line(sb, "            if !jsc_decode_by_type(ctx, elem_value, exception, elem_ptr, t.elem) {")
    write_line(sb, "                return false")
    write_line(sb, "            }")
    write_line(sb, "        }")
    write_line(sb, "")
    write_line(sb, "        (^Raw_Slice_Header)(out)^ = Raw_Slice_Header{raw_data(storage), count}")
    write_line(sb, "        return true")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Procedure:")
    write_line(sb, "        jsc_set_exception_text(ctx, exception, \"procedure values are not auto-bindable\")")
    write_line(sb, "        return false")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Map:")
    write_line(sb, "        jsc_set_exception_text(ctx, exception, \"map values are not auto-bindable\")")
    write_line(sb, "        return false")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Union:")
    write_line(sb, "        jsc_set_exception_text(ctx, exception, \"union values are not auto-bindable\")")
    write_line(sb, "        return false")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Named,")
    write_line(sb, "         runtime.Type_Info_Complex,")
    write_line(sb, "         runtime.Type_Info_Quaternion,")
    write_line(sb, "         runtime.Type_Info_Any,")
    write_line(sb, "         runtime.Type_Info_Type_Id,")
    write_line(sb, "         runtime.Type_Info_Multi_Pointer,")
    write_line(sb, "         runtime.Type_Info_Enumerated_Array,")
    write_line(sb, "         runtime.Type_Info_Dynamic_Array,")
    write_line(sb, "         runtime.Type_Info_Parameters,")
    write_line(sb, "         runtime.Type_Info_Bit_Set,")
    write_line(sb, "         runtime.Type_Info_Simd_Vector,")
    write_line(sb, "         runtime.Type_Info_Soa_Pointer,")
    write_line(sb, "         runtime.Type_Info_Bit_Field,")
    write_line(sb, "         runtime.Type_Info_Fixed_Capacity_Dynamic_Array:")
    write_line(
        sb,
        "        jsc_set_exception_text(ctx, exception, fmt.aprintf(\"unsupported decode type: %s\", jsc_type_name(base), allocator = context.temp_allocator))",
    )
    write_line(sb, "        return false")
    write_line(sb, "")
    write_line(sb, "    case:")
    write_line(
        sb,
        "        jsc_set_exception_text(ctx, exception, fmt.aprintf(\"unsupported decode type: %s\", jsc_type_name(base), allocator = context.temp_allocator))",
    )
    write_line(sb, "        return false")
    write_line(sb, "    }")
    write_line(sb, "}")
    write_line(sb)

    write_line(
        sb,
        "jsc_encode_by_type :: proc(ctx: jsc.JSContextRef, value: rawptr, info: ^runtime.Type_Info, exception: ^jsc.JSValueRef) -> jsc.JSValueRef {",
    )
    write_line(sb, "    if info == nil {")
    write_line(sb, "        jsc_set_exception_text(ctx, exception, \"missing type info\")")
    write_line(sb, "        return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "    }")
    write_line(sb, "")
    write_line(sb, "    base := runtime.type_info_base(info)")
    write_line(sb, "    switch t in base.variant {")
    write_line(sb, "    case runtime.Type_Info_Boolean:")
    write_line(sb, "        return jsc.ValueMakeBoolean(ctx, (^bool)(value)^)")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Integer:")
    write_line(sb, "        number, ok := jsc_read_integer(value, t.signed, base.size)")
    write_line(sb, "        if !ok {")
    write_line(sb, "            jsc_set_exception_text(ctx, exception, \"unsupported integer size\")")
    write_line(sb, "            return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "        }")
    write_line(sb, "        return jsc.ValueMakeNumber(ctx, number)")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Rune:")
    write_line(sb, "        return jsc.ValueMakeNumber(ctx, f64((^rune)(value)^))")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Float:")
    write_line(sb, "        switch base.size {")
    write_line(sb, "        case 4: return jsc.ValueMakeNumber(ctx, f64((^f32)(value)^))")
    write_line(sb, "        case 8: return jsc.ValueMakeNumber(ctx, (^f64)(value)^)")
    write_line(sb, "        case:")
    write_line(sb, "            jsc_set_exception_text(ctx, exception, \"unsupported float size\")")
    write_line(sb, "            return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "        }")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_String:")
    write_line(sb, "        if t.is_cstring {")
    write_line(sb, "            ctext := (^cstring)(value)^")
    write_line(sb, "            if ctext == nil {")
    write_line(sb, "                return jsc.ValueMakeNull(ctx)")
    write_line(sb, "            }")
    write_line(sb, "            text := jsc.StringCreateWithUTF8CString(ctext)")
    write_line(sb, "            defer jsc.StringRelease(text)")
    write_line(sb, "            return jsc.ValueMakeString(ctx, text)")
    write_line(sb, "        }")
    write_line(sb, "        return jsc_string_to_value(ctx, (^string)(value)^)")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Enum:")
    write_line(sb, "        core := runtime.type_info_core(base)")
    write_line(sb, "        signed := false")
    write_line(sb, "        if core != nil {")
    write_line(sb, "            if int_info, ok := core.variant.(runtime.Type_Info_Integer); ok {")
    write_line(sb, "                signed = int_info.signed")
    write_line(sb, "            }")
    write_line(sb, "        }")
    write_line(sb, "        number, ok := jsc_read_integer(value, signed, base.size)")
    write_line(sb, "        if !ok {")
    write_line(sb, "            jsc_set_exception_text(ctx, exception, \"unsupported enum backing size\")")
    write_line(sb, "            return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "        }")
    write_line(sb, "        return jsc.ValueMakeNumber(ctx, number)")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Array:")
    write_line(sb, "        arr := jsc.ObjectMakeArray(ctx, c.size_t(t.count), nil, exception)")
    write_line(sb, "        if jsc_has_exception(exception) {")
    write_line(sb, "            return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "        }")
    write_line(sb, "        for i := 0; i < t.count; i += 1 {")
    write_line(sb, "            elem_ptr := rawptr(uintptr(value) + uintptr(i*t.elem_size))")
    write_line(sb, "            elem := jsc_encode_by_type(ctx, elem_ptr, t.elem, exception)")
    write_line(sb, "            if jsc_has_exception(exception) {")
    write_line(sb, "                return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "            }")
    write_line(sb, "            jsc.ObjectSetPropertyAtIndex(ctx, arr, c.uint(i), elem, exception)")
    write_line(sb, "            if jsc_has_exception(exception) {")
    write_line(sb, "                return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "            }")
    write_line(sb, "        }")
    write_line(sb, "        return jsc.JSValueRef(arr)")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Matrix:")
    write_line(sb, "        count := t.row_count * t.column_count")
    write_line(sb, "        arr := jsc.ObjectMakeArray(ctx, c.size_t(count), nil, exception)")
    write_line(sb, "        if jsc_has_exception(exception) {")
    write_line(sb, "            return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "        }")
    write_line(sb, "        idx := 0")
    write_line(sb, "        for r := 0; r < t.row_count; r += 1 {")
    write_line(sb, "            for cidx := 0; cidx < t.column_count; cidx += 1 {")
    write_line(sb, "                storage_idx := 0")
    write_line(sb, "                if t.layout == .Column_Major {")
    write_line(sb, "                    storage_idx = cidx*t.elem_stride + r")
    write_line(sb, "                } else {")
    write_line(sb, "                    storage_idx = r*t.elem_stride + cidx")
    write_line(sb, "                }")
    write_line(sb, "                elem_ptr := rawptr(uintptr(value) + uintptr(storage_idx*t.elem_size))")
    write_line(sb, "                elem := jsc_encode_by_type(ctx, elem_ptr, t.elem, exception)")
    write_line(sb, "                if jsc_has_exception(exception) {")
    write_line(sb, "                    return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "                }")
    write_line(sb, "                jsc.ObjectSetPropertyAtIndex(ctx, arr, c.uint(idx), elem, exception)")
    write_line(sb, "                if jsc_has_exception(exception) {")
    write_line(sb, "                    return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "                }")
    write_line(sb, "                idx += 1")
    write_line(sb, "            }")
    write_line(sb, "        }")
    write_line(sb, "        return jsc.JSValueRef(arr)")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Struct:")
    write_line(sb, "        obj := jsc.ObjectMake(ctx, nil, nil)")
    write_line(sb, "        for i := 0; i < int(t.field_count); i += 1 {")
    write_line(sb, "            field_ptr := rawptr(uintptr(value) + t.offsets[i])")
    write_line(sb, "            field_js := jsc_encode_by_type(ctx, field_ptr, t.types[i], exception)")
    write_line(sb, "            if jsc_has_exception(exception) {")
    write_line(sb, "                return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "            }")
    write_line(sb, "            field_name, ok := jsc_make_js_string(t.names[i])")
    write_line(sb, "            if !ok {")
    write_line(sb, "                jsc_set_exception_text(ctx, exception, \"failed to allocate struct field name\")")
    write_line(sb, "                return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "            }")
    write_line(sb, "            jsc.ObjectSetProperty(ctx, obj, field_name, field_js, {}, exception)")
    write_line(sb, "            jsc.StringRelease(field_name)")
    write_line(sb, "            if jsc_has_exception(exception) {")
    write_line(sb, "                return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "            }")
    write_line(sb, "        }")
    write_line(sb, "        return jsc.JSValueRef(obj)")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Pointer:")
    write_line(sb, "        ptr := (^rawptr)(value)^")
    write_line(sb, "        if ptr == nil {")
    write_line(sb, "            return jsc.ValueMakeNull(ctx)")
    write_line(sb, "        }")
    write_line(sb, "        class := jsc_get_pointer_class(base)")
    write_line(sb, "        if class == nil {")
    write_line(sb, "            jsc_set_exception_text(ctx, exception, \"failed to create pointer wrapper class\")")
    write_line(sb, "            return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "        }")
    write_line(sb, "        obj := jsc.ObjectMake(ctx, class, nil)")
    write_line(sb, "        if obj == nil {")
    write_line(sb, "            jsc_set_exception_text(ctx, exception, \"failed to allocate pointer wrapper\")")
    write_line(sb, "            return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "        }")
    write_line(sb, "        if !jsc.ObjectSetPrivate(obj, ptr) {")
    write_line(
        sb,
        "            jsc_set_exception_text(ctx, exception, \"failed to set pointer wrapper private data\")",
    )
    write_line(sb, "            return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "        }")
    write_line(sb, "        return jsc.JSValueRef(obj)")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Slice:")
    write_line(sb, "        if t.elem != nil {")
    write_line(sb, "            core := runtime.type_info_core(t.elem)")
    write_line(sb, "            if core != nil {")
    write_line(sb, "                if int_info, ok := core.variant.(runtime.Type_Info_Integer); ok {")
    write_line(sb, "                    if !int_info.signed && t.elem_size == size_of(u8) {")
    write_line(sb, "                        return jsc_encode_slice_u8(ctx, value, exception)")
    write_line(sb, "                    }")
    write_line(sb, "                }")
    write_line(sb, "            }")
    write_line(sb, "        }")
    write_line(sb, "")
    write_line(sb, "        header := (^Raw_Slice_Header)(value)^")
    write_line(sb, "        arr := jsc.ObjectMakeArray(ctx, c.size_t(header.len), nil, exception)")
    write_line(sb, "        if jsc_has_exception(exception) {")
    write_line(sb, "            return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "        }")
    write_line(sb, "        for i := 0; i < header.len; i += 1 {")
    write_line(sb, "            elem_ptr := rawptr(uintptr(header.data) + uintptr(i*t.elem_size))")
    write_line(sb, "            elem_js := jsc_encode_by_type(ctx, elem_ptr, t.elem, exception)")
    write_line(sb, "            if jsc_has_exception(exception) {")
    write_line(sb, "                return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "            }")
    write_line(sb, "            jsc.ObjectSetPropertyAtIndex(ctx, arr, c.uint(i), elem_js, exception)")
    write_line(sb, "            if jsc_has_exception(exception) {")
    write_line(sb, "                return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "            }")
    write_line(sb, "        }")
    write_line(sb, "        return jsc.JSValueRef(arr)")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Procedure:")
    write_line(sb, "        jsc_set_exception_text(ctx, exception, \"procedure values are not auto-bindable\")")
    write_line(sb, "        return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Map:")
    write_line(sb, "        jsc_set_exception_text(ctx, exception, \"map values are not auto-bindable\")")
    write_line(sb, "        return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Union:")
    write_line(sb, "        jsc_set_exception_text(ctx, exception, \"union values are not auto-bindable\")")
    write_line(sb, "        return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "")
    write_line(sb, "    case runtime.Type_Info_Named,")
    write_line(sb, "         runtime.Type_Info_Complex,")
    write_line(sb, "         runtime.Type_Info_Quaternion,")
    write_line(sb, "         runtime.Type_Info_Any,")
    write_line(sb, "         runtime.Type_Info_Type_Id,")
    write_line(sb, "         runtime.Type_Info_Multi_Pointer,")
    write_line(sb, "         runtime.Type_Info_Enumerated_Array,")
    write_line(sb, "         runtime.Type_Info_Dynamic_Array,")
    write_line(sb, "         runtime.Type_Info_Parameters,")
    write_line(sb, "         runtime.Type_Info_Bit_Set,")
    write_line(sb, "         runtime.Type_Info_Simd_Vector,")
    write_line(sb, "         runtime.Type_Info_Soa_Pointer,")
    write_line(sb, "         runtime.Type_Info_Bit_Field,")
    write_line(sb, "         runtime.Type_Info_Fixed_Capacity_Dynamic_Array:")
    write_line(
        sb,
        "        jsc_set_exception_text(ctx, exception, fmt.aprintf(\"unsupported encode type: %s\", jsc_type_name(base), allocator = context.temp_allocator))",
    )
    write_line(sb, "        return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "")
    write_line(sb, "    case:")
    write_line(
        sb,
        "        jsc_set_exception_text(ctx, exception, fmt.aprintf(\"unsupported encode type: %s\", jsc_type_name(base), allocator = context.temp_allocator))",
    )
    write_line(sb, "        return jsc.ValueMakeUndefined(ctx)")
    write_line(sb, "    }")
    write_line(sb, "}")
    write_line(sb)

    write_line(
        sb,
        "jsc_decode_value :: proc(ctx: jsc.JSContextRef, value: jsc.JSValueRef, exception: ^jsc.JSValueRef, out: ^$T) -> bool {",
    )
    write_line(sb, "    return jsc_decode_by_type(ctx, value, exception, rawptr(out), type_info_of(T))")
    write_line(sb, "}")
    write_line(sb)

    write_line(
        sb,
        "jsc_encode_value :: proc(ctx: jsc.JSContextRef, value: $T, exception: ^jsc.JSValueRef) -> jsc.JSValueRef {",
    )
    write_line(sb, "    tmp := value")
    write_line(sb, "    return jsc_encode_by_type(ctx, rawptr(&tmp), type_info_of(T), exception)")
    write_line(sb, "}")
    write_line(sb)
}

make_binding_from_template :: proc(
    template: Proc_Template,
    js_name: string,
    wrapper_name: string,
    compile_bindings: map[string]string,
    is_specialization: bool,
) -> Proc_Binding {
    binding := Proc_Binding {
        symbol                = template.symbol,
        js_name               = js_name,
        wrapper_name          = wrapper_name,
        source_name           = template.source_name,
        source_fullpath       = template.source_fullpath,
        source_generated_name = template.source_generated_name,
        source_directives     = template.source_directives,
        params                = template.params,
        results               = template.results,
        call_args             = make([dynamic]string, 0, len(template.params)),
        supported             = true,
        diverging             = template.diverging,
    }

    if template.invalid {
        if binding.supported {
            binding.supported = false
            binding.unsupported_reason = template.invalid_msg
        }
    }

    if template.generic && !is_specialization {
        if binding.supported {
            binding.supported = false
            binding.unsupported_reason = "generic procedure requires `specialize` directive"
        }
    }

    for p, param_idx in binding.params {
        if p.runtime_exposed {
            binding.total_runtime_params += 1
            if !p.has_default {
                binding.required_runtime_params += 1
            }
            if p.unsupported {
                if binding.supported {
                    binding.supported = false
                    binding.unsupported_reason = p.unsupported_msg
                }
            }
            append(&binding.call_args, p.local_name)
            continue
        }

        if p.is_implicit {
            if !p.has_default {
                if binding.supported {
                    binding.supported = false
                    binding.unsupported_reason = fmt.aprintf(
                        "implicit parameter `%s` is missing a default",
                        p.name,
                        allocator = context.allocator,
                    )
                }
            }
            if p.odin_type == "" {
                // DUMBAI: implicit untyped defaults are omitted from call args so callee default executes (#caller_location-safe).
                continue
            }
            append(&binding.call_args, p.local_name)
            continue
        }

        if p.is_comptime {
            if compile_bindings != nil {
                binding_key := p.name
                if strings.has_prefix(binding_key, "$") {
                    binding_key = binding_key[1:]
                }

                if expr, ok := compile_bindings[binding_key]; ok {
                    append(&binding.call_args, expr)
                    continue
                }
                if expr, ok := compile_bindings[p.name]; ok {
                    append(&binding.call_args, expr)
                    continue
                }
                ordinal_key := fmt.aprintf("p%d", param_idx, allocator = context.temp_allocator)
                if expr, ok := compile_bindings[ordinal_key]; ok {
                    append(&binding.call_args, expr)
                    continue
                }
            }

            if p.has_default {
                append(&binding.call_args, p.default_expr)
            } else {
                if binding.supported {
                    binding.supported = false
                    binding.unsupported_reason = fmt.aprintf(
                        "missing specialization for compile-time param `%s`",
                        p.name,
                        allocator = context.allocator,
                    )
                }
                append(&binding.call_args, "---")
            }
            continue
        }

        if p.has_default {
            append(&binding.call_args, p.default_expr)
        } else {
            if binding.supported {
                binding.supported = false
                binding.unsupported_reason = fmt.aprintf(
                    "parameter `%s` is not bindable",
                    p.name,
                    allocator = context.allocator,
                )
            }
            append(&binding.call_args, "---")
        }
    }

    for r in binding.results {
        if r.unsupported {
            if binding.supported {
                binding.supported = false
                binding.unsupported_reason = r.unsupported_msg
            }
        }
    }

    return binding
}

find_template :: proc(templates: []Proc_Template, symbol: string) -> (^Proc_Template, bool) {
    for i := 0; i < len(templates); i += 1 {
        if templates[i].symbol == symbol {
            return &templates[i], true
        }
    }
    return nil, false
}

next_wrapper_name :: proc(used: ^map[string]int, base_symbol: string, suffix: string) -> string {
    base := sanitize_identifier(base_symbol)
    if suffix != "" {
        base = fmt.aprintf("%s_%s", base, sanitize_identifier(suffix), allocator = context.allocator)
    }
    if strings.has_prefix(base, "_") {
        base = fmt.aprintf("sym%s", base, allocator = context.allocator)
    }

    if n, ok := used^[base]; ok {
        used^[base] = n + 1
        return fmt.aprintf("jsc_bind_%s_%d", base, n + 1, allocator = context.allocator)
    }
    used^[base] = 0
    return fmt.aprintf("jsc_bind_%s", base, allocator = context.allocator)
}

build_bindings :: proc(templates: []Proc_Template, spec: Spec_Config) -> []Proc_Binding {
    bindings := make([dynamic]Proc_Binding)
    used_wrapper_names := make(map[string]int)

    // DUMBAI: explicit specializations are emitted first so generic wrappers only appear when intentionally configured.
    for entry, idx in spec.specializes {
        template_ptr, found := find_template(templates, entry.symbol)
        if !found {
            fmt.eprintf("jsc_bindgen: specialize target `%s` (line %d) does not exist\n", entry.symbol, entry.line)
            continue
        }

        template := template_ptr^
        if template.private || template.underscore {
            fmt.eprintf(
                "jsc_bindgen: specialize target `%s` (line %d) is excluded by visibility rules\n",
                entry.symbol,
                entry.line,
            )
            continue
        }

        wrapper_name := next_wrapper_name(
            &used_wrapper_names,
            template.symbol,
            fmt.aprintf("spec_%d", idx, allocator = context.allocator),
        )
        binding := make_binding_from_template(template, entry.js_name, wrapper_name, entry.bindings, true)
        append(&bindings, binding)
    }

    for template in templates {
        if template.private || template.underscore {
            continue
        }
        if spec.excludes[template.symbol] {
            continue
        }

        rename, has_rename := spec.renames[template.symbol]
        js_name := rename if has_rename else template.symbol

        if template.generic {
            // DUMBAI: unspecialized generics stay visible as explicit unsupported wrappers.
            has_specialization := false
            for entry in spec.specializes {
                if entry.symbol == template.symbol {
                    has_specialization = true
                    break
                }
            }
            if has_specialization {
                continue
            }
            wrapper_name := next_wrapper_name(&used_wrapper_names, template.symbol, "generic")
            binding := make_binding_from_template(template, js_name, wrapper_name, nil, false)
            append(&bindings, binding)
            continue
        }

        wrapper_name := next_wrapper_name(&used_wrapper_names, template.symbol, "")
        binding := make_binding_from_template(template, js_name, wrapper_name, nil, false)
        append(&bindings, binding)
    }

    slice.sort_by(bindings[:], proc(lhs, rhs: Proc_Binding) -> bool {
        if lhs.js_name == rhs.js_name {
            return lhs.wrapper_name < rhs.wrapper_name
        }
        return lhs.js_name < rhs.js_name
    })

    return bindings[:]
}

trim_generated_suffix :: proc(generated_name: string) -> string {
    if strings.has_suffix(generated_name, GEN_FILE_SUFFIX) {
        return generated_name[:len(generated_name) - len(GEN_FILE_SUFFIX)]
    }
    if strings.has_suffix(generated_name, ".odin") {
        return generated_name[:len(generated_name) - len(".odin")]
    }
    return generated_name
}

build_generated_file_bindings :: proc(bindings: []Proc_Binding, module_name: string) -> []Generated_File_Bindings {
    files := make([dynamic]Generated_File_Bindings)
    source_to_index := make(map[string]int)
    generated_name_counts := make(map[string]int)

    for binding in bindings {
        idx, exists := source_to_index[binding.source_fullpath]
        if !exists {
            generated_name := binding.source_generated_name
            // DUMBAI: duplicate source basenames are disambiguated deterministically so output filenames stay unique.
            if count, has := generated_name_counts[generated_name]; has {
                next := count + 1
                generated_name_counts[generated_name] = next
                stem := trim_generated_suffix(generated_name)
                generated_name = fmt.aprintf("%s_%d%s", stem, next, GEN_FILE_SUFFIX, allocator = context.allocator)
            } else {
                generated_name_counts[generated_name] = 0
            }

            register_suffix := sanitize_identifier(trim_generated_suffix(generated_name))
            register_name := fmt.aprintf(
                "register_%s_jsc_bindings_%s",
                module_name,
                register_suffix,
                allocator = context.allocator,
            )

            idx = len(files)
            source_to_index[binding.source_fullpath] = idx
            append(
                &files,
                Generated_File_Bindings {
                    source_name = binding.source_name,
                    source_fullpath = binding.source_fullpath,
                    generated_name = generated_name,
                    register_name = register_name,
                    directives = binding.source_directives,
                    bindings = make([dynamic]Proc_Binding),
                },
            )
        }

        append(&files[idx].bindings, binding)
    }

    for i := 0; i < len(files); i += 1 {
        slice.sort_by(files[i].bindings[:], proc(lhs, rhs: Proc_Binding) -> bool {
            if lhs.js_name == rhs.js_name {
                return lhs.wrapper_name < rhs.wrapper_name
            }
            return lhs.js_name < rhs.js_name
        })
    }

    slice.sort_by(files[:], proc(lhs, rhs: Generated_File_Bindings) -> bool {
        if lhs.generated_name == rhs.generated_name {
            return lhs.source_fullpath < rhs.source_fullpath
        }
        return lhs.generated_name < rhs.generated_name
    })

    return files[:]
}

render_register_entries :: proc(sb: ^strings.Builder, bindings: []Proc_Binding, target_object_name: string) {
    // DUMBAI: one JavaScript function is registered per emitted binding wrapper.
    // DUMBAI: generated wrappers call canonical jsc.* procs so vendor/jsc does not require JS-prefixed alias exports.
    // DUMBAI: target_object_name is already the per-library namespace object.
    for info in bindings {
        sym := sanitize_identifier(info.wrapper_name)
        write_line(
            sb,
            fmt.aprintf(
                "    name_%s := jsc.StringCreateWithUTF8CString(%s)",
                sym,
                quote_odin_string(info.js_name),
                allocator = context.allocator,
            ),
        )
        write_line(sb, fmt.aprintf("    defer jsc.StringRelease(name_%s)", sym, allocator = context.allocator))
        write_line(
            sb,
            fmt.aprintf(
                "    fn_%s := jsc.ObjectMakeFunctionWithCallback(ctx, name_%s, %s)",
                sym,
                sym,
                info.wrapper_name,
                allocator = context.allocator,
            ),
        )
        write_line(
            sb,
            fmt.aprintf(
                "    jsc.ObjectSetProperty(ctx, %s, name_%s, jsc.JSValueRef(fn_%s), {{}}, exception)",
                target_object_name,
                sym,
                sym,
                allocator = context.allocator,
            ),
        )
        write_line(sb, "    if jsc_has_exception(exception) do return")
    }
}

render_helpers_output :: proc(
    package_name, jsc_import, register_name, namespace_root, namespace_leaf: string,
) -> string {
    sb := strings.builder_make()

    write_non_web_build_tags(&sb)
    write_line(&sb, "// DUMBAI: generated by jsc_bindgen.odin; do not edit by hand.")
    write_line(&sb, fmt.aprintf("package %s", package_name, allocator = context.allocator))
    write_line(&sb)
    write_line(&sb, "import \"core:c\"")
    write_line(&sb, "import \"core:fmt\"")
    write_line(&sb, "import \"core:strings\"")
    write_line(&sb, "import runtime \"base:runtime\"")
    write_line(&sb, fmt.aprintf("import jsc %s", quote_odin_string(jsc_import), allocator = context.allocator))
    write_line(&sb)
    write_line(&sb, "when #config(JSC_BINDINGS, false) {")
    write_line(
        &sb,
        "    // DUMBAI: compile out generated JSC bindings unless the package explicitly enables JSC_BINDINGS.",
    )
    write_line(&sb)

    write_line(
        &sb,
        "JSC_File_Register_Proc :: #type proc(ctx: jsc.JSContextRef, object: jsc.JSObjectRef, exception: ^jsc.JSValueRef)",
    )
    write_line(&sb, "jsc_bindgen_file_registrars: [dynamic]JSC_File_Register_Proc")
    write_line(&sb)

    write_line(&sb, "jsc_bindgen_register_file :: proc(register_proc: JSC_File_Register_Proc) {")
    write_line(&sb, "    context = runtime.default_context()")
    write_line(
        &sb,
        "    // DUMBAI: file-local generated units self-register at package init so platform build tags stay isolated.",
    )
    write_line(&sb, "    if jsc_bindgen_file_registrars == nil {")
    write_line(&sb, "        jsc_bindgen_file_registrars = make([dynamic]JSC_File_Register_Proc)")
    write_line(&sb, "    }")
    write_line(&sb, "    append(&jsc_bindgen_file_registrars, register_proc)")
    write_line(&sb, "}")
    write_line(&sb)

    render_support_block(&sb)

    strings.write_string(&sb, register_name)
    write_line(&sb, " :: proc(ctx: jsc.JSContextRef, object: jsc.JSObjectRef, exception: ^jsc.JSValueRef) {")
    write_line(&sb, "    context = runtime.default_context()")
    write_line(
        &sb,
        fmt.aprintf(
            "    root_key := jsc.StringCreateWithUTF8CString(%s)",
            quote_odin_string(namespace_root),
            allocator = context.allocator,
        ),
    )
    write_line(&sb, "    defer jsc.StringRelease(root_key)")
    write_line(&sb, "    root_value := jsc.ObjectGetProperty(ctx, object, root_key, exception)")
    write_line(&sb, "    if jsc_has_exception(exception) do return")
    write_line(&sb, "    root_object: jsc.JSObjectRef")
    write_line(&sb, "    if root_value != nil && jsc.ValueIsObject(ctx, root_value) {")
    write_line(&sb, "        root_object = jsc.ValueToObject(ctx, root_value, exception)")
    write_line(&sb, "        if jsc_has_exception(exception) do return")
    write_line(&sb, "    } else {")
    write_line(&sb, "        root_object = jsc.ObjectMake(ctx, nil, nil)")
    write_line(&sb, "        // DUMBAI: publish generated bindings under the configured shared root namespace object.")
    write_line(&sb, "        jsc.ObjectSetProperty(ctx, object, root_key, jsc.JSValueRef(root_object), {}, exception)")
    write_line(&sb, "        if jsc_has_exception(exception) do return")
    write_line(&sb, "    }")
    write_line(
        &sb,
        fmt.aprintf(
            "    namespace_key := jsc.StringCreateWithUTF8CString(%s)",
            quote_odin_string(namespace_leaf),
            allocator = context.allocator,
        ),
    )
    write_line(&sb, "    defer jsc.StringRelease(namespace_key)")
    write_line(&sb, "    namespace_value := jsc.ObjectGetProperty(ctx, root_object, namespace_key, exception)")
    write_line(&sb, "    if jsc_has_exception(exception) do return")
    write_line(&sb, "    namespace_object: jsc.JSObjectRef")
    write_line(&sb, "    if namespace_value != nil && jsc.ValueIsObject(ctx, namespace_value) {")
    write_line(&sb, "        namespace_object = jsc.ValueToObject(ctx, namespace_value, exception)")
    write_line(&sb, "        if jsc_has_exception(exception) do return")
    write_line(&sb, "    } else {")
    write_line(&sb, "        namespace_object = jsc.ObjectMake(ctx, nil, nil)")
    write_line(
        &sb,
        "        jsc.ObjectSetProperty(ctx, root_object, namespace_key, jsc.JSValueRef(namespace_object), {}, exception)",
    )
    write_line(&sb, "        if jsc_has_exception(exception) do return")
    write_line(&sb, "    }")
    write_line(
        &sb,
        "    // DUMBAI: public entrypoint dispatches file-local registrars into the configured per-library JS namespace object.",
    )
    write_line(&sb, "    for register_proc in jsc_bindgen_file_registrars {")
    write_line(&sb, "        register_proc(ctx, namespace_object, exception)")
    write_line(&sb, "        if jsc_has_exception(exception) do return")
    write_line(&sb, "    }")
    write_line(&sb, "}")
    write_line(&sb)
    write_line(&sb, "}")
    write_line(&sb)

    return strings.to_string(sb)
}

render_file_output :: proc(
    package_name, jsc_import: string,
    output: Generated_File_Bindings,
    extra_imports: []Import_Pair,
) -> string {
    sb := strings.builder_make()

    write_non_web_build_tags(&sb)
    for directive in output.directives {
        write_line(&sb, directive)
    }
    write_line(&sb, "// DUMBAI: generated by jsc_bindgen.odin; do not edit by hand.")
    write_line(&sb, fmt.aprintf("package %s", package_name, allocator = context.allocator))
    write_line(&sb)
    write_line(&sb, "import \"core:c\"")
    for imp in extra_imports {
        write_line(
            &sb,
            fmt.aprintf("import %s %s", imp.alias, quote_odin_string(imp.path), allocator = context.allocator),
        )
    }
    write_line(&sb, "import runtime \"base:runtime\"")
    write_line(&sb, fmt.aprintf("import jsc %s", quote_odin_string(jsc_import), allocator = context.allocator))
    write_line(&sb)
    write_line(&sb, "when #config(JSC_BINDINGS, false) {")
    write_line(&sb, "    // DUMBAI: compile out per-file JSC wrapper units unless JSC_BINDINGS is explicitly enabled.")
    write_line(&sb)

    for info in output.bindings {
        if info.supported {
            write_line(
                &sb,
                fmt.aprintf(
                    "// DUMBAI: binds `%s` from %s into JavaScript as `%s`.",
                    info.symbol,
                    info.source_name,
                    info.js_name,
                    allocator = context.allocator,
                ),
            )
        } else {
            write_line(
                &sb,
                fmt.aprintf(
                    "// DUMBAI: fail-fast wrapper for `%s` with explicit bindgen reason.",
                    info.symbol,
                    allocator = context.allocator,
                ),
            )
        }
        render_wrapper(&sb, info)
        write_line(&sb)
    }

    strings.write_string(&sb, output.register_name)
    write_line(&sb, " :: proc(ctx: jsc.JSContextRef, object: jsc.JSObjectRef, exception: ^jsc.JSValueRef) {")
    write_line(&sb, "    context = runtime.default_context()")
    render_register_entries(&sb, output.bindings[:], "object")
    write_line(&sb, "}")
    write_line(&sb)

    init_name := fmt.aprintf(
        "jsc_bindgen_register_file_%s",
        sanitize_identifier(trim_generated_suffix(output.generated_name)),
        allocator = context.allocator,
    )
    write_line(&sb, "@(init)")
    write_line(&sb, fmt.aprintf("%s :: proc \"contextless\" ()", init_name, allocator = context.allocator))
    write_line(&sb, "{")
    write_line(&sb, "    context = runtime.default_context()")
    write_line(&sb, "    // DUMBAI: init hook wires this file's bindings into the shared registration table.")
    write_line(
        &sb,
        fmt.aprintf("    jsc_bindgen_register_file(%s)", output.register_name, allocator = context.allocator),
    )
    write_line(&sb, "}")
    write_line(&sb)
    write_line(&sb, "}")
    write_line(&sb)

    return strings.to_string(sb)
}

write_file_if_changed :: proc(path, content: string) -> (changed: bool, ok: bool) {
    existing, read_err := os.read_entire_file(path, context.temp_allocator)
    if read_err == nil && string(existing) == content {
        return false, true
    }

    if write_err := os.write_entire_file(path, content); write_err != nil {
        fmt.eprintf("jsc_bindgen: failed to write %s: %v\n", path, write_err)
        return false, false
    }

    return true, true
}

count_unsupported :: proc(bindings: []Proc_Binding) -> int {
    unsupported := 0
    for b in bindings {
        if !b.supported {
            unsupported += 1
        }
    }
    return unsupported
}

run :: proc() -> int {
    if len(os.args) != 2 {
        print_usage()
        return 1
    }

    lib_arg := strings.trim_space(os.args[1])
    if lib_arg == "" {
        print_usage()
        return 1
    }

    module_abs, module_name, resolved := resolve_module_path(lib_arg)
    if !resolved {
        return 1
    }

    output_abs, output_ok := join2(module_abs, GEN_FILE_NAME)
    if !output_ok {
        fmt.eprintln("jsc_bindgen: failed to allocate output path")
        return 1
    }
    dts_abs, dts_ok := join2(module_abs, DTS_FILE_NAME)
    if !dts_ok {
        fmt.eprintln("jsc_bindgen: failed to allocate d.ts output path")
        return 1
    }

    spec, spec_ok := parse_spec_file(module_abs)
    if !spec_ok {
        return 1
    }

    // DUMBAI: parse package source directly to avoid external manifests or JSON intermediates.
    pkg, collected := parser.collect_package(module_abs)
    if !collected || pkg == nil {
        fmt.eprintf("jsc_bindgen: failed to collect package files from %s\n", module_abs)
        return 1
    }

    existing_generated_files := make([dynamic]string)
    for fullpath, _ in pkg.files {
        name := filepath.base(fullpath)
        if name == GEN_FILE_NAME || has_generated_file_suffix(name) {
            append(&existing_generated_files, fullpath)
            delete_key(&pkg.files, fullpath)
        }
    }

    if !parser.parse_package(pkg) {
        fmt.eprintf("jsc_bindgen: parse failed for package %s\n", module_abs)
        return 1
    }
    if pkg.name == "" {
        fmt.eprintf("jsc_bindgen: package name could not be detected for %s\n", module_abs)
        return 1
    }

    jsc_root_abs, jsc_root_ok := resolve_generator_jsc_root()
    if !jsc_root_ok {
        return 1
    }

    jsc_import, import_ok := resolve_jsc_import(module_abs, jsc_root_abs)
    if !import_ok {
        return 1
    }

    templates := collect_proc_templates(pkg, output_abs)
    bindings := build_bindings(templates, spec)
    named_defs := collect_named_type_defs(pkg, output_abs, bindings)
    generated_files := build_generated_file_bindings(bindings, module_name)
    import_aliases := collect_import_aliases(pkg, output_abs)
    register_name := fmt.aprintf("register_%s_jsc_bindings", module_name, allocator = context.allocator)
    // DUMBAI: infer hierarchy on the fly from module path instead of requiring a spec-level namespace root setting.
    namespace_root := derive_default_namespace_root(module_abs)
    namespace_leaf := sanitize_identifier(spec.target_import_alias)
    if namespace_leaf == "" {
        namespace_leaf = module_name
    }

    // DUMBAI: helper file carries shared marshaling/runtime support and the public register entrypoint only.
    helper_generated := render_helpers_output(pkg.name, jsc_import, register_name, namespace_root, namespace_leaf)
    // DUMBAI: generate TypeScript declarations against the namespaced JS surface for editor/runtime API hints.
    dts_generated := render_dts_output(namespace_root, namespace_leaf, bindings, named_defs)

    keep_generated_files := make(map[string]bool)
    keep_generated_files[output_abs] = true
    for file in generated_files {
        file_abs, join_ok := join2(module_abs, file.generated_name)
        if !join_ok {
            fmt.eprintln("jsc_bindgen: failed to allocate per-file output path")
            return 1
        }
        keep_generated_files[file_abs] = true
    }

    removed_files := 0
    for fullpath in existing_generated_files {
        if keep_generated_files[fullpath] {
            continue
        }
        if rm_err := os.remove(fullpath); rm_err != nil {
            fmt.eprintf("jsc_bindgen: failed to remove stale generated file %s: %v\n", fullpath, rm_err)
            return 1
        }
        removed_files += 1
        fmt.printf("Removed stale generated file %s\n", fullpath)
    }

    changed_files := 0
    if changed, ok := write_file_if_changed(output_abs, helper_generated); !ok {
        return 1
    } else if changed {
        changed_files += 1
        fmt.printf("Wrote %s\n", output_abs)
    }
    if changed, ok := write_file_if_changed(dts_abs, dts_generated); !ok {
        return 1
    } else if changed {
        changed_files += 1
        fmt.printf("Wrote %s\n", dts_abs)
    }

    for file in generated_files {
        file_abs, join_ok := join2(module_abs, file.generated_name)
        if !join_ok {
            fmt.eprintln("jsc_bindgen: failed to allocate per-file output path")
            return 1
        }

        required_aliases := collect_required_aliases(file.bindings[:])
        extra_imports := resolve_extra_imports(import_aliases, required_aliases)
        rendered := render_file_output(pkg.name, jsc_import, file, extra_imports)
        if changed, ok := write_file_if_changed(file_abs, rendered); !ok {
            return 1
        } else if changed {
            changed_files += 1
            fmt.printf("Wrote %s\n", file_abs)
        }
    }

    if changed_files == 0 && removed_files == 0 {
        fmt.printf(
            "No changes: %s (%d bindings, %d unsupported, %d generated files)\n",
            module_abs,
            len(bindings),
            count_unsupported(bindings),
            len(generated_files) + 2,
        )
        return 0
    }

    fmt.printf(
        "Generated %s (%d bindings, %d unsupported, %d files written, %d stale removed)\n",
        module_abs,
        len(bindings),
        count_unsupported(bindings),
        changed_files,
        removed_files,
    )
    return 0
}

main :: proc() {
    os.exit(run())
}
