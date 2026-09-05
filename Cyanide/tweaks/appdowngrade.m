//
//  appdowngrade.m
//  SpringBoard-side implementation of the App Downgrade feature.
//
//  Flow (mirrors the StoreKitUI purchase path App Store itself uses):
//    1. Acquire kernel primitives + an open SpringBoard RemoteCall session.
//    2. Consume the sandbox extension in SpringBoard (escape_sbx_demo2_in_session).
//    3. dlopen /System/Library/PrivateFrameworks/StoreKitUI.framework in
//       SpringBoard via remote malloc/dlopen.
//    4. Build the remote objects:
//         buyParams = "productType=C&price=0&salableAdamId=<trackID>"
//                     "&pricingParameters=pricingParameter&appExtVrsId=<versionId>"
//                     "&clientBuyId=1&installed=0&trolled=1"
//         offer  = [[SKUIItemOffer alloc] initWithLookupDictionary:@{
//                      @"buyParams": buyParams }]
//         item   = [[SKUIItem alloc] initWithLookupDictionary:@{
//                      @"_itemOffer": trackID }]
//         [item setValue:offer forKey:@"_itemOffer"];
//         [item setValue:@"iosSoftware" forKey:@"_itemKindString"];
//         [item setValue:@(versionId) forKey:@"_versionIdentifier"];
//    5. purchases = [[SKUIItemStateCenter defaultCenter]
//           _newPurchasesWithItems:@[ item ]];
//       [center _performPurchases:purchases hasBundlePurchase:NO
//           withClientContext:[SKUIClientContext defaultContext]
//           completionBlock:NULL];
//
//  Every objc operation executes inside SpringBoard through
//  do_remote_call_stable(..., "objc_msgSend", ...); string literals are
//  mirrored into SpringBoard with downgrade_remote_alloc_str().
//
//  Locking: settings_rc_lock() returns the lock object; the whole session
//  runs inside @synchronized so every exit path (success and the three
//  failure bail-outs) releases it — the same enter/exit pairing the shipped
//  binary carries.
//

#import "appdowngrade.h"

#import <dlfcn.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <string.h>

#import "../TaskRop/RemoteCall.h"
#import "../LogTextView.h"

// Exported by the mod build (the upstream source keeps these static inside
// SettingsViewController.m — they were de-static'd so tweak payloads can
// reuse the shared kernel/session plumbing).
extern BOOL settings_ensure_kexploit(void);
extern NSObject *settings_rc_lock(void);
extern BOOL settings_ensure_springboard_remote_call_locked(void);

// From ViewController.m — consumes the sandbox extension held by the current
// RemoteCall session so the SpringBoard-side work can touch app containers.
extern int escape_sbx_demo2_in_session(void);

// Remote-call timeout used across this payload (matches the binary's 0x3e8).
static const int kDowngradeRCTimeout = 1000;

// StoreKitUI private framework path inside SpringBoard's mount namespace.
static const char *kStoreKitUIPath =
    "/System/Library/PrivateFrameworks/StoreKitUI.framework/StoreKitUI";

// dlopen flags used by the binary: RTLD_LAZY (1) | RTLD_NOLOAD (8) = 9 —
// the framework is already resident in SpringBoard; this only resolves the
// handle, which is why a return of 0 means "not loaded yet".
static const int kStoreKitUIDLOpenFlags = 9;

// Purchase parameters App Store's own "buy" flow posts for a free app.
// appExtVrsId selects the historical build; trolled=1 skips the server-side
// compatibility gate so old builds stay installable on newer iOS.
static NSString * const kBuyParamsFormat =
    @"productType=C&price=0&salableAdamId=%lld&pricingParameters=pricingParameter"
    @"&appExtVrsId=%lld&clientBuyId=1&installed=0&trolled=1";

// Allocate a C string inside SpringBoard and copy `s` into it. Returns the
// remote pointer, or 0 on failure. Caller frees with downgrade_remote_free().
static uint64_t downgrade_remote_alloc_str(const char *s)
{
    if (!s) return 0;
    uint64_t remote = do_remote_call_stable(kDowngradeRCTimeout, "malloc",
                                            strlen(s) + 1, 0, 0, 0, 0, 0, 0, 0);
    if (remote) {
        remote_write(remote, s, strlen(s) + 1);
    }
    return remote;
}

static void downgrade_remote_free(uint64_t ptr)
{
    if (ptr) {
        do_remote_call_stable(kDowngradeRCTimeout, "free", ptr, 0, 0, 0, 0, 0, 0, 0);
    }
}

// Remote objc runtime lookups. The class/selector name is mirrored into
// SpringBoard first, then objc_getClass/sel_registerName run there so the
// returned pointers are valid inside the target process.
static uint64_t downgrade_remote_objc_getClass(const char *name)
{
    uint64_t remote = downgrade_remote_alloc_str(name);
    if (!remote) return 0;
    uint64_t cls = do_remote_call_stable(kDowngradeRCTimeout, "objc_getClass",
                                         remote, 0, 0, 0, 0, 0, 0, 0);
    downgrade_remote_free(remote);
    return cls;
}

static uint64_t downgrade_remote_sel_registerName(const char *name)
{
    uint64_t remote = downgrade_remote_alloc_str(name);
    if (!remote) return 0;
    uint64_t sel = do_remote_call_stable(kDowngradeRCTimeout, "sel_registerName",
                                         remote, 0, 0, 0, 0, 0, 0, 0);
    downgrade_remote_free(remote);
    return sel;
}

// objc_msgSend inside SpringBoard: (receiver, sel, a0, a1).
#define REMOTE_MSG(obj, sel, a0, a1) \
    do_remote_call_stable(kDowngradeRCTimeout, "objc_msgSend", \
                          (uint64_t)(obj), (uint64_t)(sel), \
                          (uint64_t)(a0), (uint64_t)(a1), 0, 0, 0, 0)

#define REMOTE_MSG0(obj, sel) \
    do_remote_call_stable(kDowngradeRCTimeout, "objc_msgSend", \
                          (uint64_t)(obj), (uint64_t)(sel), 0, 0, 0, 0, 0, 0)

// Free the mirrored literals on every exit path.
static void downgrade_free_literals(uint64_t a, uint64_t b, uint64_t c, uint64_t d,
                                    uint64_t e, uint64_t f, uint64_t g)
{
    downgrade_remote_free(a);
    downgrade_remote_free(b);
    downgrade_remote_free(c);
    downgrade_remote_free(d);
    downgrade_remote_free(e);
    downgrade_remote_free(f);
    downgrade_remote_free(g);
}

void downgrade_trigger_in_springboard(NSString *trackID, NSString *versionId)
{
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        log_session_begin();

        long long trackIDValue = [trackID longLongValue];
        long long versionIdValue = [versionId longLongValue];
        log_user("[DOWNGRADE] Requesting downgrade (Track: %lld, Version: %lld)...\n",
                 trackIDValue, versionIdValue);

        if (!settings_ensure_kexploit()) {
            log_user("[DOWNGRADE] Failed: kernel primitives not acquired.\n");
            log_session_end();
            return;
        }

        // One lock object for the whole SpringBoard session; @synchronized
        // mirrors the binary's objc_sync_enter/objc_sync_exit pairing on
        // every path, so a failed downgrade never wedges the tweak lock.
        @synchronized (settings_rc_lock()) {
            if (!settings_ensure_springboard_remote_call_locked()) {
                log_user("[DOWNGRADE] Failed to attach to SpringBoard.\n");
                log_session_end();
                return;
            }

            if (!escape_sbx_demo2_in_session()) {
                log_user("[WARN] Sandbox escape failed or already active (%d).\n", 0);
            } else {
                log_user("[DOWNGRADE] Sandbox extension consumed by SpringBoard.\n");
            }

            log_user("[DOWNGRADE] Loading StoreKitUI framework into SpringBoard...\n");

            uint64_t remotePath = downgrade_remote_alloc_str(kStoreKitUIPath);
            if (!remotePath) {
                log_user("[DOWNGRADE] ERROR: Failed to allocate memory in SpringBoard.\n");
                log_session_end();
                return;
            }

            uint64_t handle = do_remote_call_stable(kDowngradeRCTimeout, "dlopen",
                                                    remotePath, kStoreKitUIDLOpenFlags,
                                                    0, 0, 0, 0, 0, 0);
            downgrade_remote_free(remotePath);
            if (!handle) {
                log_user("[DOWNGRADE] ERROR: SpringBoard failed to dlopen StoreKitUI.\n");
                log_session_end();
                return;
            }

            log_user("[DOWNGRADE] Constructing SKUI objects...\n");

            // Mirror every literal the purchase flow needs into SpringBoard memory.
            NSString *adamIdStr = [NSString stringWithFormat:@"%lld", trackIDValue];
            NSString *buyParamsStr = [NSString stringWithFormat:kBuyParamsFormat,
                                      trackIDValue, versionIdValue];

            uint64_t remoteAdamId = downgrade_remote_alloc_str(adamIdStr.UTF8String);
            uint64_t remoteBuy    = downgrade_remote_alloc_str(buyParamsStr.UTF8String);
            uint64_t remoteIOS    = downgrade_remote_alloc_str("iosSoftware");
            uint64_t remoteKey    = downgrade_remote_alloc_str("buyParams");
            uint64_t remoteOffer  = downgrade_remote_alloc_str("_itemOffer");
            uint64_t remoteKind   = downgrade_remote_alloc_str("_itemKindString");
            uint64_t remoteVer    = downgrade_remote_alloc_str("_versionIdentifier");
            if (!remoteAdamId || !remoteBuy || !remoteIOS || !remoteKey ||
                !remoteOffer || !remoteKind || !remoteVer) {
                log_user("[DOWNGRADE] ERROR: Failed to allocate memory in SpringBoard.\n");
                downgrade_free_literals(remoteAdamId, remoteBuy, remoteIOS, remoteKey,
                                        remoteOffer, remoteKind, remoteVer);
                log_session_end();
                return;
            }

            uint64_t nsStringCls = downgrade_remote_objc_getClass("NSString");
            uint64_t selStrUTF8  = downgrade_remote_sel_registerName("stringWithUTF8String:");
            if (!nsStringCls || !selStrUTF8) {
                log_user("[DOWNGRADE] ERROR: Failed to instantiate SKUI items.\n");
                downgrade_free_literals(remoteAdamId, remoteBuy, remoteIOS, remoteKey,
                                        remoteOffer, remoteKind, remoteVer);
                log_session_end();
                return;
            }

            uint64_t nsTrackID   = REMOTE_MSG(nsStringCls, selStrUTF8, remoteAdamId, 0);
            uint64_t nsBuyParams = REMOTE_MSG(nsStringCls, selStrUTF8, remoteBuy, 0);
            uint64_t nsIOS       = REMOTE_MSG(nsStringCls, selStrUTF8, remoteIOS, 0);
            uint64_t nsKeyBuy    = REMOTE_MSG(nsStringCls, selStrUTF8, remoteKey, 0);
            uint64_t nsKeyOffer  = REMOTE_MSG(nsStringCls, selStrUTF8, remoteOffer, 0);
            uint64_t nsKeyKind   = REMOTE_MSG(nsStringCls, selStrUTF8, remoteKind, 0);
            uint64_t nsKeyVer    = REMOTE_MSG(nsStringCls, selStrUTF8, remoteVer, 0);

            uint64_t nsVersion   = REMOTE_MSG(downgrade_remote_objc_getClass("NSNumber"),
                                              downgrade_remote_sel_registerName("numberWithLongLong:"),
                                              versionIdValue, 0);

            // buyParams dict feeds SKUIItemOffer; the item lookup dict mirrors
            // what the App Store lookup endpoint hands to SKUIItem.
            uint64_t selDictOFK  = downgrade_remote_sel_registerName("dictionaryWithObject:forKey:");
            uint64_t dictCls     = downgrade_remote_objc_getClass("NSDictionary");

            uint64_t buyDict  = REMOTE_MSG(dictCls, selDictOFK, nsBuyParams, nsKeyBuy);
            uint64_t itemDict = REMOTE_MSG(dictCls, selDictOFK, nsTrackID, nsKeyOffer);

            uint64_t selAlloc      = downgrade_remote_sel_registerName("alloc");
            uint64_t selInitLookup = downgrade_remote_sel_registerName("initWithLookupDictionary:");

            uint64_t offerCls = downgrade_remote_objc_getClass("SKUIItemOffer");
            uint64_t itemCls  = downgrade_remote_objc_getClass("SKUIItem");

            uint64_t offer = 0, item = 0;
            if (offerCls && itemCls && selAlloc && selInitLookup) {
                offer = REMOTE_MSG(REMOTE_MSG(offerCls, selAlloc, 0, 0), selInitLookup, buyDict, 0);
                item  = REMOTE_MSG(REMOTE_MSG(itemCls, selAlloc, 0, 0), selInitLookup, itemDict, 0);
            }
            if (!offer || !item) {
                log_user("[DOWNGRADE] ERROR: Failed to instantiate SKUI items.\n");
                downgrade_free_literals(remoteAdamId, remoteBuy, remoteIOS, remoteKey,
                                        remoteOffer, remoteKind, remoteVer);
                log_session_end();
                return;
            }

            uint64_t selSetValueForKey = downgrade_remote_sel_registerName("setValue:forKey:");
            REMOTE_MSG(item, selSetValueForKey, offer, nsKeyOffer);
            REMOTE_MSG(item, selSetValueForKey, nsIOS, nsKeyKind);
            REMOTE_MSG(item, selSetValueForKey, nsVersion, nsKeyVer);

            uint64_t clientContext = REMOTE_MSG0(downgrade_remote_objc_getClass("SKUIClientContext"),
                                                 downgrade_remote_sel_registerName("defaultContext"));
            uint64_t stateCenter   = REMOTE_MSG0(downgrade_remote_objc_getClass("SKUIItemStateCenter"),
                                                 downgrade_remote_sel_registerName("defaultCenter"));
            uint64_t items         = REMOTE_MSG(downgrade_remote_objc_getClass("NSArray"),
                                                downgrade_remote_sel_registerName("arrayWithObject:"),
                                                item, 0);
            uint64_t purchases     = REMOTE_MSG(stateCenter,
                                                downgrade_remote_sel_registerName("_newPurchasesWithItems:"),
                                                items, 0);

            log_user("[DOWNGRADE] Sending purchase request to App Store daemon...\n");
            REMOTE_MSG(stateCenter,
                       downgrade_remote_sel_registerName("_performPurchases:hasBundlePurchase:withClientContext:completionBlock:"),
                       purchases, 0, clientContext, 0);

            downgrade_free_literals(remoteAdamId, remoteBuy, remoteIOS, remoteKey,
                                    remoteOffer, remoteKind, remoteVer);
        }

        log_session_end();
    });
}
