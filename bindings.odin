package jsc

import "core:c"

// DUMBAI: Mirror all JavaScriptCore C refs as opaque handles for ABI parity.
JSContextGroupRef :: distinct rawptr
JSContextRef :: distinct rawptr
JSGlobalContextRef :: distinct rawptr
JSStringRef :: distinct rawptr
JSClassRef :: distinct rawptr
JSPropertyNameArrayRef :: distinct rawptr
JSPropertyNameAccumulatorRef :: distinct rawptr
JSValueRef :: distinct rawptr
JSObjectRef :: distinct rawptr
JSScriptRef :: distinct rawptr
JSWeakRef :: distinct rawptr
JSWeakObjectMapRef :: distinct rawptr

// DUMBAI: JSChar is UTF-16 code unit in all JS C APIs.
JSChar :: u16

// DUMBAI: Keep platform bridge opaque aliases available for parity APIs.
when ODIN_OS == .Windows {
    BSTR :: distinct rawptr
}
when ODIN_OS == .Darwin {
    CFAllocatorRef :: distinct rawptr
    CFStringRef :: distinct rawptr
}

// DUMBAI: Flag bit positions for JSObjectRef attribute masks.
JSPropertyAttribute :: enum c.uint {
    ReadOnly,
    DontEnum,
    DontDelete,
}
JSPropertyAttributes :: distinct bit_set[JSPropertyAttribute;c.uint]

// DUMBAI: Legacy wrappers keep a separate bit_set type but share ordinal flags with the canonical attribute mask.
JSPropertyAttributeLegacy :: enum c.uint {
    ReadOnly,
    DontEnum,
    DontDelete,
}
JSPropertyAttributesLegacy :: distinct bit_set[JSPropertyAttributeLegacy;c.uint]

// DUMBAI: Flag bit positions for JSClassDefinition attribute masks.
JSClassAttribute :: enum c.uint {
    NoAutomaticPrototype,
}
JSClassAttributes :: distinct bit_set[JSClassAttribute;c.uint]

JSType :: enum c.int {
    Undefined,
    Null,
    Boolean,
    Number,
    String,
    Object,
    Symbol,
    BigInt,
}

JSTypedArrayType :: enum c.int {
    Int8Array,
    Int16Array,
    Int32Array,
    Uint8Array,
    Uint8ClampedArray,
    Uint16Array,
    Uint32Array,
    Float32Array,
    Float64Array,
    ArrayBuffer,
    None,
    BigInt64Array,
    BigUint64Array,
}

JSRelationCondition :: enum c.uint {
    Undefined,
    Equal,
    GreaterThan,
    LessThan,
}

// DUMBAI: JS marker vtable structure is used by marking-constraint private APIs.
JSMarker :: struct {
    IsMarked: proc "c" (marker: ^JSMarker, object: JSObjectRef) -> bool,
    Mark:     proc "c" (marker: ^JSMarker, object: JSObjectRef),
}
JSMarkerRef :: ^JSMarker

// DUMBAI: Callback typedefs mapped 1:1 with header signatures.
JSTypedArrayBytesDeallocator :: #type proc "c" (bytes: rawptr, deallocatorContext: rawptr)

JSObjectInitializeCallback :: #type proc "c" (ctx: JSContextRef, object: JSObjectRef)
JSObjectFinalizeCallback :: #type proc "c" (object: JSObjectRef)
JSObjectHasPropertyCallback :: #type proc "c" (
    ctx: JSContextRef,
    object: JSObjectRef,
    propertyName: JSStringRef,
) -> bool
JSObjectGetPropertyCallback :: #type proc "c" (
    ctx: JSContextRef,
    object: JSObjectRef,
    propertyName: JSStringRef,
    exception: ^JSValueRef,
) -> JSValueRef
JSObjectSetPropertyCallback :: #type proc "c" (
    ctx: JSContextRef,
    object: JSObjectRef,
    propertyName: JSStringRef,
    value: JSValueRef,
    exception: ^JSValueRef,
) -> bool
JSObjectDeletePropertyCallback :: #type proc "c" (
    ctx: JSContextRef,
    object: JSObjectRef,
    propertyName: JSStringRef,
    exception: ^JSValueRef,
) -> bool
JSObjectGetPropertyNamesCallback :: #type proc "c" (
    ctx: JSContextRef,
    object: JSObjectRef,
    propertyNames: JSPropertyNameAccumulatorRef,
)
JSObjectCallAsFunctionCallback :: #type proc "c" (
    ctx: JSContextRef,
    function: JSObjectRef,
    thisObject: JSObjectRef,
    argumentCount: c.size_t,
    arguments: [^]JSValueRef,
    exception: ^JSValueRef,
) -> JSValueRef
JSObjectCallAsConstructorCallback :: #type proc "c" (
    ctx: JSContextRef,
    constructor: JSObjectRef,
    argumentCount: c.size_t,
    arguments: [^]JSValueRef,
    exception: ^JSValueRef,
) -> JSObjectRef
JSObjectHasInstanceCallback :: #type proc "c" (
    ctx: JSContextRef,
    constructor: JSObjectRef,
    possibleInstance: JSValueRef,
    exception: ^JSValueRef,
) -> bool
JSObjectConvertToTypeCallback :: #type proc "c" (
    ctx: JSContextRef,
    object: JSObjectRef,
    valueType: JSType,
    exception: ^JSValueRef,
) -> JSValueRef

JSShouldTerminateCallback :: #type proc "c" (ctx: JSContextRef, userContext: rawptr) -> bool
JSWeakMapDestroyedCallback :: #type proc "c" (weakMap: JSWeakObjectMapRef, data: rawptr)
JSHeapFinalizer :: #type proc "c" (group: JSContextGroupRef, userData: rawptr)
JSMarkingConstraint :: #type proc "c" (marker: JSMarkerRef, userData: rawptr)

// DUMBAI: Mirror static descriptor structs so custom classes can be built from Odin.
JSStaticValue :: struct {
    name:        cstring,
    getProperty: JSObjectGetPropertyCallback,
    setProperty: JSObjectSetPropertyCallback,
    attributes:  JSPropertyAttributes,
}

JSStaticFunction :: struct {
    name:           cstring,
    callAsFunction: JSObjectCallAsFunctionCallback,
    attributes:     JSPropertyAttributes,
}

JSClassDefinition :: struct {
    version:           c.int,
    attributes:        JSClassAttributes,
    className:         cstring,
    parentClass:       JSClassRef,
    staticValues:      ^JSStaticValue,
    staticFunctions:   ^JSStaticFunction,
    initialize:        JSObjectInitializeCallback,
    finalize:          JSObjectFinalizeCallback,
    hasProperty:       JSObjectHasPropertyCallback,
    getProperty:       JSObjectGetPropertyCallback,
    setProperty:       JSObjectSetPropertyCallback,
    deleteProperty:    JSObjectDeletePropertyCallback,
    getPropertyNames:  JSObjectGetPropertyNamesCallback,
    callAsFunction:    JSObjectCallAsFunctionCallback,
    callAsConstructor: JSObjectCallAsConstructorCallback,
    hasInstance:       JSObjectHasInstanceCallback,
    convertToType:     JSObjectConvertToTypeCallback,
}

// DUMBAI: Match platform import names so same Odin package works on Apple/Windows/Gtk.
when ODIN_OS == .Darwin {
    foreign import jsc "system:JavaScriptCore.framework"
} else when ODIN_OS == .Windows {
    foreign import jsc "system:JavaScriptCore"
} else {
    foreign import jsc "system:javascriptcoregtk-4.1"
}

@(default_calling_convention = "c", link_prefix = "JS")
// DUMBAI: Bindings package exports only canonical JavaScriptCore proc names from this foreign block.
foreign jsc {
    // DUMBAI: JSBase.h
    EvaluateScript :: proc(ctx: JSContextRef, script: JSStringRef, thisObject: JSObjectRef, sourceURL: JSStringRef, startingLineNumber: c.int, exception: ^JSValueRef) -> JSValueRef ---
    CheckScriptSyntax :: proc(ctx: JSContextRef, script: JSStringRef, sourceURL: JSStringRef, startingLineNumber: c.int, exception: ^JSValueRef) -> bool ---
    GarbageCollect :: proc(ctx: JSContextRef) ---

    // DUMBAI: JSContextRef.h
    ContextGroupCreate :: proc() -> JSContextGroupRef ---
    ContextGroupRetain :: proc(group: JSContextGroupRef) -> JSContextGroupRef ---
    ContextGroupRelease :: proc(group: JSContextGroupRef) ---
    GlobalContextCreate :: proc(globalObjectClass: JSClassRef) -> JSGlobalContextRef ---
    GlobalContextCreateInGroup :: proc(group: JSContextGroupRef, globalObjectClass: JSClassRef) -> JSGlobalContextRef ---
    GlobalContextRetain :: proc(ctx: JSGlobalContextRef) -> JSGlobalContextRef ---
    GlobalContextRelease :: proc(ctx: JSGlobalContextRef) ---
    ContextGetGlobalObject :: proc(ctx: JSContextRef) -> JSObjectRef ---
    ContextGetGroup :: proc(ctx: JSContextRef) -> JSContextGroupRef ---
    ContextGetGlobalContext :: proc(ctx: JSContextRef) -> JSGlobalContextRef ---
    GlobalContextCopyName :: proc(ctx: JSGlobalContextRef) -> JSStringRef ---
    GlobalContextSetName :: proc(ctx: JSGlobalContextRef, name: JSStringRef) ---
    GlobalContextIsInspectable :: proc(ctx: JSGlobalContextRef) -> bool ---
    GlobalContextSetInspectable :: proc(ctx: JSGlobalContextRef, inspectable: bool) ---

    // DUMBAI: JSStringRef.h + JSStringRefPrivate.h
    StringCreateWithCharacters :: proc(chars: ^JSChar, numChars: c.size_t) -> JSStringRef ---
    StringCreateWithUTF8CString :: proc(string: cstring) -> JSStringRef ---
    StringRetain :: proc(string: JSStringRef) -> JSStringRef ---
    StringRelease :: proc(string: JSStringRef) ---
    StringGetLength :: proc(string: JSStringRef) -> c.size_t ---
    StringGetCharactersPtr :: proc(string: JSStringRef) -> ^JSChar ---
    StringGetMaximumUTF8CStringSize :: proc(string: JSStringRef) -> c.size_t ---
    StringGetUTF8CString :: proc(string: JSStringRef, buffer: [^]c.char, bufferSize: c.size_t) -> c.size_t ---
    StringIsEqual :: proc(a: JSStringRef, b: JSStringRef) -> bool ---
    StringIsEqualToUTF8CString :: proc(a: JSStringRef, b: cstring) -> bool ---
    StringCreateWithCharactersNoCopy :: proc(chars: ^JSChar, numChars: c.size_t) -> JSStringRef ---

    when ODIN_OS == .Windows {
        // DUMBAI: JSStringRefBSTR.h helpers for Windows COM interop.
        StringCreateWithBSTR :: proc(string: BSTR) -> JSStringRef ---
        StringCopyBSTR :: proc(string: JSStringRef) -> BSTR ---
    }

    when ODIN_OS == .Darwin {
        // DUMBAI: JSStringRefCF.h helpers for CoreFoundation interop.
        StringCreateWithCFString :: proc(string: CFStringRef) -> JSStringRef ---
        StringCopyCFString :: proc(alloc: CFAllocatorRef, string: JSStringRef) -> CFStringRef ---
    }

    // DUMBAI: JSObjectRef.h
    @(link_name = "kJSClassDefinitionEmpty")
    kJSClassDefinitionEmpty: JSClassDefinition
    ClassCreate :: proc(definition: ^JSClassDefinition) -> JSClassRef ---
    ClassRetain :: proc(jsClass: JSClassRef) -> JSClassRef ---
    ClassRelease :: proc(jsClass: JSClassRef) ---

    ObjectMake :: proc(ctx: JSContextRef, jsClass: JSClassRef, data: rawptr) -> JSObjectRef ---
    ObjectMakeFunctionWithCallback :: proc(ctx: JSContextRef, name: JSStringRef, callAsFunction: JSObjectCallAsFunctionCallback) -> JSObjectRef ---
    ObjectMakeConstructor :: proc(ctx: JSContextRef, jsClass: JSClassRef, callAsConstructor: JSObjectCallAsConstructorCallback) -> JSObjectRef ---
    ObjectMakeArray :: proc(ctx: JSContextRef, argumentCount: c.size_t, arguments: [^]JSValueRef, exception: ^JSValueRef) -> JSObjectRef ---
    ObjectMakeDate :: proc(ctx: JSContextRef, argumentCount: c.size_t, arguments: [^]JSValueRef, exception: ^JSValueRef) -> JSObjectRef ---
    ObjectMakeError :: proc(ctx: JSContextRef, argumentCount: c.size_t, arguments: [^]JSValueRef, exception: ^JSValueRef) -> JSObjectRef ---
    ObjectMakeRegExp :: proc(ctx: JSContextRef, argumentCount: c.size_t, arguments: [^]JSValueRef, exception: ^JSValueRef) -> JSObjectRef ---
    ObjectMakeDeferredPromise :: proc(ctx: JSContextRef, resolve: ^JSObjectRef, reject: ^JSObjectRef, exception: ^JSValueRef) -> JSObjectRef ---
    ObjectMakeFunction :: proc(ctx: JSContextRef, name: JSStringRef, parameterCount: c.uint, parameterNames: [^]JSStringRef, body: JSStringRef, sourceURL: JSStringRef, startingLineNumber: c.int, exception: ^JSValueRef) -> JSObjectRef ---
    ObjectGetPrototype :: proc(ctx: JSContextRef, object: JSObjectRef) -> JSValueRef ---
    ObjectSetPrototype :: proc(ctx: JSContextRef, object: JSObjectRef, value: JSValueRef) ---
    ObjectHasProperty :: proc(ctx: JSContextRef, object: JSObjectRef, propertyName: JSStringRef) -> bool ---
    ObjectGetProperty :: proc(ctx: JSContextRef, object: JSObjectRef, propertyName: JSStringRef, exception: ^JSValueRef) -> JSValueRef ---
    ObjectSetProperty :: proc(ctx: JSContextRef, object: JSObjectRef, propertyName: JSStringRef, value: JSValueRef, attributes: JSPropertyAttributes, exception: ^JSValueRef) ---
    ObjectDeleteProperty :: proc(ctx: JSContextRef, object: JSObjectRef, propertyName: JSStringRef, exception: ^JSValueRef) -> bool ---
    ObjectHasPropertyForKey :: proc(ctx: JSContextRef, object: JSObjectRef, propertyKey: JSValueRef, exception: ^JSValueRef) -> bool ---
    ObjectGetPropertyForKey :: proc(ctx: JSContextRef, object: JSObjectRef, propertyKey: JSValueRef, exception: ^JSValueRef) -> JSValueRef ---
    ObjectSetPropertyForKey :: proc(ctx: JSContextRef, object: JSObjectRef, propertyKey: JSValueRef, value: JSValueRef, attributes: JSPropertyAttributes, exception: ^JSValueRef) ---
    ObjectDeletePropertyForKey :: proc(ctx: JSContextRef, object: JSObjectRef, propertyKey: JSValueRef, exception: ^JSValueRef) -> bool ---
    ObjectGetPropertyAtIndex :: proc(ctx: JSContextRef, object: JSObjectRef, propertyIndex: c.uint, exception: ^JSValueRef) -> JSValueRef ---
    ObjectSetPropertyAtIndex :: proc(ctx: JSContextRef, object: JSObjectRef, propertyIndex: c.uint, value: JSValueRef, exception: ^JSValueRef) ---
    ObjectGetPrivate :: proc(object: JSObjectRef) -> rawptr ---
    ObjectSetPrivate :: proc(object: JSObjectRef, data: rawptr) -> bool ---
    ObjectIsFunction :: proc(ctx: JSContextRef, object: JSObjectRef) -> bool ---
    ObjectCallAsFunction :: proc(ctx: JSContextRef, object: JSObjectRef, thisObject: JSObjectRef, argumentCount: c.size_t, arguments: [^]JSValueRef, exception: ^JSValueRef) -> JSValueRef ---
    ObjectIsConstructor :: proc(ctx: JSContextRef, object: JSObjectRef) -> bool ---
    ObjectCallAsConstructor :: proc(ctx: JSContextRef, object: JSObjectRef, argumentCount: c.size_t, arguments: [^]JSValueRef, exception: ^JSValueRef) -> JSObjectRef ---
    ObjectCopyPropertyNames :: proc(ctx: JSContextRef, object: JSObjectRef) -> JSPropertyNameArrayRef ---
    PropertyNameArrayRetain :: proc(array: JSPropertyNameArrayRef) -> JSPropertyNameArrayRef ---
    PropertyNameArrayRelease :: proc(array: JSPropertyNameArrayRef) ---
    PropertyNameArrayGetCount :: proc(array: JSPropertyNameArrayRef) -> c.size_t ---
    PropertyNameArrayGetNameAtIndex :: proc(array: JSPropertyNameArrayRef, index: c.size_t) -> JSStringRef ---
    PropertyNameAccumulatorAddName :: proc(accumulator: JSPropertyNameAccumulatorRef, propertyName: JSStringRef) ---

    // DUMBAI: JSTypedArray.h
    ObjectMakeTypedArray :: proc(ctx: JSContextRef, arrayType: JSTypedArrayType, length: c.size_t, exception: ^JSValueRef) -> JSObjectRef ---
    ObjectMakeTypedArrayWithBytesNoCopy :: proc(ctx: JSContextRef, arrayType: JSTypedArrayType, bytes: rawptr, byteLength: c.size_t, bytesDeallocator: JSTypedArrayBytesDeallocator, deallocatorContext: rawptr, exception: ^JSValueRef) -> JSObjectRef ---
    ObjectMakeTypedArrayWithArrayBuffer :: proc(ctx: JSContextRef, arrayType: JSTypedArrayType, buffer: JSObjectRef, exception: ^JSValueRef) -> JSObjectRef ---
    ObjectMakeTypedArrayWithArrayBufferAndOffset :: proc(ctx: JSContextRef, arrayType: JSTypedArrayType, buffer: JSObjectRef, byteOffset: c.size_t, length: c.size_t, exception: ^JSValueRef) -> JSObjectRef ---
    ObjectGetTypedArrayBytesPtr :: proc(ctx: JSContextRef, object: JSObjectRef, exception: ^JSValueRef) -> rawptr ---
    ObjectGetTypedArrayLength :: proc(ctx: JSContextRef, object: JSObjectRef, exception: ^JSValueRef) -> c.size_t ---
    ObjectGetTypedArrayByteLength :: proc(ctx: JSContextRef, object: JSObjectRef, exception: ^JSValueRef) -> c.size_t ---
    ObjectGetTypedArrayByteOffset :: proc(ctx: JSContextRef, object: JSObjectRef, exception: ^JSValueRef) -> c.size_t ---
    ObjectGetTypedArrayBuffer :: proc(ctx: JSContextRef, object: JSObjectRef, exception: ^JSValueRef) -> JSObjectRef ---
    ObjectMakeArrayBufferWithBytesNoCopy :: proc(ctx: JSContextRef, bytes: rawptr, byteLength: c.size_t, bytesDeallocator: JSTypedArrayBytesDeallocator, deallocatorContext: rawptr, exception: ^JSValueRef) -> JSObjectRef ---
    ObjectGetArrayBufferBytesPtr :: proc(ctx: JSContextRef, object: JSObjectRef, exception: ^JSValueRef) -> rawptr ---
    ObjectGetArrayBufferByteLength :: proc(ctx: JSContextRef, object: JSObjectRef, exception: ^JSValueRef) -> c.size_t ---

    // DUMBAI: JSValueRef.h
    ValueGetType :: proc(ctx: JSContextRef, value: JSValueRef) -> JSType ---
    ValueIsUndefined :: proc(ctx: JSContextRef, value: JSValueRef) -> bool ---
    ValueIsNull :: proc(ctx: JSContextRef, value: JSValueRef) -> bool ---
    ValueIsBoolean :: proc(ctx: JSContextRef, value: JSValueRef) -> bool ---
    ValueIsNumber :: proc(ctx: JSContextRef, value: JSValueRef) -> bool ---
    ValueIsString :: proc(ctx: JSContextRef, value: JSValueRef) -> bool ---
    ValueIsSymbol :: proc(ctx: JSContextRef, value: JSValueRef) -> bool ---
    ValueIsBigInt :: proc(ctx: JSContextRef, value: JSValueRef) -> bool ---
    ValueIsObject :: proc(ctx: JSContextRef, value: JSValueRef) -> bool ---
    ValueIsObjectOfClass :: proc(ctx: JSContextRef, value: JSValueRef, jsClass: JSClassRef) -> bool ---
    ValueIsArray :: proc(ctx: JSContextRef, value: JSValueRef) -> bool ---
    ValueIsDate :: proc(ctx: JSContextRef, value: JSValueRef) -> bool ---
    ValueGetTypedArrayType :: proc(ctx: JSContextRef, value: JSValueRef, exception: ^JSValueRef) -> JSTypedArrayType ---
    ValueIsEqual :: proc(ctx: JSContextRef, a: JSValueRef, b: JSValueRef, exception: ^JSValueRef) -> bool ---
    ValueIsStrictEqual :: proc(ctx: JSContextRef, a: JSValueRef, b: JSValueRef) -> bool ---
    ValueIsInstanceOfConstructor :: proc(ctx: JSContextRef, value: JSValueRef, constructor: JSObjectRef, exception: ^JSValueRef) -> bool ---
    ValueCompare :: proc(ctx: JSContextRef, left: JSValueRef, right: JSValueRef, exception: ^JSValueRef) -> JSRelationCondition ---
    ValueCompareInt64 :: proc(ctx: JSContextRef, left: JSValueRef, right: i64, exception: ^JSValueRef) -> JSRelationCondition ---
    ValueCompareUInt64 :: proc(ctx: JSContextRef, left: JSValueRef, right: u64, exception: ^JSValueRef) -> JSRelationCondition ---
    ValueCompareDouble :: proc(ctx: JSContextRef, left: JSValueRef, right: f64, exception: ^JSValueRef) -> JSRelationCondition ---
    ValueMakeUndefined :: proc(ctx: JSContextRef) -> JSValueRef ---
    ValueMakeNull :: proc(ctx: JSContextRef) -> JSValueRef ---
    ValueMakeBoolean :: proc(ctx: JSContextRef, boolean: bool) -> JSValueRef ---
    ValueMakeNumber :: proc(ctx: JSContextRef, number: f64) -> JSValueRef ---
    ValueMakeString :: proc(ctx: JSContextRef, string: JSStringRef) -> JSValueRef ---
    ValueMakeSymbol :: proc(ctx: JSContextRef, description: JSStringRef) -> JSValueRef ---
    BigIntCreateWithDouble :: proc(ctx: JSContextRef, value: f64, exception: ^JSValueRef) -> JSValueRef ---
    BigIntCreateWithInt64 :: proc(ctx: JSContextRef, integer: i64, exception: ^JSValueRef) -> JSValueRef ---
    BigIntCreateWithUInt64 :: proc(ctx: JSContextRef, integer: u64, exception: ^JSValueRef) -> JSValueRef ---
    BigIntCreateWithString :: proc(ctx: JSContextRef, string: JSStringRef, exception: ^JSValueRef) -> JSValueRef ---
    ValueMakeFromJSONString :: proc(ctx: JSContextRef, string: JSStringRef) -> JSValueRef ---
    ValueCreateJSONString :: proc(ctx: JSContextRef, value: JSValueRef, indent: c.uint, exception: ^JSValueRef) -> JSStringRef ---
    ValueToBoolean :: proc(ctx: JSContextRef, value: JSValueRef) -> bool ---
    ValueToNumber :: proc(ctx: JSContextRef, value: JSValueRef, exception: ^JSValueRef) -> f64 ---
    ValueToInt32 :: proc(ctx: JSContextRef, value: JSValueRef, exception: ^JSValueRef) -> i32 ---
    ValueToUInt32 :: proc(ctx: JSContextRef, value: JSValueRef, exception: ^JSValueRef) -> u32 ---
    ValueToInt64 :: proc(ctx: JSContextRef, value: JSValueRef, exception: ^JSValueRef) -> i64 ---
    ValueToUInt64 :: proc(ctx: JSContextRef, value: JSValueRef, exception: ^JSValueRef) -> u64 ---
    ValueToStringCopy :: proc(ctx: JSContextRef, value: JSValueRef, exception: ^JSValueRef) -> JSStringRef ---
    ValueToObject :: proc(ctx: JSContextRef, value: JSValueRef, exception: ^JSValueRef) -> JSObjectRef ---
    ValueProtect :: proc(ctx: JSContextRef, value: JSValueRef) ---
    ValueUnprotect :: proc(ctx: JSContextRef, value: JSValueRef) ---

    // DUMBAI: JSBasePrivate.h
    ReportExtraMemoryCost :: proc(ctx: JSContextRef, size: c.size_t) ---
    DisableGCTimer :: proc() ---
    when ODIN_OS != .Darwin && ODIN_OS != .Windows {
        ConfigureSignalForGC :: proc(signal: c.int) -> bool ---
    }
    GetMemoryUsageStatistics :: proc(ctx: JSContextRef) -> JSObjectRef ---

    // DUMBAI: JSContextRefPrivate.h
    ContextCreateBacktrace :: proc(ctx: JSContextRef, maxStackSize: c.uint) -> JSStringRef ---
    ContextGroupSetExecutionTimeLimit :: proc(group: JSContextGroupRef, limit: f64, callback: JSShouldTerminateCallback, userContext: rawptr) ---
    ContextGroupClearExecutionTimeLimit :: proc(group: JSContextGroupRef) ---
    ContextGroupEnableSamplingProfiler :: proc(group: JSContextGroupRef) -> bool ---
    ContextGroupDisableSamplingProfiler :: proc(group: JSContextGroupRef) ---
    ContextGroupTakeSamplesFromSamplingProfiler :: proc(group: JSContextGroupRef) -> JSStringRef ---
    GlobalContextGetRemoteInspectionEnabled :: proc(ctx: JSGlobalContextRef) -> bool ---
    GlobalContextSetRemoteInspectionEnabled :: proc(ctx: JSGlobalContextRef, enabled: bool) ---
    GlobalContextGetIncludesNativeCallStackWhenReportingExceptions :: proc(ctx: JSGlobalContextRef) -> bool ---
    GlobalContextSetIncludesNativeCallStackWhenReportingExceptions :: proc(ctx: JSGlobalContextRef, includesNativeCallStack: bool) ---
    GlobalContextSetUnhandledRejectionCallback :: proc(ctx: JSGlobalContextRef, function: JSObjectRef, exception: ^JSValueRef) ---
    GlobalContextSetEvalEnabled :: proc(ctx: JSGlobalContextRef, enabled: bool, message: JSStringRef) ---

    // DUMBAI: JSObjectRefPrivate.h
    ObjectSetPrivateProperty :: proc(ctx: JSContextRef, object: JSObjectRef, propertyName: JSStringRef, value: JSValueRef) -> bool ---
    ObjectGetPrivateProperty :: proc(ctx: JSContextRef, object: JSObjectRef, propertyName: JSStringRef) -> JSValueRef ---
    ObjectDeletePrivateProperty :: proc(ctx: JSContextRef, object: JSObjectRef, propertyName: JSStringRef) -> bool ---
    ObjectGetProxyTarget :: proc(object: JSObjectRef) -> JSObjectRef ---
    ObjectGetGlobalContext :: proc(object: JSObjectRef) -> JSGlobalContextRef ---

    // DUMBAI: JSLockRefPrivate.h
    Lock :: proc(ctx: JSContextRef) ---
    Unlock :: proc(ctx: JSContextRef) ---

    // DUMBAI: JSScriptRefPrivate.h
    ScriptCreateReferencingImmortalASCIIText :: proc(contextGroup: JSContextGroupRef, url: JSStringRef, startingLineNumber: c.int, source: cstring, length: c.size_t, errorMessage: ^JSStringRef, errorLine: ^c.int) -> JSScriptRef ---
    ScriptCreateFromString :: proc(contextGroup: JSContextGroupRef, url: JSStringRef, startingLineNumber: c.int, source: JSStringRef, errorMessage: ^JSStringRef, errorLine: ^c.int) -> JSScriptRef ---
    ScriptRetain :: proc(script: JSScriptRef) ---
    ScriptRelease :: proc(script: JSScriptRef) ---
    ScriptEvaluate :: proc(ctx: JSContextRef, script: JSScriptRef, thisValue: JSValueRef, exception: ^JSValueRef) -> JSValueRef ---

    // DUMBAI: JSWeakPrivate.h + JSWeakObjectMapRefPrivate.h
    WeakCreate :: proc(group: JSContextGroupRef, object: JSObjectRef) -> JSWeakRef ---
    WeakRetain :: proc(group: JSContextGroupRef, weak: JSWeakRef) ---
    WeakRelease :: proc(group: JSContextGroupRef, weak: JSWeakRef) ---
    WeakGetObject :: proc(weak: JSWeakRef) -> JSObjectRef ---

    WeakObjectMapCreate :: proc(ctx: JSContextRef, data: rawptr, destructor: JSWeakMapDestroyedCallback) -> JSWeakObjectMapRef ---
    WeakObjectMapSet :: proc(ctx: JSContextRef, weakMap: JSWeakObjectMapRef, key: rawptr, object: JSObjectRef) ---
    WeakObjectMapGet :: proc(ctx: JSContextRef, weakMap: JSWeakObjectMapRef, key: rawptr) -> JSObjectRef ---
    WeakObjectMapRemove :: proc(ctx: JSContextRef, weakMap: JSWeakObjectMapRef, key: rawptr) ---

    // DUMBAI: JSHeapFinalizerPrivate.h + JSMarkingConstraintPrivate.h
    ContextGroupAddHeapFinalizer :: proc(group: JSContextGroupRef, finalizer: JSHeapFinalizer, userData: rawptr) ---
    ContextGroupRemoveHeapFinalizer :: proc(group: JSContextGroupRef, finalizer: JSHeapFinalizer, userData: rawptr) ---
    ContextGroupAddMarkingConstraint :: proc(group: JSContextGroupRef, constraint: JSMarkingConstraint, userData: rawptr) ---
}
