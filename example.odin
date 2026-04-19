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
        msg := JSStringCreateWithUTF8CString("add(a, b) expects two arguments")
        exception^ = JSValueMakeString(ctx, msg)
        JSStringRelease(msg)
        return JSValueMakeUndefined(ctx)
    }
    a := JSValueToNumber(ctx, argv[0], exception)
    if exception^ != nil do return JSValueMakeUndefined(ctx)
    b := JSValueToNumber(ctx, argv[1], exception)
    if exception^ != nil do return JSValueMakeUndefined(ctx)
    return JSValueMakeNumber(ctx, a + b)
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

    group := JSContextGroupCreate()
    defer JSContextGroupRelease(group)

    ctx := JSGlobalContextCreateInGroup(group, nil)
    defer JSGlobalContextRelease(ctx)

    jsc_ctx := JSContextRef(ctx)
    global := JSContextGetGlobalObject(jsc_ctx)
    add_name := JSStringCreateWithUTF8CString("add")
    defer JSStringRelease(add_name)

    add_fn := JSObjectMakeFunctionWithCallback(jsc_ctx, add_name, add)
    JSObjectSetProperty(jsc_ctx, global, add_name, JSValueRef(add_fn), .None, nil)

    src := JSStringCreateWithUTF8CString(cstring(raw_data(source)))
    src_url := JSStringCreateWithUTF8CString(cstring(raw_data(os.args[1])))
    defer JSStringRelease(src)
    defer JSStringRelease(src_url)

    exception: JSValueRef
    result := JSEvaluateScript(jsc_ctx, src, nil, src_url, 1, &exception)

    if exception != nil {
        err_str := JSValueToStringCopy(jsc_ctx, exception, nil)
        buf_len := JSStringGetMaximumUTF8CStringSize(err_str)
        buf := make([]c.char, buf_len)
        JSStringGetUTF8CString(err_str, raw_data(buf), buf_len)
        fmt.eprintln("Error:", cstring(raw_data(buf)))
        JSStringRelease(err_str)
        delete(buf)
        os.exit(1)
    }

    if result != nil && !JSValueIsUndefined(jsc_ctx, result) && !JSValueIsNull(jsc_ctx, result) {
        res_str := JSValueToStringCopy(jsc_ctx, result, nil)
        defer JSStringRelease(res_str)
        buf_len := JSStringGetMaximumUTF8CStringSize(res_str)
        buf := make([]c.char, buf_len)
        defer delete(buf)
        JSStringGetUTF8CString(res_str, raw_data(buf), buf_len)
        fmt.println(cstring(raw_data(buf)))
    }
}
