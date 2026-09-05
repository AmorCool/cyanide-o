//
//  BlockUpdatesViewController.h
//  Blocks App Store OTA updates for selected apps by planting a
// `com.apple.mobileinstallation.placeholder` file inside each app bundle via
// the SpringBoard RemoteCall session (mkdir -p + touch + chmod 0555).
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface BlockUpdatesViewController : UITableViewController <UISearchResultsUpdating>

- (void)loadApps;

@end

NS_ASSUME_NONNULL_END
