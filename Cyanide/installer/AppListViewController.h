//
//  AppListViewController.h
//  Cyanide
//
//  Reconstructed from binary analysis of Cyanide 1.2.24 (App Downgrade feature).
//  Hosts the installed-app list, App Store search and the App Downgrade flow.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A lightweight value object describing an installed app / an App Store result.
@interface AppInfo : NSObject

@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy, nullable) NSString *trackID;   // resolved App Store track id (string)
@property (nonatomic, copy, nullable) NSString *storeLink; // pasted "https://apps.apple.com/..." link
@property (nonatomic, strong, nullable) UIImage *icon;

@end

/// The App list screen reached from Settings → Quick Actions → "App Downgrade".
/// Lists installed apps, offers App Store search (install directly) and the
/// downgrade flow: trackID resolution → version history → StoreKitUI injection.
@interface AppListViewController : UITableViewController <UISearchResultsUpdating>

// Installed / resolved apps shown in the table.
@property (nonatomic, copy, nullable) NSArray<AppInfo *> *apps;
// App Store search results (search controller mode).
@property (nonatomic, copy, nullable) NSArray<AppInfo *> *appStoreResults;
@property (nonatomic, copy, nullable) NSArray<AppInfo *> *filteredApps;
@property (nonatomic, strong, nullable) NSURLSessionDataTask *currentSearchTask;
@property (nonatomic, strong, nullable) NSCache<NSString *, UIImage *> *imageCache;
@property (nonatomic, strong, nullable) UISearchController *searchController;
@property (nonatomic, assign) BOOL isFiltering;

- (void)loadApps;
- (void)forceRefreshApps;

@end

NS_ASSUME_NONNULL_END
