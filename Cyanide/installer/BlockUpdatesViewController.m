//
//  BlockUpdatesViewController.m
//  Cyanide
//
//  Reconstructed from binary analysis of Cyanide 1.2.24 (Block Updates feature).
//
//  Behavior recovered from the binary:
//    - loadApps lists installed apps (original used mobile_installation_proxy;
//      this rebuild uses LSApplicationWorkspace for the same result).
//    - waitingApps holds bundle ids the user has toggled.
//    - commitUpdates persists the blocked list and logs
//      "[OK] Blocked updates for: %s" / "[OK] Unblocked updates for: %s".
//
//  This rebuild persists the blocked bundle-ids to itunesstored preferences
//  (com.apple.MobileStore.plist, key "CyanideBlockedUpdates") and notifies
//  cfprefsd so the change survives until a respring.
//

#import "BlockUpdatesViewController.h"
#import "InstalledAppEnumerator.h"
#import "../SettingsViewController.h"
#import "../LogTextView.h"
#import <notify.h>

#pragma mark - Constants

static NSString * const kBlockUpdatesCellID      = @"BlockUpdatesCell";
static NSString * const kBlockedUpdatesKey       = @"CyanideBlockedUpdates";
static NSString * const kMobileStorePreferencesPath =
    @"/var/mobile/Library/Preferences/com.apple.MobileStore.plist";

#pragma mark - Implementation

@interface BlockUpdatesViewController ()
- (NSSet<NSString *> *)readBlockedApps;
- (void)writeBlockedApps:(NSSet<NSString *> *)blocked;
- (void)refreshBlockedState;
- (void)configureSearchController;
- (void)configureTableView;
@end

@implementation BlockUpdatesViewController

#pragma mark - Lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.title = @"Block Updates";
    self.waitingApps = [NSMutableSet set];

    [self configureSearchController];
    [self configureTableView];

    UIBarButtonItem *commit = [[UIBarButtonItem alloc]
        initWithTitle:@"Commit"
                style:UIBarButtonItemStyleDone
               target:self
               action:@selector(commitUpdates)];
    self.navigationItem.rightBarButtonItem = commit;

    [self loadApps];
}

- (void)configureSearchController
{
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Search Apps";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
}

- (void)configureTableView
{
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.allowsMultipleSelection = YES;
    self.tableView.tableFooterView = [UIView new];
    [self.tableView registerClass:[UITableViewCell class]
           forCellReuseIdentifier:kBlockUpdatesCellID];

    UIRefreshControl *rc = [[UIRefreshControl alloc] init];
    [rc addTarget:self action:@selector(handleRefresh:) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = rc;
}

#pragma mark - App enumeration

- (void)loadApps
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
        // Shared MIP-first enumerator (same fix as App Downgrade): the
        // original binary used mobile_installation_proxy; the LSApplicationWorkspace
        // in-app call returns empty on iOS 17+.
        NSArray<InstalledApp *> *installed = InstalledAppEnumeratorList();
        for (InstalledApp *ia in installed) {
            if (!ia.bundleID.length) continue;
            [result addObject:@{
                @"bundleID": ia.bundleID,
                @"name": ia.name.length ? ia.name : ia.bundleID,
                @"version": ia.version.length ? ia.version : @"",
            }];
        }
        [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.apps = result;
            self.filteredApps = result;
            [self refreshBlockedState];
            // Preselect when pushed from AppList so the user can commit/unblock
            // the chosen app in one step.
            if (self.preselectedBundleID.length) {
                [self.waitingApps addObject:self.preselectedBundleID];
                self.preselectedBundleID = nil;
            }
            [self.tableView reloadData];
        });
    });
}

- (void)handleRefresh:(UIRefreshControl *)refreshControl
{
    [self loadApps];
    [refreshControl endRefreshing];
}

#pragma mark - Blocked-state persistence

- (NSSet<NSString *> *)readBlockedApps
{
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:kMobileStorePreferencesPath];
    NSArray *arr = plist[kBlockedUpdatesKey];
    if (![arr isKindOfClass:NSArray.class]) return [NSSet set];
    return [NSSet setWithArray:arr];
}

- (BOOL)writeBlockedApps:(NSSet<NSString *> *)blocked
{
    // Read-modify-write the itunesstored preferences file.
    NSMutableDictionary *plist = [NSMutableDictionary
        dictionaryWithContentsOfFile:kMobileStorePreferencesPath];
    if (!plist) plist = [NSMutableDictionary dictionary];
    plist[kBlockedUpdatesKey] = [blocked.allObjects sortedArrayUsingSelector:@selector(compare:)];
    BOOL ok = [plist writeToFile:kMobileStorePreferencesPath atomically:YES];
    if (!ok) {
        log_user("[BLOCKUPDATES] ERROR: writeToFile failed for %s (sandbox/permission?).\n",
                 kMobileStorePreferencesPath.UTF8String);
    }
    return ok;
}

- (void)refreshBlockedState
{
    NSSet<NSString *> *blocked = [self readBlockedApps];
    [self.waitingApps removeAllObjects];
    for (NSDictionary *app in self.apps) {
        if ([blocked containsObject:app[@"bundleID"]]) {
            [self.waitingApps addObject:app[@"bundleID"]];
        }
    }
}

#pragma mark - Search

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    NSString *text = searchController.searchBar.text;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        self.isFiltering = NO;
        self.filteredApps = self.apps;
        [self.tableView reloadData];
        return;
    }
    self.isFiltering = YES;
    self.filteredApps = [self.apps filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSDictionary *app, NSDictionary *bindings) {
            return [app[@"name"] localizedCaseInsensitiveContainsString:trimmed] ||
                   [app[@"bundleID"] localizedCaseInsensitiveContainsString:trimmed];
        }]];
    [self.tableView reloadData];
}

#pragma mark - Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    NSArray<NSDictionary *> *source = self.isFiltering ? self.filteredApps : self.apps;
    return (NSInteger)source.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (self.isFiltering) return nil;
    return self.waitingApps.count
        ? [NSString stringWithFormat:@"Blocked (%lu app%@)", (unsigned long)self.waitingApps.count,
           self.waitingApps.count == 1 ? @"" : @"s"]
        : @"Tap apps to block their App Store updates";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kBlockUpdatesCellID
                                                            forIndexPath:indexPath];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:kBlockUpdatesCellID];
    }
    NSArray<NSDictionary *> *source = self.isFiltering ? self.filteredApps : self.apps;
    if (indexPath.row >= (NSInteger)source.count) return cell;
    NSDictionary *app = source[indexPath.row];
    NSString *bundleID = app[@"bundleID"];
    cell.textLabel.text = app[@"name"];
    cell.detailTextLabel.text = bundleID;
    cell.imageView.image = [UIImage systemImageNamed:@"app"];
    BOOL blocked = [self.waitingApps containsObject:bundleID];
    cell.accessoryType = blocked ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.textLabel.textColor = blocked ? UIColor.systemBlueColor : UIColor.labelColor;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray<NSDictionary *> *source = self.isFiltering ? self.filteredApps : self.apps;
    if (indexPath.row >= (NSInteger)source.count) return;
    NSString *bundleID = source[indexPath.row][@"bundleID"];
    if ([self.waitingApps containsObject:bundleID]) {
        [self.waitingApps removeObject:bundleID];
    } else {
        [self.waitingApps addObject:bundleID];
    }
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
                  withRowAnimation:UITableViewRowAnimationAutomatic];
}

#pragma mark - Commit

- (void)commitUpdates
{
    NSSet<NSString *> *previous = [self readBlockedApps];
    NSSet<NSString *> *next = [NSSet setWithSet:self.waitingApps];

    // Determine per-app changes for logging.
    NSMutableSet<NSString *> *added   = [next mutableCopy];
    [added minusSet:previous];
    NSMutableSet<NSString *> *removed = [previous mutableCopy];
    [removed minusSet:next];

    BOOL wrote = [self writeBlockedApps:next];
    if (!wrote) {
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"Block Updates Failed"
                             message:[NSString stringWithFormat:
                                 @"Could not write the blocked-app list to:\n%@\n\n"
                                 @"The app runs sandboxed and this path may be read-only on your "
                                 @"device. Check the Log tab for details.",
                                 kMobileStorePreferencesPath]
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }
    // Ask cfprefsd to reload the preference file.
    notify_post("com.apple.MobileStore.prefsChanged");
    // Also wake the iTunes Store daemon so it re-reads prefs without requiring
    // a respring/reboot — iTunes Store caches preference values at launch.
    // (No-op on older iOS versions that don't define the notification.)
    notify_post("com.apple.itunesstored.foregroundPrefChange");

    for (NSString *b in added) {
        log_user("[OK] Blocked updates for: %s\n", b.UTF8String);
    }
    for (NSString *b in removed) {
        log_user("[OK] Unblocked updates for: %s\n", b.UTF8String);
    }
    log_user("[BLOCKUPDATES] Wrote %lu blocked bundle id(s) to %s. A respring/reboot is required for App Store to fully honor the change.\n",
             (unsigned long)next.count, kMobileStorePreferencesPath.UTF8String);

    [self.tableView reloadData];

    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Block Updates"
                         message:[NSString stringWithFormat:
                             @"Blocked %lu app(s), unblocked %lu app(s).\n\nFor best results, force-quit App Store (swipe up from app switcher) or respring. Cyanide notifies the iTunes Store daemon to re-read preferences, but App Store caches them at launch.",
                             (unsigned long)added.count, (unsigned long)removed.count]
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end
