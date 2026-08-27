//
//  InstalledAppEnumerator.h
//  Cyanide
//
//  Shared "list installed apps" helper for AppListViewController (App Downgrade)
//  and BlockUpdatesViewController.
//
//  The original Cyanide 1.2.24 binary enumerated installed apps through
//  mobile_installation_proxy (MIP); the first reconstruction used the private
//  LSApplicationWorkspace API directly in the app process, which returns an
//  EMPTY list on iOS 17+ when called from a non-SpringBoard process. This
//  helper restores the MIP-based path (primary) with an LSApplicationWorkspace
//  fallback, plus a KRW readiness check so the user gets a diagnosable log
//  instead of a silent empty table.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One installed app, matching what the MIP "Lookup" returns.
@interface InstalledApp : NSObject
@property (nonatomic, copy, nullable) NSString *bundleID;
@property (nonatomic, copy, nullable) NSString *name;
@property (nonatomic, copy, nullable) NSString *version;
@end

/// Returns installed user apps sorted by localized name.
/// Uses mobile_installation_proxy (XPC) first, then falls back to
/// LSApplicationWorkspace. Never returns nil.
NSArray<InstalledApp *> *InstalledAppEnumeratorList(void);

NS_ASSUME_NONNULL_END
