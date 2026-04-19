package jsc

import "core:c"

// ── Opaque handle types ────────────────────────────────────────────────────

JSContextGroupRef :: distinct rawptr
JSGlobalContextRef :: distinct rawptr
JSContextRef :: distinct rawptr
JSObjectRef :: distinct rawptr
JSValueRef :: distinct rawptr
JSStringRef :: distinct rawptr

// ── Enums / flags ──────────────────────────────────────────────────────────

JSPropertyAttributes :: enum c.uint {
    None       = 0,
    ReadOnly   = 1 << 1,
    DontEnum   = 1 << 2,
    DontDelete = 1 << 3,
}

// ── Callbacks ──────────────────────────────────────────────────────────────

// Signature for a native function exposed to JS (what "Add" was in the C example)
JSObjectCallAsFunctionCallback :: #type proc "c" (
    ctx: JSContextRef,
    function: JSObjectRef,
    thisObject: JSObjectRef,
    argc: c.size_t,
    argv: [^]JSValueRef,
    exception: ^JSValueRef,
) -> JSValueRef

// ── Foreign block ──────────────────────────────────────────────────────────

when ODIN_OS == .Darwin {
    foreign import jsc "system:JavaScriptCore.framework"
} else {
    foreign import jsc "system:javascriptcoregtk-4.1"
}

@(default_calling_convention = "c")
foreign jsc {

    // Context group (~ Isolate)
    JSContextGroupCreate :: proc() -> JSContextGroupRef ---
    JSContextGroupRelease :: proc(group: JSContextGroupRef) ---

    // Global context (~ Context)
    JSGlobalContextCreateInGroup :: proc(group: JSContextGroupRef,
        globalClass: rawptr, ) -> JSGlobalContextRef ---// JSClassRef, pass nil for default
    JSGlobalContextRelease :: proc(ctx: JSGlobalContextRef) ---

    // Get the global object from a context
    JSContextGetGlobalObject :: proc(ctx: JSContextRef) -> JSObjectRef ---

    // String create / release / convert
    JSStringCreateWithUTF8CString :: proc(str: cstring) -> JSStringRef ---
    JSStringRelease :: proc(str: JSStringRef) ---
    JSStringGetMaximumUTF8CStringSize :: proc(str: JSStringRef) -> c.size_t ---
    JSStringGetUTF8CString :: proc(str: JSStringRef, buf: [^]c.char, bufSize: c.size_t) -> c.size_t ---

    // Value checks
    JSValueIsUndefined :: proc(ctx: JSContextRef, value: JSValueRef) -> bool ---
    JSValueIsNull :: proc(ctx: JSContextRef, value: JSValueRef) -> bool ---

    // Value constructors
    JSValueMakeUndefined :: proc(ctx: JSContextRef) -> JSValueRef ---
    JSValueMakeNumber :: proc(ctx: JSContextRef, number: f64) -> JSValueRef ---
    JSValueMakeString :: proc(ctx: JSContextRef, str: JSStringRef) -> JSValueRef ---

    // Value conversions
    JSValueToNumber :: proc(ctx: JSContextRef, value: JSValueRef, exception: ^JSValueRef) -> f64 ---
    JSValueToStringCopy :: proc(ctx: JSContextRef, value: JSValueRef, exception: ^JSValueRef) -> JSStringRef ---

    // Object: make a native function and register it
    JSObjectMakeFunctionWithCallback :: proc(ctx: JSContextRef, name: JSStringRef, callback: JSObjectCallAsFunctionCallback) -> JSObjectRef ---
    JSObjectSetProperty :: proc(ctx: JSContextRef, object: JSObjectRef, propertyName: JSStringRef, value: JSValueRef, attributes: JSPropertyAttributes, exception: ^JSValueRef) ---

    // Evaluate a script string
    JSEvaluateScript :: proc(ctx: JSContextRef,
        script: JSStringRef,
        thisObject: JSObjectRef, // nil → global
        sourceURL: JSStringRef, // nil → no source URL
        startingLineNumber: c.int,
        exception: ^JSValueRef,) -> JSValueRef ---
}
