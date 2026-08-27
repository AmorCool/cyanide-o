//
//  BlockUpdatesViewController.h
//  Cyanide
//
//  Reconstructed from binary analysis of Cyanide 1.2.24 (Block Updates feature).
//  Lists installed apps and lets the user block/unblock App Store auto-updates
//  per app. The block list is persisted to the itunesstored preferences so it
//  survives resprings.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Block / unblock App Store automatic updates for installed apps.
@interface BlockUpdatesViewController : UITableViewController <UISearchResultsUpdating>

// All installed apps.
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *apps;
// Filtered view (search active).
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *filteredApps;
// Bundle ids currently queued to be blocked (uncommitted).
@property (nonatomic, strong, nullable) NSMutableSet<NSString *> *waitingApps;
@property (nonatomic, strong, nullable) UISearchController *searchController;
@property (nonatomic, assign) BOOL isFiltering;
// When pushed from AppList, preselect this bundle so the user can commit it
// directly (or unblock it) without tapping.
@property (nonatomic, copy, nullable) NSString *preselectedBundleID;

- (void)loadApps;
- (void)commitUpdates;
- (void)handleRefresh:(UIRefreshControl *)refreshControl;

@end

NS_ASSUME_NONNULL_END
