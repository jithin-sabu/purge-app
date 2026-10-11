#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Private Apple interfaces, every one of them looked up at run time and failing
// closed when a class, selector or symbol is missing. None of these are called
// from the aimodels parent process: they run in a throwaway `__worker` child,
// so a changed ABI crashes that child and not the tool (purge-app#133).
//
// UnifiedAssetFramework and com.apple.siri.uaf.subscription.service were mapped
// by pared (github.com/4evy/pared, MIT); the simpler ObjC lookup style follows
// RemoveMacAI (github.com/omlahore/RemoveMacAI, MIT).

#pragma mark - UnifiedAssetFramework

/// Loads the framework. NO when it is missing on this macOS.
BOOL PBLoadUnifiedAssets(void);

/// The MobileAsset type macOS maps an asset set to, or nil when the set or the
/// configuration interface is unknown. Used to confirm the catalog still matches
/// this macOS before anything is sent.
NSString *_Nullable PBAssetType(NSString *assetSet);

/// Bytes the asset service says are on disk for a set, or nil when the status
/// interface is missing. RemoveMacAI found this can read 0 for installed sets,
/// so it is a cross-check, not the measurement.
NSNumber *_Nullable PBDownloadedFilesystemBytes(NSString *assetSet,
                                                NSError *_Nullable *_Nullable error);

/// The service's own inventory (`SystemAssets` records with metadata), or nil.
NSDictionary *_Nullable PBAssetInventory(NSError *_Nullable *_Nullable error);

/// Sends one operation to the subscription service and waits up to `timeout`
/// for its reply. `config` carries "Operation" and its arguments.
/// A ResetAssetSets whose AssetSets is missing or empty is refused here, before
/// any connection is made: the service reads an empty list as every set.
/// Returns NO with `error` set on refusal, a missing interface, a transport
/// error, a timeout, or an error reply.
BOOL PBSendAssetOperation(NSDictionary *config, NSTimeInterval timeout,
                          NSError *_Nullable *_Nullable error);

/// Builds a UAFAssetSetSubscription for a Subscribe operation and validates it
/// against the configuration manager. Nil with `error` when the class, its
/// initializer or validator is missing, or when macOS rejects the request.
id _Nullable PBMakeSubscription(NSString *name, NSDictionary *assetSetUsages,
                                NSDictionary *usageAliases,
                                NSError *_Nullable *_Nullable error);

#pragma mark - CacheDelete

/// Loads the CacheDelete framework. NO when it is missing.
BOOL PBLoadCacheDelete(void);

/// How a CacheDelete function is called. Neither form is documented; the spike
/// records which one this macOS answers.
typedef NS_ENUM(NSInteger, PBCallStyle) {
    /// `CFDictionaryRef f(CFDictionaryRef info)`: synchronous, caller owns the result.
    PBCallStyleSync = 0,
    /// `void f(CFDictionaryRef info, void (^reply)(CFDictionaryRef))`: the shape
    /// BrainLayer derived from DeviceLink's `_DLPurgeDiskSpaceOnComputer`.
    PBCallStyleBlock = 1,
};

/// `CacheDeleteCopyPurgeableSpaceWithInfo`: read-only. Returns the reply
/// dictionary, or nil with `error` when the symbol is missing, the call style
/// gave no reply within `timeout`, or the reply is not a dictionary.
NSDictionary *_Nullable PBCacheDeletePurgeableSpace(NSDictionary *info, PBCallStyle style,
                                                    NSTimeInterval timeout,
                                                    NSError *_Nullable *_Nullable error);

/// `CacheDeletePurgeSpaceWithInfo`: asks `deleted` to purge now. Same contract
/// as the purgeable query. The caller is responsible for the service filter in
/// `info`; nothing here adds or checks one.
NSDictionary *_Nullable PBCacheDeletePurgeSpace(NSDictionary *info, PBCallStyle style,
                                                NSTimeInterval timeout,
                                                NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
