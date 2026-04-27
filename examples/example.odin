package jsc

import "core:c"
import "core:fmt"
import "core:os"

add :: proc "c" (
    ctx: JSContextRef,
    function: JSObjectRef,
    thisObject: JSObjectRef,
    argc: c.size_t,
    argv: [^]JSValueRef,
    exception: ^JSValueRef,
) -> JSValueRef {
    if argc < 2 {
        msg := StringCreateWithUTF8CString("add(a, b) expects two arguments")
        exception^ = ValueMakeString(ctx, msg)
        StringRelease(msg)
        return ValueMakeUndefined(ctx)
    }
    a := ValueToNumber(ctx, argv[0], exception)
    if exception^ != nil do return ValueMakeUndefined(ctx)
    b := ValueToNumber(ctx, argv[1], exception)
    if exception^ != nil do return ValueMakeUndefined(ctx)
    return ValueMakeNumber(ctx, a + b)
}

main :: proc() {
    if len(os.args) < 2 {
        fmt.eprintln("Usage: runner <script.js>")
        os.exit(1)
    }

    source, err := os.read_entire_file_from_path(os.args[1], context.allocator)
    if err != os.ERROR_NONE {
        fmt.eprintln("Cannot open file:", os.args[1])
        os.exit(1)
    }
    defer delete(source)

    group := ContextGroupCreate()
    defer ContextGroupRelease(group)

    ctx := GlobalContextCreateInGroup(group, nil)
    defer GlobalContextRelease(ctx)

    jsc_ctx := JSContextRef(ctx)
    global := ContextGetGlobalObject(jsc_ctx)
    add_name := StringCreateWithUTF8CString("add")
    defer StringRelease(add_name)

    add_fn := ObjectMakeFunctionWithCallback(jsc_ctx, add_name, add)
    ObjectSetProperty(jsc_ctx, global, add_name, JSValueRef(add_fn), {}, nil)

    src := StringCreateWithUTF8CString(cstring(raw_data(source)))
    src_url := StringCreateWithUTF8CString(cstring(raw_data(os.args[1])))
    defer StringRelease(src)
    defer StringRelease(src_url)

    exception: JSValueRef
    result := EvaluateScript(jsc_ctx, src, nil, src_url, 1, &exception)

    if exception != nil {
        err_str := ValueToStringCopy(jsc_ctx, exception, nil)
        buf_len := StringGetMaximumUTF8CStringSize(err_str)
        buf := make([]c.char, buf_len)
        StringGetUTF8CString(err_str, raw_data(buf), buf_len)
        fmt.eprintln("Error:", cstring(raw_data(buf)))
        StringRelease(err_str)
        delete(buf)
        os.exit(1)
    }

    if result != nil && !ValueIsUndefined(jsc_ctx, result) && !ValueIsNull(jsc_ctx, result) {
        res_str := ValueToStringCopy(jsc_ctx, result, nil)
        defer StringRelease(res_str)
        buf_len := StringGetMaximumUTF8CStringSize(res_str)
        buf := make([]c.char, buf_len)
        defer delete(buf)
        StringGetUTF8CString(res_str, raw_data(buf), buf_len)
        fmt.println(cstring(raw_data(buf)))
    }
}
