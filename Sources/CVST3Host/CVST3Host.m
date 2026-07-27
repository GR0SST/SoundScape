#import "CVST3Host.h"
#import "Vendor/vst3_c_api.h"

#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <stdatomic.h>

NSErrorDomain const SSVST3ErrorDomain = @"SoundScape.VST3";

typedef bool (*SSVST3BundleEntryProc)(CFBundleRef bundle);
typedef bool (*SSVST3BundleExitProc)(void);
typedef Steinberg_IPluginFactory *(*SSVST3GetFactoryProc)(void);

static BOOL SSVST3UIDEqual(const Steinberg_TUID left,
                           const Steinberg_TUID right) {
    return memcmp(left, right, sizeof(Steinberg_TUID)) == 0;
}

static NSString *SSVST3StringFromCString(const char *value) {
    if (value == NULL || value[0] == '\0') {
        return @"";
    }
    return [NSString stringWithUTF8String:value] ?: @"";
}

static NSString *SSVST3StringFromUTF16(const Steinberg_char16 *value,
                                       NSUInteger capacity) {
    if (value == NULL) {
        return @"";
    }
    NSUInteger length = 0;
    while (length < capacity && value[length] != 0) {
        length++;
    }
    return [[NSString alloc] initWithCharacters:(const unichar *)value
                                         length:length];
}

static NSString *SSVST3HexStringFromUID(const Steinberg_TUID uid) {
    NSMutableString *result = [NSMutableString stringWithCapacity:32];
    for (NSUInteger index = 0; index < sizeof(Steinberg_TUID); index++) {
        [result appendFormat:@"%02X", (uint8_t)uid[index]];
    }
    return result;
}

static BOOL SSVST3UIDFromHexString(NSString *string, Steinberg_TUID result) {
    NSString *compact = [[string
        stringByReplacingOccurrencesOfString:@"-" withString:@""]
        uppercaseString];
    if (compact.length != 32) {
        return NO;
    }

    for (NSUInteger index = 0; index < 16; index++) {
        NSString *pair = [compact substringWithRange:NSMakeRange(index * 2, 2)];
        unsigned int byte = 0;
        NSScanner *scanner = [NSScanner scannerWithString:pair];
        if (![scanner scanHexInt:&byte]) {
            return NO;
        }
        result[index] = (char)(byte & 0xFF);
    }
    return YES;
}

static NSError *SSVST3MakeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:SSVST3ErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

#pragma mark - Host application

typedef struct {
    Steinberg_Vst_IHostApplication interface;
    atomic_uint referenceCount;
} SSVST3HostApplication;

static Steinberg_tresult SSVST3HostQueryInterface(void *thisInterface,
                                                   const Steinberg_TUID iid,
                                                   void **object);
static Steinberg_uint32 SSVST3HostAddRef(void *thisInterface);
static Steinberg_uint32 SSVST3HostRelease(void *thisInterface);
static Steinberg_tresult SSVST3HostGetName(void *thisInterface,
                                           Steinberg_Vst_String128 name);
static Steinberg_tresult SSVST3HostCreateInstance(void *thisInterface,
                                                  Steinberg_TUID cid,
                                                  Steinberg_TUID iid,
                                                  void **object);

static Steinberg_Vst_IHostApplicationVtbl SSVST3HostVTable = {
    SSVST3HostQueryInterface,
    SSVST3HostAddRef,
    SSVST3HostRelease,
    SSVST3HostGetName,
    SSVST3HostCreateInstance,
};

static SSVST3HostApplication SSVST3Host = {
    .interface = {.lpVtbl = &SSVST3HostVTable},
    .referenceCount = 1,
};

static Steinberg_tresult SSVST3HostQueryInterface(void *thisInterface,
                                                   const Steinberg_TUID iid,
                                                   void **object) {
    if (object == NULL) {
        return Steinberg_kInvalidArgument;
    }
    *object = NULL;
    if (SSVST3UIDEqual(iid, Steinberg_FUnknown_iid) ||
        SSVST3UIDEqual(iid, Steinberg_Vst_IHostApplication_iid)) {
        *object = thisInterface;
        SSVST3HostAddRef(thisInterface);
        return Steinberg_kResultOk;
    }
    return Steinberg_kNoInterface;
}

static Steinberg_uint32 SSVST3HostAddRef(void *thisInterface) {
    SSVST3HostApplication *host = thisInterface;
    return atomic_fetch_add_explicit(&host->referenceCount, 1,
                                     memory_order_relaxed) +
           1;
}

static Steinberg_uint32 SSVST3HostRelease(void *thisInterface) {
    SSVST3HostApplication *host = thisInterface;
    unsigned int current =
        atomic_load_explicit(&host->referenceCount, memory_order_relaxed);
    if (current > 1) {
        return atomic_fetch_sub_explicit(&host->referenceCount, 1,
                                         memory_order_relaxed) -
               1;
    }
    return 1;
}

static Steinberg_tresult SSVST3HostGetName(void *thisInterface,
                                           Steinberg_Vst_String128 name) {
    (void)thisInterface;
    NSString *hostName = @"SoundScape";
    NSUInteger count = MIN(hostName.length, (NSUInteger)127);
    [hostName getCharacters:(unichar *)name range:NSMakeRange(0, count)];
    name[count] = 0;
    return Steinberg_kResultOk;
}

static Steinberg_tresult SSVST3HostCreateInstance(void *thisInterface,
                                                  Steinberg_TUID cid,
                                                  Steinberg_TUID iid,
                                                  void **object) {
    (void)thisInterface;
    (void)cid;
    (void)iid;
    if (object != NULL) {
        *object = NULL;
    }
    return Steinberg_kNoInterface;
}

#pragma mark - Realtime parameter interfaces

typedef struct {
    Steinberg_Vst_IParamValueQueue interface;
    Steinberg_Vst_ParamID parameterID;
    Steinberg_Vst_ParamValue value;
    Steinberg_int32 pointCount;
} SSVST3ParameterQueue;

typedef struct {
    Steinberg_Vst_IParameterChanges interface;
    SSVST3ParameterQueue queue;
    Steinberg_int32 parameterCount;
} SSVST3ParameterChanges;

static Steinberg_tresult SSVST3QueueQuery(void *thisInterface,
                                          const Steinberg_TUID iid,
                                          void **object) {
    if (object == NULL) {
        return Steinberg_kInvalidArgument;
    }
    *object = NULL;
    if (SSVST3UIDEqual(iid, Steinberg_FUnknown_iid) ||
        SSVST3UIDEqual(iid, Steinberg_Vst_IParamValueQueue_iid)) {
        *object = thisInterface;
        return Steinberg_kResultOk;
    }
    return Steinberg_kNoInterface;
}

static Steinberg_uint32 SSVST3StaticAddRef(void *thisInterface) {
    (void)thisInterface;
    return 1;
}

static Steinberg_uint32 SSVST3StaticRelease(void *thisInterface) {
    (void)thisInterface;
    return 1;
}

static Steinberg_Vst_ParamID SSVST3QueueGetParameterID(void *thisInterface) {
    SSVST3ParameterQueue *queue = thisInterface;
    return queue->parameterID;
}

static Steinberg_int32 SSVST3QueueGetPointCount(void *thisInterface) {
    SSVST3ParameterQueue *queue = thisInterface;
    return queue->pointCount;
}

static Steinberg_tresult SSVST3QueueGetPoint(
    void *thisInterface, Steinberg_int32 index, Steinberg_int32 *sampleOffset,
    Steinberg_Vst_ParamValue *value) {
    SSVST3ParameterQueue *queue = thisInterface;
    if (index != 0 || queue->pointCount == 0 || sampleOffset == NULL ||
        value == NULL) {
        return Steinberg_kInvalidArgument;
    }
    *sampleOffset = 0;
    *value = queue->value;
    return Steinberg_kResultOk;
}

static Steinberg_tresult SSVST3QueueAddPoint(
    void *thisInterface, Steinberg_int32 sampleOffset,
    Steinberg_Vst_ParamValue value, Steinberg_int32 *index) {
    SSVST3ParameterQueue *queue = thisInterface;
    (void)sampleOffset;
    queue->value = value;
    queue->pointCount = 1;
    if (index != NULL) {
        *index = 0;
    }
    return Steinberg_kResultOk;
}

static Steinberg_Vst_IParamValueQueueVtbl SSVST3ParameterQueueVTable = {
    SSVST3QueueQuery,
    SSVST3StaticAddRef,
    SSVST3StaticRelease,
    SSVST3QueueGetParameterID,
    SSVST3QueueGetPointCount,
    SSVST3QueueGetPoint,
    SSVST3QueueAddPoint,
};

static Steinberg_tresult SSVST3ChangesQuery(void *thisInterface,
                                            const Steinberg_TUID iid,
                                            void **object) {
    if (object == NULL) {
        return Steinberg_kInvalidArgument;
    }
    *object = NULL;
    if (SSVST3UIDEqual(iid, Steinberg_FUnknown_iid) ||
        SSVST3UIDEqual(iid, Steinberg_Vst_IParameterChanges_iid)) {
        *object = thisInterface;
        return Steinberg_kResultOk;
    }
    return Steinberg_kNoInterface;
}

static Steinberg_int32 SSVST3ChangesGetParameterCount(void *thisInterface) {
    SSVST3ParameterChanges *changes = thisInterface;
    return changes->parameterCount;
}

static Steinberg_Vst_IParamValueQueue *
SSVST3ChangesGetParameterData(void *thisInterface, Steinberg_int32 index) {
    SSVST3ParameterChanges *changes = thisInterface;
    if (index != 0 || changes->parameterCount == 0) {
        return NULL;
    }
    return &changes->queue.interface;
}

static Steinberg_Vst_IParamValueQueue *SSVST3ChangesAddParameterData(
    void *thisInterface, const Steinberg_Vst_ParamID *parameterID,
    Steinberg_int32 *index) {
    SSVST3ParameterChanges *changes = thisInterface;
    if (parameterID == NULL) {
        return NULL;
    }
    changes->queue.parameterID = *parameterID;
    changes->queue.pointCount = 0;
    changes->parameterCount = 1;
    if (index != NULL) {
        *index = 0;
    }
    return &changes->queue.interface;
}

static Steinberg_Vst_IParameterChangesVtbl SSVST3ParameterChangesVTable = {
    SSVST3ChangesQuery,
    SSVST3StaticAddRef,
    SSVST3StaticRelease,
    SSVST3ChangesGetParameterCount,
    SSVST3ChangesGetParameterData,
    SSVST3ChangesAddParameterData,
};

@interface SSVST3Plugin (InternalParameterQueue)
- (void)queueParameterID:(uint32_t)parameterID value:(double)value;
@end

typedef struct {
    Steinberg_Vst_IComponentHandler interface;
    void *owner;
} SSVST3ComponentHandler;

static Steinberg_tresult SSVST3HandlerQuery(void *thisInterface,
                                            const Steinberg_TUID iid,
                                            void **object) {
    if (object == NULL) {
        return Steinberg_kInvalidArgument;
    }
    *object = NULL;
    if (SSVST3UIDEqual(iid, Steinberg_FUnknown_iid) ||
        SSVST3UIDEqual(iid, Steinberg_Vst_IComponentHandler_iid)) {
        *object = thisInterface;
        return Steinberg_kResultOk;
    }
    return Steinberg_kNoInterface;
}

static Steinberg_tresult SSVST3HandlerBeginEdit(
    void *thisInterface, Steinberg_Vst_ParamID parameterID) {
    (void)thisInterface;
    (void)parameterID;
    return Steinberg_kResultOk;
}

static Steinberg_tresult SSVST3HandlerPerformEdit(
    void *thisInterface, Steinberg_Vst_ParamID parameterID,
    Steinberg_Vst_ParamValue value) {
    SSVST3ComponentHandler *handler = thisInterface;
    if (handler->owner != NULL) {
        SSVST3Plugin *plugin = (__bridge SSVST3Plugin *)handler->owner;
        [plugin queueParameterID:parameterID value:value];
    }
    return Steinberg_kResultOk;
}

static Steinberg_tresult SSVST3HandlerEndEdit(
    void *thisInterface, Steinberg_Vst_ParamID parameterID) {
    (void)thisInterface;
    (void)parameterID;
    return Steinberg_kResultOk;
}

static Steinberg_tresult SSVST3HandlerRestart(
    void *thisInterface, Steinberg_int32 flags) {
    (void)thisInterface;
    (void)flags;
    return Steinberg_kResultOk;
}

static Steinberg_Vst_IComponentHandlerVtbl SSVST3ComponentHandlerVTable = {
    SSVST3HandlerQuery,
    SSVST3StaticAddRef,
    SSVST3StaticRelease,
    SSVST3HandlerBeginEdit,
    SSVST3HandlerPerformEdit,
    SSVST3HandlerEndEdit,
    SSVST3HandlerRestart,
};

#pragma mark - Module

@interface SSVST3Module : NSObject {
    CFBundleRef _bundleReference;
}

@property(nonatomic) Steinberg_IPluginFactory *factory;
@property(nonatomic) SSVST3BundleExitProc bundleExit;

- (nullable instancetype)initWithPath:(NSString *)path
                                error:(NSError *_Nullable *_Nullable)error;
+ (nullable instancetype)sharedModuleWithPath:(NSString *)path
                                        error:
                                            (NSError *_Nullable *_Nullable)error;

@end

@implementation SSVST3Module

+ (nullable instancetype)sharedModuleWithPath:(NSString *)path
                                        error:
                                            (NSError *_Nullable *_Nullable)error {
    static NSMutableDictionary<NSString *, SSVST3Module *> *modules;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        modules = [NSMutableDictionary dictionary];
    });

    @synchronized(modules) {
        SSVST3Module *existing = modules[path];
        if (existing != nil) {
            return existing;
        }
        SSVST3Module *module =
            [[SSVST3Module alloc] initWithPath:path error:error];
        if (module != nil) {
            modules[path] = module;
        }
        return module;
    }
}

- (nullable instancetype)initWithPath:(NSString *)path
                                error:(NSError *_Nullable *_Nullable)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    NSURL *bundleURL = [NSURL fileURLWithPath:path isDirectory:YES];
    CFBundleRef bundleReference =
        CFBundleCreate(kCFAllocatorDefault, (__bridge CFURLRef)bundleURL);
    if (bundleReference == NULL) {
        if (error != NULL) {
            *error = SSVST3MakeError(1, [NSString
                stringWithFormat:@"Invalid VST3 bundle: %@", path]);
        }
        return nil;
    }

    CFErrorRef loadError = NULL;
    if (!CFBundleLoadExecutableAndReturnError(bundleReference, &loadError)) {
        if (error != NULL) {
            *error = loadError != NULL
                         ? CFBridgingRelease(loadError)
                         : SSVST3MakeError(
                               2, @"The VST3 bundle could not be loaded.");
        } else if (loadError != NULL) {
            CFRelease(loadError);
        }
        CFRelease(bundleReference);
        return nil;
    }

    SSVST3BundleEntryProc bundleEntry =
        (SSVST3BundleEntryProc)CFBundleGetFunctionPointerForName(
            bundleReference, CFSTR("bundleEntry"));
    SSVST3BundleExitProc bundleExit =
        (SSVST3BundleExitProc)CFBundleGetFunctionPointerForName(
            bundleReference, CFSTR("bundleExit"));
    SSVST3GetFactoryProc getFactory =
        (SSVST3GetFactoryProc)CFBundleGetFunctionPointerForName(
            bundleReference, CFSTR("GetPluginFactory"));

    if (bundleEntry == NULL || bundleExit == NULL || getFactory == NULL) {
        CFBundleUnloadExecutable(bundleReference);
        CFRelease(bundleReference);
        if (error != NULL) {
            *error = SSVST3MakeError(
                3, @"The bundle does not export the required VST3 entry points.");
        }
        return nil;
    }
    if (!bundleEntry(bundleReference)) {
        CFBundleUnloadExecutable(bundleReference);
        CFRelease(bundleReference);
        if (error != NULL) {
            *error =
                SSVST3MakeError(4, @"The VST3 bundle rejected initialization.");
        }
        return nil;
    }

    Steinberg_IPluginFactory *factory = getFactory();
    if (factory == NULL) {
        bundleExit();
        CFBundleUnloadExecutable(bundleReference);
        CFRelease(bundleReference);
        if (error != NULL) {
            *error =
                SSVST3MakeError(5, @"The VST3 bundle returned no plug-in factory.");
        }
        return nil;
    }

    Steinberg_IPluginFactory3 *factory3 = NULL;
    if (factory->lpVtbl->queryInterface(
            factory, Steinberg_IPluginFactory3_iid,
            (void **)&factory3) == Steinberg_kResultOk &&
        factory3 != NULL) {
        factory3->lpVtbl->setHostContext(
            factory3, (Steinberg_FUnknown *)&SSVST3Host.interface);
        factory3->lpVtbl->release(factory3);
    }

    _bundleReference = bundleReference;
    _factory = factory;
    _bundleExit = bundleExit;
    return self;
}

- (void)dealloc {
    if (_factory != NULL) {
        _factory->lpVtbl->release(_factory);
        _factory = NULL;
    }
    if (_bundleExit != NULL) {
        _bundleExit();
        _bundleExit = NULL;
    }
    if (_bundleReference != NULL) {
        CFBundleUnloadExecutable(_bundleReference);
        CFRelease(_bundleReference);
        _bundleReference = NULL;
    }
}

@end

#pragma mark - Descriptor

@interface SSVST3Descriptor ()

@property(nonatomic, copy, readwrite) NSString *modulePath;
@property(nonatomic, copy, readwrite) NSString *classID;
@property(nonatomic, copy, readwrite) NSString *name;
@property(nonatomic, copy, readwrite) NSString *vendor;
@property(nonatomic, copy, readwrite) NSString *version;
@property(nonatomic, copy, readwrite) NSString *subcategories;

@end

@implementation SSVST3Descriptor

+ (NSArray<NSString *> *)installedModulePaths {
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    NSString *userLibrary =
        NSSearchPathForDirectoriesInDomains(NSLibraryDirectory,
                                            NSUserDomainMask, YES).firstObject;
    if (userLibrary.length > 0) {
        [roots addObject:[userLibrary
                             stringByAppendingPathComponent:
                                 @"Audio/Plug-Ins/VST3"]];
    }
    [roots addObject:@"/Library/Audio/Plug-Ins/VST3"];
    [roots addObject:@"/Network/Library/Audio/Plug-Ins/VST3"];

    NSString *applicationVST3 = [[NSBundle.mainBundle.bundlePath
        stringByAppendingPathComponent:@"Contents"]
        stringByAppendingPathComponent:@"VST3"];
    [roots addObject:applicationVST3];

    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSFileManager *fileManager = NSFileManager.defaultManager;
    for (NSString *root in roots) {
        NSDirectoryEnumerator<NSURL *> *enumerator = [fileManager
            enumeratorAtURL:[NSURL fileURLWithPath:root isDirectory:YES]
 includingPropertiesForKeys:@[ NSURLIsDirectoryKey ]
                    options:NSDirectoryEnumerationSkipsHiddenFiles
               errorHandler:^BOOL(NSURL *url, NSError *enumerationError) {
                   (void)url;
                   (void)enumerationError;
                   return YES;
               }];
        for (NSURL *url in enumerator) {
            if ([url.pathExtension caseInsensitiveCompare:@"vst3"] !=
                NSOrderedSame) {
                continue;
            }
            [enumerator skipDescendants];
            NSString *resolved = url.URLByResolvingSymlinksInPath.path;
            if (![seen containsObject:resolved]) {
                [seen addObject:resolved];
                [paths addObject:resolved];
            }
        }
    }
    return paths;
}

+ (NSArray<SSVST3Descriptor *> *)descriptorsForModulePath:(NSString *)path
                                                    error:
                                                        (NSError *_Nullable
                                                             *_Nullable)error {
    SSVST3Module *module =
        [SSVST3Module sharedModuleWithPath:path error:error];
    if (module == nil) {
        return @[];
    }

    Steinberg_IPluginFactory *factory = module.factory;
    Steinberg_IPluginFactory2 *factory2 = NULL;
    factory->lpVtbl->queryInterface(factory, Steinberg_IPluginFactory2_iid,
                                    (void **)&factory2);

    NSMutableArray<SSVST3Descriptor *> *results = [NSMutableArray array];
    Steinberg_int32 classCount = factory->lpVtbl->countClasses(factory);
    for (Steinberg_int32 index = 0; index < classCount; index++) {
        struct Steinberg_PClassInfo2 info2 = {0};
        struct Steinberg_PClassInfo info = {0};
        BOOL hasInfo2 =
            factory2 != NULL &&
            factory2->lpVtbl->getClassInfo2(factory2, index, &info2) ==
                Steinberg_kResultOk;
        if (!hasInfo2 &&
            factory->lpVtbl->getClassInfo(factory, index, &info) !=
                Steinberg_kResultOk) {
            continue;
        }

        const char *category = hasInfo2 ? info2.category : info.category;
        if (strcmp(category, "Audio Module Class") != 0) {
            continue;
        }

        SSVST3Descriptor *descriptor = [[SSVST3Descriptor alloc] init];
        descriptor.modulePath = path;
        descriptor.classID =
            SSVST3HexStringFromUID(hasInfo2 ? info2.cid : info.cid);
        descriptor.name =
            SSVST3StringFromCString(hasInfo2 ? info2.name : info.name);
        descriptor.vendor =
            hasInfo2 ? SSVST3StringFromCString(info2.vendor) : @"";
        descriptor.version =
            hasInfo2 ? SSVST3StringFromCString(info2.version) : @"";
        descriptor.subcategories =
            hasInfo2 ? SSVST3StringFromCString(info2.subCategories) : @"Fx";
        [results addObject:descriptor];
    }

    if (factory2 != NULL) {
        factory2->lpVtbl->release(factory2);
    }
    return results;
}

+ (NSArray<SSVST3Descriptor *> *)scanInstalledPlugins:
    (NSError *_Nullable *_Nullable)error {
    NSMutableArray<SSVST3Descriptor *> *results = [NSMutableArray array];
    NSMutableSet<NSString *> *seenClassIDs = [NSMutableSet set];
    NSMutableArray<NSString *> *failures = [NSMutableArray array];

    for (NSString *path in self.installedModulePaths) {
        NSError *moduleError = nil;
        NSArray<SSVST3Descriptor *> *descriptors =
            [self descriptorsForModulePath:path error:&moduleError];
        if (moduleError != nil) {
            [failures addObject:[NSString
                stringWithFormat:@"%@: %@", path.lastPathComponent,
                                 moduleError.localizedDescription]];
            continue;
        }
        for (SSVST3Descriptor *descriptor in descriptors) {
            if (![seenClassIDs containsObject:descriptor.classID]) {
                [seenClassIDs addObject:descriptor.classID];
                [results addObject:descriptor];
            }
        }
    }

    [results sortUsingComparator:^NSComparisonResult(SSVST3Descriptor *left,
                                                     SSVST3Descriptor *right) {
        NSString *leftKey =
            [NSString stringWithFormat:@"%@ %@", left.vendor, left.name];
        NSString *rightKey =
            [NSString stringWithFormat:@"%@ %@", right.vendor, right.name];
        return [leftKey localizedCaseInsensitiveCompare:rightKey];
    }];

    if (results.count == 0 && failures.count > 0 && error != NULL) {
        *error = SSVST3MakeError(
            6, [NSString stringWithFormat:@"No VST3 effects could be loaded. %@",
                                          [failures componentsJoinedByString:
                                                        @"\n"]]);
    }
    return results;
}

@end

#pragma mark - Parameter

@interface SSVST3Parameter ()

@property(nonatomic, readwrite) uint32_t parameterID;
@property(nonatomic, copy, readwrite) NSString *name;
@property(nonatomic, copy, readwrite) NSString *units;
@property(nonatomic, readwrite) double normalizedValue;
@property(nonatomic, readwrite) double defaultNormalizedValue;
@property(nonatomic, readwrite) NSInteger stepCount;
@property(nonatomic, readwrite, getter=isWritable) BOOL writable;
@property(nonatomic, readwrite, getter=isBypass) BOOL bypass;
@property(nonatomic, copy, readwrite) NSString *displayValue;

@end

@implementation SSVST3Parameter
@end

#pragma mark - State stream

@class SSVST3MemoryStream;

typedef struct {
    Steinberg_IBStream interface;
    void *owner;
} SSVST3StreamInterface;

static Steinberg_tresult SSVST3StreamQuery(void *thisInterface,
                                           const Steinberg_TUID iid,
                                           void **object) {
    if (object == NULL) {
        return Steinberg_kInvalidArgument;
    }
    *object = NULL;
    if (SSVST3UIDEqual(iid, Steinberg_FUnknown_iid) ||
        SSVST3UIDEqual(iid, Steinberg_IBStream_iid)) {
        *object = thisInterface;
        return Steinberg_kResultOk;
    }
    return Steinberg_kNoInterface;
}

static Steinberg_tresult SSVST3StreamRead(void *thisInterface, void *buffer,
                                          Steinberg_int32 numBytes,
                                          Steinberg_int32 *numBytesRead);
static Steinberg_tresult SSVST3StreamWrite(void *thisInterface, void *buffer,
                                           Steinberg_int32 numBytes,
                                           Steinberg_int32 *numBytesWritten);
static Steinberg_tresult SSVST3StreamSeek(void *thisInterface,
                                          Steinberg_int64 position,
                                          Steinberg_int32 mode,
                                          Steinberg_int64 *result);
static Steinberg_tresult SSVST3StreamTell(void *thisInterface,
                                          Steinberg_int64 *position);

static Steinberg_IBStreamVtbl SSVST3StreamVTable = {
    SSVST3StreamQuery,
    SSVST3StaticAddRef,
    SSVST3StaticRelease,
    SSVST3StreamRead,
    SSVST3StreamWrite,
    SSVST3StreamSeek,
    SSVST3StreamTell,
};

@interface SSVST3MemoryStream : NSObject {
    SSVST3StreamInterface _stream;
}

@property(nonatomic, strong) NSMutableData *data;
@property(nonatomic) NSUInteger position;
@property(nonatomic, readonly) Steinberg_IBStream *interfacePointer;

- (instancetype)initWithData:(nullable NSData *)data;

@end

@implementation SSVST3MemoryStream

- (instancetype)initWithData:(nullable NSData *)data {
    self = [super init];
    if (self != nil) {
        _stream.interface.lpVtbl = &SSVST3StreamVTable;
        _stream.owner = (__bridge void *)self;
        _data = data != nil ? [data mutableCopy] : [NSMutableData data];
        _position = 0;
    }
    return self;
}

- (Steinberg_IBStream *)interfacePointer {
    return &_stream.interface;
}

- (void)dealloc {
    _stream.owner = NULL;
}

@end

static SSVST3MemoryStream *SSVST3StreamOwner(void *thisInterface) {
    SSVST3StreamInterface *stream = thisInterface;
    if (stream->owner == NULL) {
        return nil;
    }
    return (__bridge SSVST3MemoryStream *)stream->owner;
}

static Steinberg_tresult SSVST3StreamRead(void *thisInterface, void *buffer,
                                          Steinberg_int32 numBytes,
                                          Steinberg_int32 *numBytesRead) {
    SSVST3MemoryStream *stream = SSVST3StreamOwner(thisInterface);
    if (stream == nil || buffer == NULL || numBytes < 0) {
        return Steinberg_kInvalidArgument;
    }
    NSUInteger available =
        stream.position < stream.data.length
            ? stream.data.length - stream.position
            : 0;
    NSUInteger count = MIN((NSUInteger)numBytes, available);
    if (count > 0) {
        [stream.data getBytes:buffer
                       range:NSMakeRange(stream.position, count)];
        stream.position += count;
    }
    if (numBytesRead != NULL) {
        *numBytesRead = (Steinberg_int32)count;
    }
    return Steinberg_kResultOk;
}

static Steinberg_tresult SSVST3StreamWrite(void *thisInterface, void *buffer,
                                           Steinberg_int32 numBytes,
                                           Steinberg_int32 *numBytesWritten) {
    SSVST3MemoryStream *stream = SSVST3StreamOwner(thisInterface);
    if (stream == nil || buffer == NULL || numBytes < 0) {
        return Steinberg_kInvalidArgument;
    }
    NSUInteger count = (NSUInteger)numBytes;
    NSUInteger requiredLength = stream.position + count;
    if (requiredLength > stream.data.length) {
        stream.data.length = requiredLength;
    }
    if (count > 0) {
        [stream.data replaceBytesInRange:NSMakeRange(stream.position, count)
                               withBytes:buffer];
        stream.position += count;
    }
    if (numBytesWritten != NULL) {
        *numBytesWritten = numBytes;
    }
    return Steinberg_kResultOk;
}

static Steinberg_tresult SSVST3StreamSeek(void *thisInterface,
                                          Steinberg_int64 position,
                                          Steinberg_int32 mode,
                                          Steinberg_int64 *result) {
    SSVST3MemoryStream *stream = SSVST3StreamOwner(thisInterface);
    if (stream == nil) {
        return Steinberg_kInvalidArgument;
    }
    int64_t base = 0;
    switch (mode) {
    case Steinberg_IBStream_IStreamSeekMode_kIBSeekSet:
        base = 0;
        break;
    case Steinberg_IBStream_IStreamSeekMode_kIBSeekCur:
        base = (int64_t)stream.position;
        break;
    case Steinberg_IBStream_IStreamSeekMode_kIBSeekEnd:
        base = (int64_t)stream.data.length;
        break;
    default:
        return Steinberg_kInvalidArgument;
    }
    int64_t next = base + position;
    if (next < 0) {
        return Steinberg_kInvalidArgument;
    }
    stream.position = (NSUInteger)next;
    if (result != NULL) {
        *result = next;
    }
    return Steinberg_kResultOk;
}

static Steinberg_tresult SSVST3StreamTell(void *thisInterface,
                                          Steinberg_int64 *position) {
    SSVST3MemoryStream *stream = SSVST3StreamOwner(thisInterface);
    if (stream == nil || position == NULL) {
        return Steinberg_kInvalidArgument;
    }
    *position = (Steinberg_int64)stream.position;
    return Steinberg_kResultOk;
}

#pragma mark - Plug-in editor

@class SSVST3ViewController;

typedef struct {
    Steinberg_IPlugFrame interface;
    void *owner;
} SSVST3PlugFrame;

static Steinberg_tresult SSVST3FrameQuery(void *thisInterface,
                                          const Steinberg_TUID iid,
                                          void **object) {
    if (object == NULL) {
        return Steinberg_kInvalidArgument;
    }
    *object = NULL;
    if (SSVST3UIDEqual(iid, Steinberg_FUnknown_iid) ||
        SSVST3UIDEqual(iid, Steinberg_IPlugFrame_iid)) {
        *object = thisInterface;
        return Steinberg_kResultOk;
    }
    return Steinberg_kNoInterface;
}

static Steinberg_tresult SSVST3FrameResizeView(
    void *thisInterface, Steinberg_IPlugView *view,
    struct Steinberg_ViewRect *newSize);

static Steinberg_IPlugFrameVtbl SSVST3PlugFrameVTable = {
    SSVST3FrameQuery,
    SSVST3StaticAddRef,
    SSVST3StaticRelease,
    SSVST3FrameResizeView,
};

@interface SSVST3ViewController : NSViewController {
    Steinberg_IPlugView *_plugView;
    SSVST3PlugFrame _plugFrame;
}

@property(nonatomic, strong) SSVST3Plugin *pluginOwner;
@property(nonatomic, readonly) BOOL plugViewAttached;

- (instancetype)initWithPlugView:(Steinberg_IPlugView *)plugView;
- (void)applyPlugViewRect:(struct Steinberg_ViewRect)rect;

@end

@implementation SSVST3ViewController {
    BOOL _plugViewAttached;
}

- (instancetype)initWithPlugView:(Steinberg_IPlugView *)plugView {
    self = [super initWithNibName:nil bundle:nil];
    if (self != nil) {
        _plugView = plugView;
        _plugFrame.interface.lpVtbl = &SSVST3PlugFrameVTable;
        _plugFrame.owner = (__bridge void *)self;
    }
    return self;
}

- (BOOL)plugViewAttached {
    return _plugViewAttached;
}

- (void)loadView {
    struct Steinberg_ViewRect rect = {0, 0, 640, 420};
    if (_plugView != NULL) {
        _plugView->lpVtbl->getSize(_plugView, &rect);
    }
    CGFloat width = MAX(1, rect.right - rect.left);
    CGFloat height = MAX(1, rect.bottom - rect.top);
    NSView *container =
        [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    container.wantsLayer = YES;
    self.view = container;
    self.preferredContentSize = NSMakeSize(width, height);

    if (_plugView != NULL) {
        _plugView->lpVtbl->setFrame(_plugView, &_plugFrame.interface);
        _plugViewAttached =
            _plugView->lpVtbl->attached(
                _plugView, (__bridge void *)container,
                Steinberg_kPlatformTypeNSView) == Steinberg_kResultOk;
    }
}

- (void)applyPlugViewRect:(struct Steinberg_ViewRect)rect {
    CGFloat width = MAX(1, rect.right - rect.left);
    CGFloat height = MAX(1, rect.bottom - rect.top);
    self.preferredContentSize = NSMakeSize(width, height);
    [self.view setFrameSize:NSMakeSize(width, height)];
}

- (void)dealloc {
    _plugFrame.owner = NULL;
    if (_plugView != NULL) {
        if (_plugViewAttached) {
            _plugView->lpVtbl->removed(_plugView);
        }
        _plugView->lpVtbl->setFrame(_plugView, NULL);
        _plugView->lpVtbl->release(_plugView);
        _plugView = NULL;
    }
}

@end

static Steinberg_tresult SSVST3FrameResizeView(
    void *thisInterface, Steinberg_IPlugView *view,
    struct Steinberg_ViewRect *newSize) {
    (void)view;
    SSVST3PlugFrame *frame = thisInterface;
    if (frame->owner == NULL || newSize == NULL) {
        return Steinberg_kInvalidArgument;
    }
    SSVST3ViewController *controller =
        (__bridge SSVST3ViewController *)frame->owner;
    struct Steinberg_ViewRect requested = *newSize;
    if (NSThread.isMainThread) {
        [controller applyPlugViewRect:requested];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [controller applyPlugViewRect:requested];
        });
    }
    return Steinberg_kResultOk;
}

#pragma mark - Plug-in instance

@interface SSVST3Plugin () {
    SSVST3Module *_module;
    Steinberg_Vst_IComponent *_component;
    Steinberg_Vst_IAudioProcessor *_processor;
    Steinberg_Vst_IEditController *_controller;
    Steinberg_Vst_IConnectionPoint *_componentConnection;
    Steinberg_Vst_IConnectionPoint *_controllerConnection;
    BOOL _controllerInitializedSeparately;
    struct Steinberg_Vst_AudioBusBuffers _inputBus;
    struct Steinberg_Vst_AudioBusBuffers _outputBus;
    Steinberg_Vst_Sample32 *_inputPointers[32];
    Steinberg_Vst_Sample32 *_outputPointers[32];
    struct Steinberg_Vst_ProcessContext _processContext;
    int64_t _continuousSampleTime;
    SSVST3ParameterChanges _parameterChanges;
    atomic_uint_fast32_t _pendingParameterID;
    atomic_uint_fast64_t _pendingParameterValueBits;
    atomic_uint_fast64_t _pendingParameterGeneration;
    uint64_t _consumedParameterGeneration;
    SSVST3ComponentHandler _componentHandler;
}

@property(nonatomic, copy, readwrite) NSString *name;
@property(nonatomic, copy, readwrite) NSString *vendor;
@property(nonatomic, copy, readwrite) NSArray<SSVST3Parameter *> *parameters;
@property(nonatomic, readwrite) NSInteger inputChannelCount;
@property(nonatomic, readwrite) NSInteger outputChannelCount;
@property(nonatomic, readwrite, getter=isPrepared) BOOL prepared;

@end

@implementation SSVST3Plugin

- (nullable instancetype)initWithModulePath:(NSString *)modulePath
                                    classID:(NSString *)classID
                                      error:(NSError *_Nullable *_Nullable)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _parameterChanges.interface.lpVtbl = &SSVST3ParameterChangesVTable;
    _parameterChanges.queue.interface.lpVtbl = &SSVST3ParameterQueueVTable;
    atomic_init(&_pendingParameterID, 0);
    atomic_init(&_pendingParameterValueBits, 0);
    atomic_init(&_pendingParameterGeneration, 0);
    _consumedParameterGeneration = 0;
    _componentHandler.interface.lpVtbl = &SSVST3ComponentHandlerVTable;
    _componentHandler.owner = (__bridge void *)self;

    Steinberg_TUID targetClassID = {0};
    if (!SSVST3UIDFromHexString(classID, targetClassID)) {
        if (error != NULL) {
            *error = SSVST3MakeError(10, @"The saved VST3 class identifier is invalid.");
        }
        return nil;
    }

    _module =
        [SSVST3Module sharedModuleWithPath:modulePath error:error];
    if (_module == nil) {
        return nil;
    }

    Steinberg_IPluginFactory *factory = _module.factory;
    struct Steinberg_PFactoryInfo factoryInfo = {0};
    factory->lpVtbl->getFactoryInfo(factory, &factoryInfo);
    self.vendor = SSVST3StringFromCString(factoryInfo.vendor);

    void *componentObject = NULL;
    Steinberg_tresult result = factory->lpVtbl->createInstance(
        factory, targetClassID, Steinberg_Vst_IComponent_iid, &componentObject);
    if (result != Steinberg_kResultOk || componentObject == NULL) {
        if (error != NULL) {
            *error = SSVST3MakeError(11, @"The VST3 processor could not be created.");
        }
        return nil;
    }
    _component = componentObject;

    if (_component->lpVtbl->initialize(
            _component, (Steinberg_FUnknown *)&SSVST3Host.interface) !=
        Steinberg_kResultOk) {
        if (error != NULL) {
            *error =
                SSVST3MakeError(12, @"The VST3 processor failed to initialize.");
        }
        return nil;
    }

    if (_component->lpVtbl->queryInterface(
            _component, Steinberg_Vst_IAudioProcessor_iid,
            (void **)&_processor) != Steinberg_kResultOk ||
        _processor == NULL) {
        if (error != NULL) {
            *error = SSVST3MakeError(
                13, @"The selected VST3 class is not an audio processor.");
        }
        return nil;
    }

    if (_component->lpVtbl->queryInterface(
            _component, Steinberg_Vst_IEditController_iid,
            (void **)&_controller) != Steinberg_kResultOk ||
        _controller == NULL) {
        Steinberg_TUID controllerClassID = {0};
        if (_component->lpVtbl->getControllerClassId(
                _component, controllerClassID) == Steinberg_kResultOk) {
            void *controllerObject = NULL;
            if (factory->lpVtbl->createInstance(
                    factory, controllerClassID,
                    Steinberg_Vst_IEditController_iid,
                    &controllerObject) == Steinberg_kResultOk) {
                _controller = controllerObject;
                if (_controller != NULL &&
                    _controller->lpVtbl->initialize(
                        _controller,
                        (Steinberg_FUnknown *)&SSVST3Host.interface) ==
                        Steinberg_kResultOk) {
                    _controllerInitializedSeparately = YES;
                }
            }
        }
    }

    if (_controller != NULL) {
        _component->lpVtbl->queryInterface(
            _component, Steinberg_Vst_IConnectionPoint_iid,
            (void **)&_componentConnection);
        _controller->lpVtbl->queryInterface(
            _controller, Steinberg_Vst_IConnectionPoint_iid,
            (void **)&_controllerConnection);
        if (_componentConnection != NULL && _controllerConnection != NULL) {
            _componentConnection->lpVtbl->connect(_componentConnection,
                                                  _controllerConnection);
            _controllerConnection->lpVtbl->connect(_controllerConnection,
                                                    _componentConnection);
        }
        _controller->lpVtbl->setComponentHandler(
            _controller, &_componentHandler.interface);
    }

    self.name = modulePath.lastPathComponent.stringByDeletingPathExtension;
    Steinberg_IPluginFactory2 *factory2 = NULL;
    if (factory->lpVtbl->queryInterface(
            factory, Steinberg_IPluginFactory2_iid,
            (void **)&factory2) == Steinberg_kResultOk &&
        factory2 != NULL) {
        Steinberg_int32 classCount = factory->lpVtbl->countClasses(factory);
        for (Steinberg_int32 index = 0; index < classCount; index++) {
            struct Steinberg_PClassInfo2 info = {0};
            if (factory2->lpVtbl->getClassInfo2(factory2, index, &info) ==
                    Steinberg_kResultOk &&
                SSVST3UIDEqual(info.cid, targetClassID)) {
                self.name = SSVST3StringFromCString(info.name);
                if (info.vendor[0] != '\0') {
                    self.vendor = SSVST3StringFromCString(info.vendor);
                }
                break;
            }
        }
        factory2->lpVtbl->release(factory2);
    }

    [self rebuildParameters];
    return self;
}

- (void)dealloc {
    [self unprepare];
    _componentHandler.owner = NULL;
    if (_controller != NULL) {
        _controller->lpVtbl->setComponentHandler(_controller, NULL);
    }
    if (_componentConnection != NULL && _controllerConnection != NULL) {
        _componentConnection->lpVtbl->disconnect(_componentConnection,
                                                 _controllerConnection);
        _controllerConnection->lpVtbl->disconnect(_controllerConnection,
                                                   _componentConnection);
    }
    if (_componentConnection != NULL) {
        _componentConnection->lpVtbl->release(_componentConnection);
    }
    if (_controllerConnection != NULL) {
        _controllerConnection->lpVtbl->release(_controllerConnection);
    }
    if (_controller != NULL) {
        if (_controllerInitializedSeparately) {
            _controller->lpVtbl->terminate(_controller);
        }
        _controller->lpVtbl->release(_controller);
    }
    if (_processor != NULL) {
        _processor->lpVtbl->release(_processor);
    }
    if (_component != NULL) {
        _component->lpVtbl->terminate(_component);
        _component->lpVtbl->release(_component);
    }
}

- (BOOL)prepareWithSampleRate:(double)sampleRate
              maximumFrames:(uint32_t)maximumFrames
                    channels:(uint32_t)channels
                       error:(NSError *_Nullable *_Nullable)error {
    [self unprepare];
    if (_component == NULL || _processor == NULL || sampleRate <= 0 ||
        maximumFrames == 0) {
        if (error != NULL) {
            *error = SSVST3MakeError(20, @"The VST3 processing format is invalid.");
        }
        return NO;
    }

    uint32_t requestedChannels = MIN(MAX(channels, 1u), 2u);
    Steinberg_Vst_SpeakerArrangement arrangement =
        requestedChannels == 1 ? Steinberg_Vst_SpeakerArr_kMono
                               : Steinberg_Vst_SpeakerArr_kStereo;
    _component->lpVtbl->setIoMode(_component,
                                  Steinberg_Vst_IoModes_kSimple);

    Steinberg_int32 inputBusCount = _component->lpVtbl->getBusCount(
        _component, Steinberg_Vst_MediaTypes_kAudio,
        Steinberg_Vst_BusDirections_kInput);
    Steinberg_int32 outputBusCount = _component->lpVtbl->getBusCount(
        _component, Steinberg_Vst_MediaTypes_kAudio,
        Steinberg_Vst_BusDirections_kOutput);
    if (inputBusCount < 1 || outputBusCount < 1) {
        if (error != NULL) {
            *error =
                SSVST3MakeError(21, @"Only VST3 audio effects with input and output busses are supported.");
        }
        return NO;
    }

    Steinberg_tresult arrangementResult =
        _processor->lpVtbl->setBusArrangements(
            _processor, &arrangement, 1, &arrangement, 1);
    if (arrangementResult != Steinberg_kResultOk &&
        requestedChannels == 2) {
        arrangement = Steinberg_Vst_SpeakerArr_kMono;
        arrangementResult = _processor->lpVtbl->setBusArrangements(
            _processor, &arrangement, 1, &arrangement, 1);
    }

    struct Steinberg_Vst_BusInfo inputInfo = {0};
    struct Steinberg_Vst_BusInfo outputInfo = {0};
    if (_component->lpVtbl->getBusInfo(
            _component, Steinberg_Vst_MediaTypes_kAudio,
            Steinberg_Vst_BusDirections_kInput, 0,
            &inputInfo) != Steinberg_kResultOk ||
        _component->lpVtbl->getBusInfo(
            _component, Steinberg_Vst_MediaTypes_kAudio,
            Steinberg_Vst_BusDirections_kOutput, 0,
            &outputInfo) != Steinberg_kResultOk ||
        inputInfo.channelCount < 1 || outputInfo.channelCount < 1 ||
        inputInfo.channelCount > 32 || outputInfo.channelCount > 32) {
        if (error != NULL) {
            *error =
                SSVST3MakeError(22, @"The VST3 plug-in reported unsupported audio busses.");
        }
        return NO;
    }

    if (_processor->lpVtbl->canProcessSampleSize(
            _processor, Steinberg_Vst_SymbolicSampleSizes_kSample32) !=
        Steinberg_kResultOk) {
        if (error != NULL) {
            *error =
                SSVST3MakeError(23, @"The VST3 plug-in does not support Float32 audio.");
        }
        return NO;
    }

    _component->lpVtbl->activateBus(
        _component, Steinberg_Vst_MediaTypes_kAudio,
        Steinberg_Vst_BusDirections_kInput, 0, true);
    _component->lpVtbl->activateBus(
        _component, Steinberg_Vst_MediaTypes_kAudio,
        Steinberg_Vst_BusDirections_kOutput, 0, true);

    struct Steinberg_Vst_ProcessSetup setup = {
        .processMode = Steinberg_Vst_ProcessModes_kRealtime,
        .symbolicSampleSize = Steinberg_Vst_SymbolicSampleSizes_kSample32,
        .maxSamplesPerBlock = (Steinberg_int32)maximumFrames,
        .sampleRate = sampleRate,
    };
    if (_processor->lpVtbl->setupProcessing(_processor, &setup) !=
            Steinberg_kResultOk ||
        _component->lpVtbl->setActive(_component, true) !=
            Steinberg_kResultOk ||
        _processor->lpVtbl->setProcessing(_processor, true) !=
            Steinberg_kResultOk) {
        _component->lpVtbl->setActive(_component, false);
        if (error != NULL) {
            *error =
                SSVST3MakeError(24, @"The VST3 plug-in rejected the processing format.");
        }
        return NO;
    }

    self.inputChannelCount = inputInfo.channelCount;
    self.outputChannelCount = outputInfo.channelCount;
    _inputBus.numChannels = inputInfo.channelCount;
    _inputBus.silenceFlags = 0;
    _inputBus.Steinberg_Vst_AudioBusBuffers_channelBuffers32 = _inputPointers;
    _outputBus.numChannels = outputInfo.channelCount;
    _outputBus.silenceFlags = 0;
    _outputBus.Steinberg_Vst_AudioBusBuffers_channelBuffers32 = _outputPointers;
    memset(&_processContext, 0, sizeof(_processContext));
    _processContext.sampleRate = sampleRate;
    _processContext.tempo = 120.0;
    _continuousSampleTime = 0;
    self.prepared = YES;
    return YES;
}

- (void)unprepare {
    if (!self.prepared) {
        return;
    }
    _processor->lpVtbl->setProcessing(_processor, false);
    _component->lpVtbl->setActive(_component, false);
    _component->lpVtbl->activateBus(
        _component, Steinberg_Vst_MediaTypes_kAudio,
        Steinberg_Vst_BusDirections_kInput, 0, false);
    _component->lpVtbl->activateBus(
        _component, Steinberg_Vst_MediaTypes_kAudio,
        Steinberg_Vst_BusDirections_kOutput, 0, false);
    self.prepared = NO;
}

- (BOOL)processAudioBufferList:(AudioBufferList *)audioBufferList
                    frameCount:(uint32_t)frameCount {
    if (!self.prepared || audioBufferList == NULL || frameCount == 0 ||
        audioBufferList->mNumberBuffers == 0) {
        return NO;
    }

    uint32_t availableChannels = audioBufferList->mNumberBuffers;
    for (NSInteger channel = 0; channel < self.inputChannelCount; channel++) {
        uint32_t sourceChannel =
            MIN((uint32_t)channel, availableChannels - 1);
        _inputPointers[channel] =
            audioBufferList->mBuffers[sourceChannel].mData;
    }
    for (NSInteger channel = 0; channel < self.outputChannelCount; channel++) {
        uint32_t destinationChannel =
            MIN((uint32_t)channel, availableChannels - 1);
        _outputPointers[channel] =
            audioBufferList->mBuffers[destinationChannel].mData;
    }

    _inputBus.silenceFlags = 0;
    _outputBus.silenceFlags = 0;
    _processContext.continousTimeSamples = _continuousSampleTime;
    uint64_t parameterGeneration = atomic_load_explicit(
        &_pendingParameterGeneration, memory_order_acquire);
    if (parameterGeneration != _consumedParameterGeneration) {
        uint64_t valueBits = atomic_load_explicit(
            &_pendingParameterValueBits, memory_order_relaxed);
        double parameterValue = 0;
        memcpy(&parameterValue, &valueBits, sizeof(parameterValue));
        _parameterChanges.queue.parameterID = atomic_load_explicit(
            &_pendingParameterID, memory_order_relaxed);
        _parameterChanges.queue.value = parameterValue;
        _parameterChanges.queue.pointCount = 1;
        _parameterChanges.parameterCount = 1;
    } else {
        _parameterChanges.queue.pointCount = 0;
        _parameterChanges.parameterCount = 0;
    }
    struct Steinberg_Vst_ProcessData processData = {
        .processMode = Steinberg_Vst_ProcessModes_kRealtime,
        .symbolicSampleSize = Steinberg_Vst_SymbolicSampleSizes_kSample32,
        .numSamples = (Steinberg_int32)frameCount,
        .numInputs = 1,
        .numOutputs = 1,
        .inputs = &_inputBus,
        .outputs = &_outputBus,
        .inputParameterChanges = &_parameterChanges.interface,
        .outputParameterChanges = NULL,
        .inputEvents = NULL,
        .outputEvents = NULL,
        .processContext = &_processContext,
    };

    Steinberg_tresult result =
        _processor->lpVtbl->process(_processor, &processData);
    _consumedParameterGeneration = parameterGeneration;
    _parameterChanges.queue.pointCount = 0;
    _parameterChanges.parameterCount = 0;
    _continuousSampleTime += frameCount;
    return result == Steinberg_kResultOk;
}

- (BOOL)setNormalizedValue:(double)value
               parameterID:(uint32_t)parameterID {
    if (_controller == NULL) {
        return NO;
    }
    double clamped = MIN(MAX(value, 0.0), 1.0);
    if (_controller->lpVtbl->setParamNormalized(
            _controller, parameterID, clamped) != Steinberg_kResultOk) {
        return NO;
    }
    [self queueParameterID:parameterID value:clamped];
    [self refreshParameterValues];
    return YES;
}

- (void)queueParameterID:(uint32_t)parameterID value:(double)value {
    uint64_t valueBits = 0;
    memcpy(&valueBits, &value, sizeof(valueBits));
    atomic_store_explicit(&_pendingParameterID, parameterID,
                          memory_order_relaxed);
    atomic_store_explicit(&_pendingParameterValueBits, valueBits,
                          memory_order_relaxed);
    atomic_fetch_add_explicit(&_pendingParameterGeneration, 1,
                              memory_order_release);
}

- (void)rebuildParameters {
    if (_controller == NULL) {
        self.parameters = @[];
        return;
    }

    NSMutableArray<SSVST3Parameter *> *parameters = [NSMutableArray array];
    Steinberg_int32 count =
        _controller->lpVtbl->getParameterCount(_controller);
    for (Steinberg_int32 index = 0; index < count; index++) {
        struct Steinberg_Vst_ParameterInfo info = {0};
        if (_controller->lpVtbl->getParameterInfo(_controller, index, &info) !=
            Steinberg_kResultOk) {
            continue;
        }
        if ((info.flags &
             Steinberg_Vst_ParameterInfo_ParameterFlags_kIsHidden) != 0) {
            continue;
        }

        SSVST3Parameter *parameter = [[SSVST3Parameter alloc] init];
        parameter.parameterID = info.id;
        parameter.name = SSVST3StringFromUTF16(info.title, 128);
        parameter.units = SSVST3StringFromUTF16(info.units, 128);
        parameter.defaultNormalizedValue = info.defaultNormalizedValue;
        parameter.stepCount = info.stepCount;
        parameter.writable =
            (info.flags &
             Steinberg_Vst_ParameterInfo_ParameterFlags_kIsReadOnly) == 0;
        parameter.bypass =
            (info.flags &
             Steinberg_Vst_ParameterInfo_ParameterFlags_kIsBypass) != 0;
        parameter.normalizedValue =
            _controller->lpVtbl->getParamNormalized(_controller, info.id);
        Steinberg_Vst_String128 display = {0};
        if (_controller->lpVtbl->getParamStringByValue(
                _controller, info.id, parameter.normalizedValue,
                display) == Steinberg_kResultOk) {
            parameter.displayValue = SSVST3StringFromUTF16(display, 128);
        } else {
            parameter.displayValue =
                [NSString stringWithFormat:@"%.3f", parameter.normalizedValue];
        }
        [parameters addObject:parameter];
    }
    self.parameters = parameters;
}

- (void)refreshParameterValues {
    if (_controller == NULL) {
        return;
    }
    for (SSVST3Parameter *parameter in self.parameters) {
        parameter.normalizedValue =
            _controller->lpVtbl->getParamNormalized(_controller,
                                                     parameter.parameterID);
        Steinberg_Vst_String128 display = {0};
        if (_controller->lpVtbl->getParamStringByValue(
                _controller, parameter.parameterID,
                parameter.normalizedValue, display) == Steinberg_kResultOk) {
            parameter.displayValue = SSVST3StringFromUTF16(display, 128);
        }
    }
}

- (nullable NSData *)stateData {
    if (_component == NULL) {
        return nil;
    }

    SSVST3MemoryStream *componentStream =
        [[SSVST3MemoryStream alloc] initWithData:nil];
    if (_component->lpVtbl->getState(
            _component, componentStream.interfacePointer) !=
        Steinberg_kResultOk) {
        return nil;
    }

    NSMutableDictionary<NSString *, NSData *> *state =
        [NSMutableDictionary dictionaryWithObject:componentStream.data
                                           forKey:@"component"];
    if (_controller != NULL) {
        SSVST3MemoryStream *controllerStream =
            [[SSVST3MemoryStream alloc] initWithData:nil];
        if (_controller->lpVtbl->getState(
                _controller, controllerStream.interfacePointer) ==
            Steinberg_kResultOk) {
            state[@"controller"] = controllerStream.data;
        }
    }

    return [NSPropertyListSerialization
        dataWithPropertyList:state
                      format:NSPropertyListBinaryFormat_v1_0
                     options:0
                       error:nil];
}

- (BOOL)loadStateData:(NSData *)stateData
                 error:(NSError *_Nullable *_Nullable)error {
    if (_component == NULL || stateData.length == 0) {
        return NO;
    }

    NSError *decodeError = nil;
    id propertyList = [NSPropertyListSerialization
        propertyListWithData:stateData
                     options:NSPropertyListImmutable
                      format:nil
                       error:&decodeError];
    if (![propertyList isKindOfClass:NSDictionary.class]) {
        if (error != NULL) {
            *error = decodeError ?: SSVST3MakeError(
                                      40, @"The saved VST3 state is invalid.");
        }
        return NO;
    }

    NSDictionary *state = propertyList;
    NSData *componentData = state[@"component"];
    if (![componentData isKindOfClass:NSData.class]) {
        if (error != NULL) {
            *error = SSVST3MakeError(
                41, @"The saved VST3 state contains no processor state.");
        }
        return NO;
    }

    SSVST3MemoryStream *componentStream =
        [[SSVST3MemoryStream alloc] initWithData:componentData];
    if (_component->lpVtbl->setState(
            _component, componentStream.interfacePointer) !=
        Steinberg_kResultOk) {
        if (error != NULL) {
            *error =
                SSVST3MakeError(42, @"The VST3 processor rejected its saved state.");
        }
        return NO;
    }

    if (_controller != NULL) {
        SSVST3MemoryStream *componentStateForController =
            [[SSVST3MemoryStream alloc] initWithData:componentData];
        _controller->lpVtbl->setComponentState(
            _controller, componentStateForController.interfacePointer);

        NSData *controllerData = state[@"controller"];
        if ([controllerData isKindOfClass:NSData.class]) {
            SSVST3MemoryStream *controllerStream =
                [[SSVST3MemoryStream alloc] initWithData:controllerData];
            _controller->lpVtbl->setState(
                _controller, controllerStream.interfacePointer);
        }
    }
    [self rebuildParameters];
    return YES;
}

- (nullable NSViewController *)createViewControllerWithError:
    (NSError *_Nullable *_Nullable)error {
    if (_controller == NULL) {
        if (error != NULL) {
            *error = SSVST3MakeError(
                30, @"The VST3 plug-in does not provide an edit controller.");
        }
        return nil;
    }

    Steinberg_IPlugView *plugView = _controller->lpVtbl->createView(
        _controller, Steinberg_Vst_ViewType_kEditor);
    if (plugView == NULL) {
        if (error != NULL) {
            *error =
                SSVST3MakeError(31, @"The VST3 plug-in has no custom interface.");
        }
        return nil;
    }
    if (plugView->lpVtbl->isPlatformTypeSupported(
            plugView, Steinberg_kPlatformTypeNSView) != Steinberg_kResultOk) {
        plugView->lpVtbl->release(plugView);
        if (error != NULL) {
            *error = SSVST3MakeError(
                32, @"The VST3 interface is not compatible with macOS NSView hosting.");
        }
        return nil;
    }

    SSVST3ViewController *viewController =
        [[SSVST3ViewController alloc] initWithPlugView:plugView];
    viewController.pluginOwner = self;
    [viewController loadView];
    if (!viewController.plugViewAttached) {
        if (error != NULL) {
            *error =
                SSVST3MakeError(33, @"The VST3 interface could not be attached.");
        }
        return nil;
    }
    return viewController;
}

@end
