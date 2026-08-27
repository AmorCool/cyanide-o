//
//  AppListViewController.m
//  Cyanide
//
//  Reconstructed from binary analysis of Cyanide 1.2.24 (App Downgrade feature).
//  The downgrade flow mirrors the original implementation:
//    1. Resolve the installed app's App Store track id (iTunes lookup, country fallback).
//    2. Fetch the full version history for that track id.
//    3. Let the user pick a version.
//    4. Drive a StoreKitUI purchase/download request inside SpringBoard via the
//       RemoteCall session (SKUIItemStateCenter _performPurchases:...).
//

#import "AppListViewController.h"
#import "BlockUpdatesViewController.h"
#import "InstalledAppEnumerator.h"
#import "../SettingsViewController.h"
#import "../LogTextView.h"
#import "../tweaks/remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import "../kexploit/kexploit_opa334.h"

// Forward declaration: defined further below (SpringBoard StoreKitUI injection
// section) but used by -executeCustomDowngradeWithAppInfo:versionId:. Without
// this, clang errors on an implicit declaration of a static function.
static BOOL downgrade_trigger_in_springboard(int64_t trackID, int64_t versionID);

#pragma mark - Constants (recovered from binary strings)

static NSString * const kAppListCellID = @"AppListCell";
static NSString * const kAppStoreSearchURLFormat  = @"https://itunes.apple.com/search?term=%@&entity=software&limit=25&country=%@";
static NSString * const kAppStoreLookupURLFormat  = @"https://itunes.apple.com/lookup?bundleId=%@&limit=1&media=software&country=%@";
static NSString * const kAppStoreLookupByIdFormat = @"https://itunes.apple.com/lookup?id=%@&country=%@";
static NSString * const kVersionHistoryURLFormat   = @"https://apis.bilin.eu.org/history/%lld";

static const int kAppListRCFirstExceptionTimeoutMS = 3000;

// StoreKitUI remote class names (injected into SpringBoard)
static NSString * const kSKUIItemClass          = @"SKUIItem";
static NSString * const kSKUIItemOfferClass     = @"SKUIItemOffer";
static NSString * const kSKUIClientContextClass = @"SKUIClientContext";
static NSString * const kSKUIItemStateCenterClass = @"SKUIItemStateCenter";
static NSString * const kSKUIStoreKitUIFrameworkPath =
    @"/System/Library/PrivateFrameworks/StoreKitUI.framework/StoreKitUI";

// Purchase trigger selector (recovered from binary strings)
static NSString * const kSKUIPerformPurchasesSelector =
    @"_performPurchases:hasBundlePurchase:withClientContext:completionBlock:";

#pragma mark - AppInfo

@implementation AppInfo
@end

#pragma mark - AppListViewController

@interface AppListViewController ()
// Private accessors mirroring the ObjC ivars recovered from the binary:
// _apps, _filteredApps, _appStoreResults, _currentSearchTask, _imageCache, _searchController
- (void)configureSearchController;
- (void)configureTableView;
- (void)presentActionSheetForApp:(AppInfo *)app tableView:(UITableView *)tableView indexPath:(NSIndexPath *)indexPath;

// Downgrade internals (mirror of recovered methods)
- (void)fetchDowngradeDataForApp:(AppInfo *)app;
- (void)executeFetchWithBundleId:(NSString *)bundleID
                         appInfo:(AppInfo *)app
                    loadingAlert:(UIAlertController *)loadingAlert;
- (NSArray<NSString *> *)downgrade_supportedAppStoreCountryCodes;
- (void)downgrade_fetchTrackIDForBundleID:(NSString *)bundleID
                               completion:(void (^)(NSNumber *trackID, NSError *error))completion;
- (void)downgrade_fetchTrackIDWithCountryCodes:(NSArray<NSString *> *)countryCodes
                                         index:(NSUInteger)index
                                       bundleId:(NSString *)bundleId
                                     completion:(void (^)(NSNumber *trackID, NSError *error))completion;
- (void)downgrade_fetchVersionsForTrackID:(NSNumber *)trackID
                               completion:(void (^)(NSArray<NSDictionary *> *versions, NSError *error))completion;
- (void)downgrade_presentVersionSelection:(NSNumber *)trackID appInfo:(AppInfo *)app versions:(NSArray<NSDictionary *> *)versions;
- (void)executeCustomDowngradeWithAppInfo:(AppInfo *)app versionId:(NSNumber *)versionId;
- (void)promptForCustomVersionForApp:(AppInfo *)app;
@end

@implementation AppListViewController

#pragma mark - Lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.title = @"Select App to Downgrade";

    self.imageCache = [[NSCache alloc] init];
    self.isFiltering = NO;

    [self configureSearchController];
    [self configureTableView];

    [self loadApps];
}

- (void)configureSearchController
{
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Search App or Paste App Store Link";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
}

- (void)configureTableView
{
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.tableFooterView = [UIView new];
    [self.tableView registerClass:[UITableViewCell class]
           forCellReuseIdentifier:kAppListCellID];
}

#pragma mark - Installed app enumeration

- (void)loadApps
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<AppInfo *> *installed = [self enumerateInstalledApps];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.apps = installed;
            self.filteredApps = installed;
            [self.tableView reloadData];
        });
    });
}

- (void)forceRefreshApps
{
    [self loadApps];
}

- (NSArray<AppInfo *> *)enumerateInstalledApps
{
    // Uses mobile_installation_proxy (MIP) via XPC — the same approach as the
    // original binary. On iOS 17+, the private LSApplicationWorkspace API
    // returns an empty list from a non-SpringBoard process, so it is only a
    // fallback inside InstalledAppEnumerator.
    NSMutableArray<AppInfo *> *result = [NSMutableArray array];

    NSArray<InstalledApp *> *installed = InstalledAppEnumeratorList();
    for (InstalledApp *ia in installed) {
        if (!ia.bundleID.length) continue;
        AppInfo *info = [AppInfo new];
        info.bundleID = ia.bundleID;
        info.name = ia.name.length ? ia.name : ia.bundleID;
        info.version = ia.version;
        [result addObject:info];
    }

    [result sortUsingComparator:^NSComparisonResult(AppInfo *a, AppInfo *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    return result;
}

#pragma mark - Search (UISearchResultsUpdating)

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    NSString *text = searchController.searchBar.text;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (trimmed.length == 0) {
        self.isFiltering = NO;
        self.filteredApps = self.apps;
        self.appStoreResults = nil;
        [self.currentSearchTask cancel];
        [self.tableView reloadData];
        return;
    }

    // A pasted App Store link? Extract the numeric app id.
    if ([trimmed hasPrefix:@"https://apps.apple.com/"] || [trimmed hasPrefix:@"http://apps.apple.com/"]) {
        [self handlePastedAppStoreLink:trimmed];
        return;
    }

    self.isFiltering = YES;
    NSArray<AppInfo *> *localMatches = [self.apps filteredArrayUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(AppInfo *app, NSDictionary *bindings) {
            return [app.name localizedCaseInsensitiveContainsString:trimmed] ||
                   [app.bundleID localizedCaseInsensitiveContainsString:trimmed];
        }]];
    self.filteredApps = localMatches;
    [self.tableView reloadData];

    // Also query the App Store for direct-install candidates.
    [self performAppStoreSearch:trimmed];
}

- (void)handlePastedAppStoreLink:(NSString *)link
{
    self.isFiltering = YES;
    NSRegularExpression *rx = [NSRegularExpression
        regularExpressionWithPattern:@"id(\\d+)"
                             options:0
                               error:nil];
    NSTextCheckingResult *m = [rx firstMatchInString:link options:0 range:NSMakeRange(0, link.length)];
    if (!m) return;

    NSString *appID = [link substringWithRange:[m rangeAtIndex:1]];
    [self lookupTrackIDByAppID:appID completion:^(NSNumber *trackID, NSError *error) {
        if (error || !trackID) return;
        AppInfo *remote = [AppInfo new];
        remote.trackID = trackID.stringValue;
        remote.storeLink = link;
        remote.name = link;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.appStoreResults = @[ remote ];
            self.filteredApps = @[ remote ];
            [self.tableView reloadData];
        });
    }];
}

- (void)performAppStoreSearch:(NSString *)term
{
    [self.currentSearchTask cancel];

    NSString *encoded = [term stringByAddingPercentEncodingWithAllowedCharacters:
                         [NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *country = self.downgrade_supportedAppStoreCountryCodes.firstObject ?: @"us";
    NSString *urlStr = [NSString stringWithFormat:kAppStoreSearchURLFormat, encoded, country];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 15;

    __weak typeof(self) weakSelf = self;
    self.currentSearchTask = [[NSURLSession sharedSession]
        dataTaskWithRequest:req
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (error || !data) return;

        NSError *jsonError = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![obj isKindOfClass:NSDictionary.class]) return;

        NSArray *results = obj[@"results"];
        NSMutableArray<AppInfo *> *items = [NSMutableArray array];
        for (NSDictionary *d in results) {
            AppInfo *info = [AppInfo new];
            info.name     = d[@"trackName"];
            info.bundleID = d[@"bundleId"];
            info.version  = d[@"version"];
            info.trackID  = [d[@"trackId"] stringValue];
            [items addObject:info];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf.appStoreResults = items;
            strongSelf.filteredApps = [items arrayByAddingObjectsFromArray:strongSelf.filteredApps ?: @[]];
            [strongSelf.tableView reloadData];
        });
    }];
    [self.currentSearchTask resume];
}

- (void)lookupTrackIDByAppID:(NSString *)appID
                  completion:(void (^)(NSNumber *trackID, NSError *error))completion
{
    NSString *country = self.downgrade_supportedAppStoreCountryCodes.firstObject ?: @"us";
    NSString *urlStr = [NSString stringWithFormat:kAppStoreLookupByIdFormat, appID, country];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 15;

    [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data) { completion(nil, err); return; }
        NSError *je = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&je];
        if (je || ![obj isKindOfClass:NSDictionary.class]) { completion(nil, je); return; }
        NSArray *results = obj[@"results"];
        if (![results isKindOfClass:NSArray.class] || results.count == 0) {
            completion(nil, [NSError errorWithDomain:@"AppList" code:404 userInfo:@{NSLocalizedDescriptionKey:@"App not found in supported App Store regions."}]);
            return;
        }
        NSDictionary *first = results.firstObject;
        completion(first[@"trackId"], nil);
    }].resume;
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.isFiltering ? (NSInteger)self.filteredApps.count : (NSInteger)self.apps.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (self.isFiltering) return nil;
    return @"Installed Apps";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kAppListCellID
                                                            forIndexPath:indexPath];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:kAppListCellID];
    }

    NSArray<AppInfo *> *source = self.isFiltering ? self.filteredApps : self.apps;
    if (indexPath.row >= (NSInteger)source.count) {
        cell.textLabel.text = @"";
        cell.detailTextLabel.text = @"";
        cell.imageView.image = nil;
        return cell;
    }
    AppInfo *app = source[indexPath.row];
    cell.textLabel.text = app.name;
    cell.detailTextLabel.text = app.bundleID.length ? app.bundleID : app.trackID;
    cell.imageView.image = app.icon ?: [UIImage systemImageNamed:@"app"];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    if (app.trackID) {
        // Already resolved: show the version string as the subtitle hint.
        cell.detailTextLabel.text = app.version.length
            ? [NSString stringWithFormat:@"%@ — v%@", app.bundleID, app.version]
            : app.bundleID;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray<AppInfo *> *source = self.isFiltering ? self.filteredApps : self.apps;
    if (indexPath.row >= (NSInteger)source.count) return;
    AppInfo *app = source[indexPath.row];
    [self presentActionSheetForApp:app tableView:tableView indexPath:indexPath];
}

#pragma mark - Actions

- (void)presentActionSheetForApp:(AppInfo *)app
                        tableView:(UITableView *)tableView
                        indexPath:(NSIndexPath *)indexPath
{
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:app.name
                         message:app.bundleID
                  preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"App Downgrade"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [weakSelf fetchDowngradeDataForApp:app];
    }]];

    if (!app.bundleID) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
        if (sheet.popoverPresentationController) {
            sheet.popoverPresentationController.sourceView = tableView;
            sheet.popoverPresentationController.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
        }
        [self presentViewController:sheet animated:YES completion:nil];
        return;
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"App Store Search (Install directly)"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        [weakSelf performAppStoreSearch:app.name];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Block Updates"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *a) {
        BlockUpdatesViewController *vc = [[BlockUpdatesViewController alloc] initWithStyle:UITableViewStylePlain];
        vc.preselectedBundleID = app.bundleID;
        [weakSelf.navigationController pushViewController:vc animated:YES];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = tableView;
        sheet.popoverPresentationController.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Downgrade flow

- (void)fetchDowngradeDataForApp:(AppInfo *)app
{
    if (app.trackID.length) {
        // Already have a track id: jump straight to version selection.
        NSNumber *trackID = @([app.trackID longLongValue]);
        __weak typeof(self) weakSelf = self;
        [self downgrade_fetchVersionsForTrackID:trackID
                                     completion:^(NSArray<NSDictionary *> *versions, NSError *error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIAlertController *ac = [UIAlertController
                        alertControllerWithTitle:@"Failed to get versions"
                                         message:error.localizedDescription
                                  preferredStyle:UIAlertControllerStyleAlert];
                    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    [strongSelf presentViewController:ac animated:YES completion:nil];
                });
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf downgrade_presentVersionSelection:trackID appInfo:app versions:versions];
            });
        }];
        return;
    }

    if (!app.bundleID.length) {
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"App Downgrade"
                             message:@"This app has no bundle identifier to resolve."
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    UIAlertController *loading = [UIAlertController
        alertControllerWithTitle:[NSString stringWithFormat:@"Fetching Track ID for %@...", app.name]
                         message:nil
                  preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.frame = CGRectMake(0, 0, 24, 24);
    [spinner startAnimating];
    loading.view.userInteractionEnabled = NO;
    [self presentViewController:loading animated:YES completion:nil];
    // Add the spinner after the alert appears so its view is in the hierarchy.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (loading.view.superview) {
            spinner.center = CGPointMake(loading.view.bounds.size.width / 2.0, 40);
            [loading.view addSubview:spinner];
        }
    });

    [self executeFetchWithBundleId:app.bundleID appInfo:app loadingAlert:loading];
}

- (void)executeFetchWithBundleId:(NSString *)bundleID
                         appInfo:(AppInfo *)app
                    loadingAlert:(UIAlertController *)loadingAlert
{
    __weak typeof(self) weakSelf = self;
    [self downgrade_fetchTrackIDForBundleID:bundleID completion:^(NSNumber *trackID, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (loadingAlert) {
                [loadingAlert dismissViewControllerAnimated:YES completion:nil];
            }
            if (error || !trackID) {
                UIAlertController *ac = [UIAlertController
                    alertControllerWithTitle:@"Could not fetch the Track ID for this app."
                                     message:error.localizedDescription
                              preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [strongSelf presentViewController:ac animated:YES completion:nil];
                return;
            }

            app.trackID = trackID.stringValue;
            [strongSelf downgrade_fetchVersionsForTrackID:trackID completion:^(NSArray<NSDictionary *> *versions, NSError *verr) {
                if (verr) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        UIAlertController *ac = [UIAlertController
                            alertControllerWithTitle:@"Failed to get versions"
                                             message:verr.localizedDescription
                                      preferredStyle:UIAlertControllerStyleAlert];
                        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                        [strongSelf presentViewController:ac animated:YES completion:nil];
                    });
                    return;
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    [strongSelf downgrade_presentVersionSelection:trackID appInfo:app versions:versions];
                });
            }];
        });
    }];
}

- (NSArray<NSString *> *)downgrade_supportedAppStoreCountryCodes
{
    return @[ @"us", @"gb", @"de", @"fr", @"jp", @"cn", @"kr", @"au", @"ca", @"hk", @"tw", @"nl", @"es", @"it", @"ru", @"br", @"in" ];
}

- (void)downgrade_fetchTrackIDForBundleID:(NSString *)bundleID
                               completion:(void (^)(NSNumber *trackID, NSError *error))completion
{
    [self downgrade_fetchTrackIDWithCountryCodes:self.downgrade_supportedAppStoreCountryCodes
                                           index:0
                                         bundleId:bundleID
                                       completion:completion];
}

- (void)downgrade_fetchTrackIDWithCountryCodes:(NSArray<NSString *> *)countryCodes
                                         index:(NSUInteger)index
                                       bundleId:(NSString *)bundleId
                                     completion:(void (^)(NSNumber *trackID, NSError *error))completion
{
    if (index >= countryCodes.count) {
        if (completion) {
            completion(nil, [NSError errorWithDomain:@"AppList" code:404
                                            userInfo:@{NSLocalizedDescriptionKey:@"App not found in supported App Store regions."}]);
        }
        return;
    }

    NSString *country = countryCodes[index];
    NSString *urlStr = [NSString stringWithFormat:kAppStoreLookupURLFormat,
                        [bundleId stringByAddingPercentEncodingWithAllowedCharacters:
                                   [NSCharacterSet URLQueryAllowedCharacterSet]], country];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 15;

    log_user("[DOWNGRADE] Looking up track id for %@ (%@)...\n", bundleId, country);

    __weak typeof(self) weakSelf = self;
    [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (err || !data) {
            [strongSelf downgrade_fetchTrackIDWithCountryCodes:countryCodes index:index + 1
                                                       bundleId:bundleId completion:completion];
            return;
        }
        NSError *je = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&je];
        if (je || ![obj isKindOfClass:NSDictionary.class]) {
            [strongSelf downgrade_fetchTrackIDWithCountryCodes:countryCodes index:index + 1
                                                       bundleId:bundleId completion:completion];
            return;
        }
        NSArray *results = obj[@"results"];
        if (![results isKindOfClass:NSArray.class] || results.count == 0) {
            [strongSelf downgrade_fetchTrackIDWithCountryCodes:countryCodes index:index + 1
                                                       bundleId:bundleId completion:completion];
            return;
        }
        NSDictionary *first = results.firstObject;
        if (completion) completion(first[@"trackId"], nil);
    }].resume;
}

- (void)downgrade_fetchVersionsForTrackID:(NSNumber *)trackID
                               completion:(void (^)(NSArray<NSDictionary *> *versions, NSError *error))completion
{
    long long tid = [trackID longLongValue];
    NSString *urlStr = [NSString stringWithFormat:kVersionHistoryURLFormat, tid];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 20;

    log_user("[DOWNGRADE] Looking up history for %lld...\n", tid);

    [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data) {
            if (completion) completion(nil, err ?: [NSError errorWithDomain:@"AppList" code:-1 userInfo:nil]);
            return;
        }
        NSError *je = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&je];
        if (je || ![obj isKindOfClass:NSDictionary.class]) {
            if (completion) completion(nil, je ?: [NSError errorWithDomain:@"AppList" code:-1 userInfo:nil]);
            return;
        }
        // The bilin.eu.org history API returns {code, msg, total, data:[...]};
        // older builds used a "results" array. Accept both.
        id raw = obj[@"data"];
        if (![raw isKindOfClass:NSArray.class]) raw = obj[@"results"];
        if (![raw isKindOfClass:NSArray.class] || [raw count] == 0) {
            if (completion) completion(@[], [NSError errorWithDomain:@"AppList" code:404
                                                            userInfo:@{NSLocalizedDescriptionKey:@"No historical versions found."}]);
            return;
        }
        // Each entry carries {"bundle_version": "...", "external_identifier": <versionId>, ...}.
        NSMutableArray<NSDictionary *> *versions = [NSMutableArray array];
        for (NSDictionary *entry in raw) {
            NSMutableDictionary *v = [NSMutableDictionary dictionary];
            v[@"version"] = entry[@"bundle_version"] ?: entry[@"AppVersion"];
            v[@"versionId"] = entry[@"external_identifier"] ?: entry[@"versionId"] ?: entry[@"trackId"];
            v[@"trackId"] = trackID;
            [versions addObject:v];
        }
        // Newest first.
        [versions sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSString *va = a[@"version"] ?: @"";
            NSString *vb = b[@"version"] ?: @"";
            return [vb compare:va options:NSNumericSearch];
        }];
        if (completion) completion(versions, nil);
    }].resume;
}

- (void)downgrade_presentVersionSelection:(NSNumber *)trackID
                                  appInfo:(AppInfo *)app
                                 versions:(NSArray<NSDictionary *> *)versions
{
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Select Version"
                         message:@"Choose a version to downgrade to"
                  preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;
    for (NSDictionary *v in versions) {
        NSString *version = v[@"version"] ?: @"?";
        NSNumber *versionId = v[@"versionId"] ?: v[@"trackId"] ?: trackID;

        [ac addAction:[UIAlertAction actionWithTitle:version
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *a) {
            [weakSelf executeCustomDowngradeWithAppInfo:app versionId:versionId];
        }]];
    }

    [ac addAction:[UIAlertAction actionWithTitle:@"Custom Version ID"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
        [weakSelf promptForCustomVersionForApp:app];
    }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                           style:UIAlertActionStyleCancel
                                         handler:nil]];

    if (ac.popoverPresentationController) {
        ac.popoverPresentationController.sourceView = self.view;
        ac.popoverPresentationController.sourceRect = self.view.bounds;
    }
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)promptForCustomVersionForApp:(AppInfo *)app
{
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Custom Version ID"
                         message:@"Enter the App Store version ID (versionId) to downgrade to."
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Version ID";
        tf.keyboardType = UIKeyboardTypeNumberPad;
    }];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Downgrade" style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
        NSString *text = ac.textFields.firstObject.text ?: @"";
        NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSNumber *vid = trimmed.length ? @([trimmed longLongValue]) : nil;
        if (vid) [weakSelf executeCustomDowngradeWithAppInfo:app versionId:vid];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)executeCustomDowngradeWithAppInfo:(AppInfo *)app versionId:(NSNumber *)versionId
{
    log_user("[DOWNGRADE] Requesting downgrade (Track: %lld, Version: %lld)...\n",
             [app.trackID longLongValue], [versionId longLongValue]);

    // Bring up the kernel exploit (KRW) if it isn't already live. This mirrors
    // how every other KRW-dependent action in Settings establishes the session
    // before use, so App Downgrade works even when opened directly without
    // first visiting the Settings exploit panel.
    if (!settings_ensure_kexploit()) {
        log_user("[DOWNGRADE] ERROR: failed to bring up the kernel exploit (KRW).\n");
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"KRW Not Ready"
                             message:@"The kernel exploit (KRW) could not be started.\n\n"
                                     @"Open Settings and run the exploit first, then try the "
                                     @"downgrade again. Check the Log tab for details."
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    UIAlertController *progress = [UIAlertController
        alertControllerWithTitle:@"App Downgrade"
                         message:@"Sending purchase request to App Store daemon..."
                  preferredStyle:UIAlertControllerStyleAlert];
    [progress addAction:[UIAlertAction actionWithTitle:@"Dismiss" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:progress animated:YES completion:nil];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ok = downgrade_trigger_in_springboard([app.trackID longLongValue],
                                                   [versionId longLongValue]);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [progress dismissViewControllerAnimated:YES completion:nil];
            NSString *msg = ok
                ? @"Downgrade purchase request sent. Check App Store / Updates for the download."
                : @"Downgrade failed. Check the log for details.";
            UIAlertController *ac = [UIAlertController
                alertControllerWithTitle:ok ? @"Downgrade Started" : @"Downgrade Failed"
                                 message:msg
                          preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [strongSelf presentViewController:ac animated:YES completion:nil];
        });
    });
}

#pragma mark - SpringBoard StoreKitUI injection (recovered from _downgrade_trigger_in_springboard)

// Triggers the downgrade by driving a StoreKitUI purchase request inside
// SpringBoard. This mirrors the original _downgrade_trigger_in_springboard:
//   attach to SpringBoard → dlopen StoreKitUI → build SKUIItem/SKUIItemOffer/
//   SKUIClientContext → SKUIItemStateCenter _performPurchases:... (itunesstored)
static BOOL downgrade_trigger_in_springboard(int64_t trackID, int64_t versionID)
{
    log_user("[DOWNGRADE] Loading StoreKitUI framework into SpringBoard...\n");

    RemoteCallSession *session = [[RemoteCallSession alloc] initWithProcess:@"SpringBoard"
                                                          useMigFilterBypass:NO
                                                     firstExceptionTimeoutMS:kAppListRCFirstExceptionTimeoutMS];
    if (!session) {
        log_user("[DOWNGRADE] Failed to attach to SpringBoard.\n");
        return NO;
    }

    __block BOOL ok = NO;
    remote_call_with_session(session, ^{
        // 1) dlopen StoreKitUI inside SpringBoard.
        uint64_t frameworkPath = r_session_alloc_str(session, kSKUIStoreKitUIFrameworkPath.UTF8String);
        if (!frameworkPath) {
            log_user("[DOWNGRADE] ERROR: Failed to allocate memory in SpringBoard.\n");
            return;
        }
        uint64_t handle = r_session_dlsym_call(session, R_TIMEOUT, "dlopen",
                                               frameworkPath, 1, 0, 0, 0, 0, 0, 0);
        r_session_free(session, frameworkPath);
        if (!handle) {
            log_user("[DOWNGRADE] ERROR: SpringBoard failed to dlopen StoreKitUI.\n");
            return;
        }
        log_user("[DOWNGRADE] Constructing SKUI objects...\n");

        // 2) Resolve the classes (objc_getClass).
        uint64_t itemClass  = r_session_class(session, kSKUIItemClass.UTF8String);
        uint64_t offerClass = r_session_class(session, kSKUIItemOfferClass.UTF8String);
        uint64_t ctxClass   = r_session_class(session, kSKUIClientContextClass.UTF8String);
        uint64_t centerClass= r_session_class(session, kSKUIItemStateCenterClass.UTF8String);
        if (!itemClass || !offerClass || !ctxClass || !centerClass) {
            log_user("[DOWNGRADE] ERROR: Failed to instantiate SKUI items.\n");
            return;
        }

        // 3) Build an SKUIItemOffer configured for the target version.
        //    Try SKUIItemOffer initWithItemDictionary: (private StoreKitUI API)
        //    first, fall back to init + KVC wiring.
        uint64_t offer = r_session_msg2(session, offerClass, "alloc", 0, 0, 0, 0);
        if (!offer) {
            log_user("[DOWNGRADE] ERROR: Failed to instantiate SKUI items.\n");
            return;
        }
        offer = r_session_msg2(session, offer, "initWithItemDictionary:", 0, 0, 0, 0);
        if (!offer) {
            offer = r_session_msg2(session, offerClass, "alloc", 0, 0, 0, 0);
            if (offer) offer = r_session_msg2(session, offer, "init", 0, 0, 0, 0);
        }
        if (!offer) {
            log_user("[DOWNGRADE] ERROR: Failed to instantiate SKUI items.\n");
            return;
        }

        // 4) Build an SKUIItem that references the offer + the app's track id.
        uint64_t item = r_session_msg2(session, itemClass, "alloc", 0, 0, 0, 0);
        if (item) item = r_session_msg2(session, item, "init", 0, 0, 0, 0);
        if (!item) {
            log_user("[DOWNGRADE] ERROR: Failed to instantiate SKUI items.\n");
            return;
        }

        // 5) Build a minimal SKUIClientContext (default storefront context).
        uint64_t ctx = r_session_msg2(session, ctxClass, "alloc", 0, 0, 0, 0);
        if (ctx) ctx = r_session_msg2(session, ctx, "init", 0, 0, 0, 0);

        // 6) Grab the shared SKUIItemStateCenter.
        uint64_t center = r_session_msg2(session, centerClass, "defaultCenter", 0, 0, 0, 0);
        if (!center) {
            log_user("[DOWNGRADE] ERROR: SKUIItemStateCenter unavailable.\n");
            return;
        }

        // 7) Wire item → offer using KVC (setValue:forKey:) so we don't depend
        //    on private setters that vary across iOS versions. KVC keys are
        //    remote NSStrings; never nest remote calls inside arguments since
        //    C argument-evaluation order is unspecified.
        uint64_t offerKey    = r_session_nsstr_retained(session, "offerIdentifier");
        uint64_t buyKey      = r_session_nsstr_retained(session, "buyParameters");
        uint64_t itemIDKey   = r_session_nsstr_retained(session, "itemIdentifier");
        uint64_t availKey    = r_session_nsstr_retained(session, "availableOffers");
        uint64_t versionIdStr = r_session_nsstr_retained(session, [[NSString stringWithFormat:@"%lld", versionID] UTF8String]);
        uint64_t trackIdStr   = r_session_nsstr_retained(session, [[NSString stringWithFormat:@"%lld", trackID] UTF8String]);
        if (versionIdStr) {
            if (offerKey) {
                r_session_msg2(session, offer, "setValue:forKey:", versionIdStr, offerKey, 0, 0);
                r_session_free(session, offerKey);
            }
            if (buyKey) {
                r_session_msg2(session, offer, "setValue:forKey:", versionIdStr, buyKey, 0, 0);
                r_session_free(session, buyKey);
            }
            r_session_free(session, versionIdStr);
        }
        if (trackIdStr) {
            if (itemIDKey) {
                r_session_msg2(session, item, "setValue:forKey:", trackIdStr, itemIDKey, 0, 0);
                r_session_free(session, itemIDKey);
            }
            r_session_free(session, trackIdStr);
        }

        // 8) Attach the offer to the item (availableOffers expects an NSArray).
        //    Build a remote NSArray @[offer].
        uint64_t arrCls = r_session_class(session, "NSArray");
        uint64_t arr = r_session_msg2(session, arrCls, "arrayWithObjects:count:",
                                      offer, 1, 0, 0);
        if (arr) {
            if (availKey) {
                r_session_msg2(session, item, "setValue:forKey:", arr, availKey, 0, 0);
                r_session_free(session, availKey);
            }
        }

        // 9) Fire the purchase request. The selector string was recovered from
        //    the binary: SKUIItemStateCenter _performPurchases:hasBundlePurchase:
        //    withClientContext:completionBlock:
        uint64_t itemsArray = r_session_msg2(session, arrCls, "arrayWithObjects:count:",
                                             item, 1, 0, 0);
        if (!itemsArray) {
            log_user("[DOWNGRADE] ERROR: failed to build purchase array.\n");
            return;
        }
        uint64_t result = r_session_msg2(session, center, kSKUIPerformPurchasesSelector.UTF8String,
                                         itemsArray, 0, ctx, 0);
        ok = (result != 0);
        log_user("[DOWNGRADE] Sending purchase request to App Store daemon...\n");
    });

    [session destroyRemoteCall];
    return ok;
}

@end
