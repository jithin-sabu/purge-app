#import "PrivateBridge.h"
#import <dlfcn.h>
#import <objc/runtime.h>

static NSString *const kUAFPath =
    @"/System/Library/PrivateFrameworks/UnifiedAssetFramework.framework/UnifiedAssetFramework";
static NSString *const kCacheDeletePath =
    @"/System/Library/PrivateFrameworks/CacheDelete.framework/CacheDelete";
static NSString *const kService = @"com.apple.siri.uaf.subscription.service";
static NSString *const kErrorDomain = @"io.getpurge.spike.aimodels";

// Declared on NSObject so the compiler emits the real selector encodings,
// including the oneway XPC method. Nothing here is ever called on an object
// that was not first checked with respondsToSelector:.
@interface NSObject (PBPrivateSelectors)
+ (id)defaultManager;
+ (NSXPCInterface *)defaultInterface;
+ (id)latestStatusForClients:(NSString *)name error:(NSError **)error;
+ (id)generateInformationWithError:(NSError **)error;
- (id)getAssetSet:(NSString *)name;
- (NSString *)autoAssetType;
- (int64_t)downloadedFilesystemBytes;
- (instancetype)initWithName:(NSString *)name
                   assetSets:(NSDictionary *)assetSets
                usageAliases:(NSDictionary *)usageAliases;
- (BOOL)isValid:(id)manager error:(NSError **)error;
- (oneway void)operationWithConfig:(NSDictionary *)configuration
                        completion:(void (^)(NSError *_Nullable))completion;
@end

static NSError *PBError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:kErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

static void PBSetError(NSError **error, NSInteger code, NSString *message) {
    if (error) *error = PBError(code, message);
}

#pragma mark - UnifiedAssetFramework

BOOL PBLoadUnifiedAssets(void) {
    return dlopen(kUAFPath.fileSystemRepresentation, RTLD_NOW) != NULL;
}

static id PBConfigurationManager(void) {
    Class manager = NSClassFromString(@"UAFConfigurationManager");
    if (![manager respondsToSelector:@selector(defaultManager)]) return nil;
    return [manager defaultManager];
}

NSString *PBAssetType(NSString *assetSet) {
    id manager = PBConfigurationManager();
    if (![manager respondsToSelector:@selector(getAssetSet:)]) return nil;
    id set = [manager getAssetSet:assetSet];
    if (![set respondsToSelector:@selector(autoAssetType)]) return nil;
    id type = [set autoAssetType];
    return [type isKindOfClass:NSString.class] ? type : nil;
}

NSNumber *PBDownloadedFilesystemBytes(NSString *assetSet, NSError **error) {
    Class manager = NSClassFromString(@"UAFAutoAssetManager");
    if (![manager respondsToSelector:@selector(latestStatusForClients:error:)]) {
        PBSetError(error, 10, @"UAFAutoAssetManager +latestStatusForClients:error: is missing");
        return nil;
    }
    NSError *queryError = nil;
    id status = [manager latestStatusForClients:assetSet error:&queryError];
    if (queryError) {
        if (error) *error = queryError;
        return nil;
    }
    if (![status respondsToSelector:@selector(downloadedFilesystemBytes)]) {
        PBSetError(error, 11, @"asset status has no downloadedFilesystemBytes");
        return nil;
    }
    return @([status downloadedFilesystemBytes]);
}

NSDictionary *PBAssetInventory(NSError **error) {
    Class manager = NSClassFromString(@"UAFAssetSetManager");
    if (![manager respondsToSelector:@selector(generateInformationWithError:)]) {
        PBSetError(error, 12, @"UAFAssetSetManager +generateInformationWithError: is missing");
        return nil;
    }
    NSError *queryError = nil;
    id info = [manager generateInformationWithError:&queryError];
    if (queryError) {
        if (error) *error = queryError;
        return nil;
    }
    if ([info isKindOfClass:NSString.class]) {
        NSData *data = [info dataUsingEncoding:NSUTF8StringEncoding];
        info = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    }
    if ([info isKindOfClass:NSDictionary.class]) return info;
    if (error && !*error) PBSetError(error, 13, @"asset inventory has an unexpected shape");
    return nil;
}

static BOOL PBInterfaceAccepts(NSXPCInterface *interface, SEL selector) {
    Protocol *protocol = interface.protocol;
    if (protocol == NULL) return NO;
    // A proxy answers every selector, so the interface's protocol is what is checked.
    return protocol_getMethodDescription(protocol, selector, YES, YES).name != NULL ||
           protocol_getMethodDescription(protocol, selector, NO, YES).name != NULL;
}

BOOL PBSendAssetOperation(NSDictionary *config, NSTimeInterval timeout, NSError **error) {
    NSString *operation = config[@"Operation"];
    if (![operation isKindOfClass:NSString.class] || operation.length == 0) {
        PBSetError(error, 20, @"operation config has no Operation");
        return NO;
    }
    if ([operation isEqualToString:@"ResetAssetSets"]) {
        id sets = config[@"AssetSets"];
        if (![sets isKindOfClass:NSArray.class] || [sets count] == 0) {
            PBSetError(error, 21,
                       @"refusing ResetAssetSets with no AssetSets: the service reads that as every set");
            return NO;
        }
        for (id name in sets) {
            if (![name isKindOfClass:NSString.class] || [name length] == 0) {
                PBSetError(error, 21, @"refusing ResetAssetSets with a non-string or empty set name");
                return NO;
            }
        }
    }
    Class interfaceClass = NSClassFromString(@"UAFXPCProxyServiceInterface");
    if (![interfaceClass respondsToSelector:@selector(defaultInterface)]) {
        PBSetError(error, 22, @"UAFXPCProxyServiceInterface +defaultInterface is missing");
        return NO;
    }
    NSXPCInterface *interface = [interfaceClass defaultInterface];
    if (![interface isKindOfClass:NSXPCInterface.class]) {
        PBSetError(error, 22, @"defaultInterface did not return an NSXPCInterface");
        return NO;
    }
    SEL operationSelector = @selector(operationWithConfig:completion:);
    if (!PBInterfaceAccepts(interface, operationSelector)) {
        PBSetError(error, 23, @"the service interface no longer has operationWithConfig:completion:");
        return NO;
    }

    NSXPCConnection *connection =
        [[NSXPCConnection alloc] initWithMachServiceName:kService options:0];
    connection.remoteObjectInterface = interface;
    [connection resume];

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSError *replyError = nil;
    __block BOOL finished = NO;
    NSObject *lock = [NSObject new];
    void (^finish)(NSError *) = ^(NSError *e) {
        @synchronized(lock) {
            if (finished) return;
            finished = YES;
            replyError = e;
        }
        dispatch_semaphore_signal(done);
    };
    id proxy = [connection remoteObjectProxyWithErrorHandler:^(NSError *e) {
        finish(e ?: PBError(24, @"XPC transport error"));
    }];
    [proxy operationWithConfig:config completion:^(NSError *e) { finish(e); }];

    long waited = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
                                                              (int64_t)(timeout * NSEC_PER_SEC)));
    [connection invalidate];
    if (waited != 0) {
        PBSetError(error, 25, [NSString stringWithFormat:@"no reply from %@ in %.0f s; the request may still have run",
                                                         kService, timeout]);
        return NO;
    }
    if (replyError) {
        if (error) *error = replyError;
        return NO;
    }
    return YES;
}

id PBMakeSubscription(NSString *name, NSDictionary *assetSetUsages, NSDictionary *usageAliases,
                      NSError **error) {
    Class type = NSClassFromString(@"UAFAssetSetSubscription");
    if (type == Nil) {
        PBSetError(error, 30, @"UAFAssetSetSubscription is missing");
        return nil;
    }
    if (![type instancesRespondToSelector:@selector(initWithName:assetSets:usageAliases:)] ||
        ![type instancesRespondToSelector:@selector(isValid:error:)]) {
        PBSetError(error, 31, @"UAFAssetSetSubscription initializer or validator is missing");
        return nil;
    }
    if (![type conformsToProtocol:@protocol(NSSecureCoding)]) {
        PBSetError(error, 32, @"UAFAssetSetSubscription is not NSSecureCoding, so it cannot cross XPC");
        return nil;
    }
    id manager = PBConfigurationManager();
    if (manager == nil) {
        PBSetError(error, 33, @"UAFConfigurationManager +defaultManager is missing");
        return nil;
    }
    id subscription = [[type alloc] initWithName:name assetSets:assetSetUsages usageAliases:usageAliases];
    if (subscription == nil) {
        PBSetError(error, 34, @"UAFAssetSetSubscription returned nil");
        return nil;
    }
    NSError *validation = nil;
    BOOL valid = [subscription isValid:manager error:&validation];
    if (!valid || validation) {
        if (error) *error = validation ?: PBError(35, @"macOS rejected the subscription");
        return nil;
    }
    return subscription;
}

#pragma mark - CacheDelete

static void *cacheDeleteHandle = NULL;

BOOL PBLoadCacheDelete(void) {
    if (cacheDeleteHandle == NULL) {
        cacheDeleteHandle = dlopen(kCacheDeletePath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    }
    return cacheDeleteHandle != NULL;
}

typedef CFDictionaryRef (*PBSyncCall)(CFDictionaryRef info);
typedef void (*PBBlockCall)(CFDictionaryRef info, void (^reply)(CFDictionaryRef result));

static NSDictionary *PBCallCacheDelete(const char *symbolName, NSDictionary *info, PBCallStyle style,
                                       NSTimeInterval timeout, NSError **error) {
    if (!PBLoadCacheDelete()) {
        PBSetError(error, 40, @"CacheDelete.framework is missing");
        return nil;
    }
    void *symbol = dlsym(cacheDeleteHandle, symbolName);
    if (symbol == NULL) {
        PBSetError(error, 41, [NSString stringWithFormat:@"%s is missing from CacheDelete", symbolName]);
        return nil;
    }
    CFDictionaryRef request = (__bridge CFDictionaryRef)info;
    if (style == PBCallStyleSync) {
        CFDictionaryRef result = ((PBSyncCall)symbol)(request);
        if (result == NULL) {
            PBSetError(error, 42, [NSString stringWithFormat:@"%s returned NULL", symbolName]);
            return nil;
        }
        if (CFGetTypeID(result) != CFDictionaryGetTypeID()) {
            CFRelease(result);
            PBSetError(error, 43, [NSString stringWithFormat:@"%s did not return a dictionary", symbolName]);
            return nil;
        }
        // "Copy" in the name: the caller owns the result.
        return CFBridgingRelease(result);
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary *reply = nil;
    __block BOOL replied = NO;
    ((PBBlockCall)symbol)(request, ^(CFDictionaryRef result) {
        if (result != NULL && CFGetTypeID(result) == CFDictionaryGetTypeID()) {
            reply = [(__bridge NSDictionary *)result copy];
        }
        replied = YES;
        dispatch_semaphore_signal(done);
    });
    long waited = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,
                                                              (int64_t)(timeout * NSEC_PER_SEC)));
    if (waited != 0) {
        PBSetError(error, 44, [NSString stringWithFormat:@"%s gave no reply in %.0f s with the block call style",
                                                         symbolName, timeout]);
        return nil;
    }
    if (!replied || reply == nil) {
        PBSetError(error, 45, [NSString stringWithFormat:@"%s replied without a dictionary", symbolName]);
        return nil;
    }
    return reply;
}

NSDictionary *PBCacheDeletePurgeableSpace(NSDictionary *info, PBCallStyle style, NSTimeInterval timeout,
                                          NSError **error) {
    return PBCallCacheDelete("CacheDeleteCopyPurgeableSpaceWithInfo", info, style, timeout, error);
}

NSDictionary *PBCacheDeletePurgeSpace(NSDictionary *info, PBCallStyle style, NSTimeInterval timeout,
                                      NSError **error) {
    return PBCallCacheDelete("CacheDeletePurgeSpaceWithInfo", info, style, timeout, error);
}
