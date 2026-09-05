//
//  AppListViewController.h
//  Lists every user-installed app and drives the App Store downgrade flow:
//  resolve bundle ID -> track ID, pull the historical version list, then ask
//  SpringBoard to purchase the chosen AppExtVrsId (see tweaks/appdowngrade.h).
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AppListViewController : UITableViewController <UISearchResultsUpdating>

- (void)loadApps;

@end

NS_ASSUME_NONNULL_END
