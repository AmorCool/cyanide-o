//
//  AppListViewController.m
//  Installed-app browser + App Store downgrade UI.
//
//  Data flow:
//    loadApps
//      └─ reads /var/containers/Bundle/Application/<UUID>/<App>.app/Info.plist
//         into per-app dictionaries (CFBundleDisplayName / CFBundleName /
//         CFBundleIdentifier / AppBundlePath).
//    didSelectRow → presentActionSheetForApp
//      ├─ "Fetch from Server" → fetchDowngradeDataForApp
//      │    └─ downgrade_fetchTrackIDForBundleID (iTunes lookup, walks every
//         supported country code until a track matches)
//      │       └─ downgrade_fetchVersionsForTrackID (history API)
//      │          └─ downgrade_presentVersionSelection (sorted by release_date)
//      └─ "Custom Version ID" → promptForCustomVersionForApp (manual AppExtVrsId)
//    Both paths converge on executeCustomDowngradeWithAppInfo:versionId:,
//    which forwards to downgrade_trigger_in_springboard().
//

#import "AppListViewController.h"
#import "../tweaks/appdowngrade.h"

// From ViewController.m — local sandbox escape used before touching app
// containers directly. Repeated calls re-consume the KRW primitives every
// time, so it is guarded by g_springboard_sandbox_escaped exactly like the
// shipped binary does (cbnz w8 -> skip; bl _escape_sbx_demo2).
extern int escape_sbx_demo2(void);
extern volatile int g_springboard_sandbox_escaped;

#define R_DOWNGRADE_HISTORY_API_FORMAT @"https://apis.bilin.eu.org/history/%lld"
#define R_ITUNES_LOOKUP_BUNDLE_FORMAT  @"https://itunes.apple.com/lookup?bundleId=%@&limit=1&media=software&country=%@"
#define R_ITUNES_LOOKUP_ID_FORMAT      @"https://itunes.apple.com/lookup?id=%@&country=%@"

@interface AppListViewController ()
@property (nonatomic, strong) NSArray<NSDictionary *> *apps;
@property (nonatomic, strong) NSArray<NSDictionary *> *filteredApps;
@property (nonatomic, strong) NSArray<NSDictionary *> *appStoreResults;
@property (nonatomic, strong) NSURLSessionDataTask *currentSearchTask;
@property (nonatomic, strong) NSCache *imageCache;
@property (nonatomic, strong) UISearchController *searchController;
// App whose version-selection sheet is on screen; the alert actions capture
// it implicitly in the fetch flow, but the sorted-versions handler needs the
// owning dictionary to hand to executeCustomDowngradeWithAppInfo:versionId:.
@property (nonatomic, strong) NSDictionary *pendingDowngradeApp;
@end

@implementation AppListViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"App Downgrade";
    self.tableView.rowHeight = 76.0;
    self.imageCache = [[NSCache alloc] init];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Search App";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    self.filteredApps = self.apps;
    [self loadApps];
}

#pragma mark - Data

- (void)loadApps
{
    if (self.apps.count > 0) {
        // Refresh in place: keep the cached list until the rescan finishes so
        // the table doesn't flash empty.
        NSArray<NSDictionary *> *previous = self.apps;
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            NSArray<NSDictionary *> *fresh = [self scanInstalledApps];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (fresh.count > 0) self.apps = fresh;
                else self.apps = previous;
                self.filteredApps = self.apps;
                [self.tableView reloadData];
            });
        });
        return;
    }

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [spinner startAnimating];
    self.tableView.backgroundView = spinner;

    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        // Sandbox escape is one-shot per process lifetime; without this guard
        // every refresh would burn another kernel primitive and break KRW.
        if (!g_springboard_sandbox_escaped) {
            if (escape_sbx_demo2()) {
                g_springboard_sandbox_escaped = YES;
            }
        }
        NSArray<NSDictionary *> *found = [self scanInstalledApps];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.apps = found;
            self.filteredApps = self.apps;
            [self.tableView reloadData];
            self.tableView.backgroundView = nil;
        });
    });
}

- (NSArray<NSDictionary *> *)scanInstalledApps
{
    // Caller guarantees the sandbox escape already happened (loadApps guard).
    NSArray<NSString *> *uuids = [[NSFileManager defaultManager]
        contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application" error:nil];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSString *uuid in uuids) {
        NSArray<NSString *> *containers = [[NSFileManager defaultManager]
            contentsOfDirectoryAtPath:
                [@"/var/containers/Bundle/Application" stringByAppendingPathComponent:uuid]
            error:nil];
        for (NSString *entry in containers) {
            if (![entry.pathExtension isEqualToString:@".app"]) continue;
            NSString *bundlePath = [@"/var/containers/Bundle/Application"
                stringByAppendingPathComponent:uuid];
            bundlePath = [bundlePath stringByAppendingPathComponent:entry];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                [bundlePath stringByAppendingPathComponent:@"Info.plist"]];
            if (!info) continue;
            NSMutableDictionary *app = [info mutableCopy];
            app[@"AppBundlePath"] = bundlePath;
            [out addObject:app];
        }
    }
    return [out copy];
}

- (BOOL)isFiltering
{
    return self.searchController.isActive &&
           self.searchController.searchBar.text.length > 0;
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController
{
    NSString *query = searchController.searchBar.text;
    if (query.length == 0) {
        self.filteredApps = self.apps;
    } else {
        self.filteredApps = [self.apps filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSDictionary *app, NSDictionary *bindings) {
                NSString *name = app[@"CFBundleDisplayName"] ?: app[@"CFBundleName"];
                NSString *bundleId = app[@"CFBundleIdentifier"];
                return ([name localizedCaseInsensitiveContainsString:query] ||
                        [bundleId localizedCaseInsensitiveContainsString:query]);
            }]];
    }
    [self.tableView reloadData];
}

#pragma mark - Downgrade: fetch chain

// Country codes the iTunes lookup walks. `cn` first — the downgrade history
// database covers CN store apps best, and iTunes regional catalogs differ.
- (NSArray<NSString *> *)downgrade_supportedAppStoreCountryCodes
{
    return @[@"cn", @"us", @"ae", @"ag", @"ai", @"al", @"am", @"ao", @"ar", @"at",
             @"au", @"az", @"bb", @"be", @"bf", @"bg", @"bh", @"bj", @"bm", @"bn",
             @"bo", @"br", @"bs", @"bt", @"bw", @"by", @"bz", @"ca", @"cg", @"ch",
             @"ci", @"cl", @"cm", @"co", @"cr", @"cv", @"cy", @"cz", @"de", @"dk",
             @"dm", @"do", @"dz", @"ec", @"ee", @"eg", @"es", @"fi", @"fj", @"fm",
             @"fr", @"gb", @"gd", @"gh", @"gm", @"gr", @"gt", @"gw", @"gy", @"hk",
             @"hn", @"hr", @"hu", @"id", @"ie", @"il", @"in", @"is", @"it", @"jm",
             @"jo", @"jp", @"ke", @"kg", @"kh", @"kn", @"kr", @"kw", @"ky", @"kz",
             @"la", @"lb", @"lc", @"lk", @"lr", @"lt", @"lu", @"lv", @"md", @"mg",
             @"mk", @"ml", @"mn", @"mo", @"mr", @"ms", @"mt", @"mu", @"mw", @"mx",
             @"my", @"na", @"ne", @"ng", @"ni", @"nl", @"no", @"np", @"nz", @"om",
             @"pa", @"pe", @"pg", @"ph", @"pk", @"pl", @"pt", @"pw", @"py", @"qa",
             @"ro", @"ru", @"rw", @"sa", @"sb", @"sc", @"se", @"sg", @"si", @"sk",
             @"sl", @"sn", @"sr", @"st", @"sv", @"sz", @"tc", @"td", @"th", @"tj",
             @"tm", @"tn", @"tr", @"tt", @"tw", @"tz", @"ua", @"ug", @"uy", @"uz",
             @"vc", @"ve", @"vg", @"vn", @"ye", @"za", @"zm", @"zw"];
}

// Walks `codes` from `index`, one iTunes lookup per country, until a track
// resolves for `bundleId`. Recursion keeps the request chain serial.
- (void)downgrade_fetchTrackIDWithCountryCodes:(NSArray<NSString *> *)codes
                                         index:(NSUInteger)index
                                      bundleId:(NSString *)bundleId
                                    completion:(void (^)(NSNumber *))completion
{
    if (index >= codes.count) {
        completion(nil);
        return;
    }

    NSString *url = [NSString stringWithFormat:R_ITUNES_LOOKUP_BUNDLE_FORMAT,
                     bundleId, codes[index]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    request.timeoutInterval = 10.0;

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSUInteger nextIndex = index + 1;
            NSNumber *trackID = nil;
            if (data && !error) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSArray *results = json[@"results"];
                if ([results isKindOfClass:[NSArray class]] && results.count > 0) {
                    id trackIdValue = results.firstObject[@"trackId"];
                    if ([trackIdValue respondsToSelector:@selector(longLongValue)]) {
                        trackID = @([trackIdValue longLongValue]);
                    }
                }
            }
            if (trackID) {
                completion(trackID);
            } else {
                dispatch_async(dispatch_get_global_queue(0, 0), ^{
                    [self downgrade_fetchTrackIDWithCountryCodes:codes
                                                           index:nextIndex
                                                        bundleId:bundleId
                                                      completion:completion];
                });
            }
        }] resume];
}

- (void)downgrade_fetchTrackIDForBundleID:(NSString *)bundleId
                               completion:(void (^)(NSNumber *))completion
{
    [self downgrade_fetchTrackIDWithCountryCodes:[self downgrade_supportedAppStoreCountryCodes]
                                           index:0
                                        bundleId:bundleId
                                      completion:completion];
}

// Historical version list for a track. Returns the raw "data" array of the
// history service — entries carry external_identifier (AppExtVrsId),
// bundle_version and release_date.
- (void)downgrade_fetchVersionsForTrackID:(long long)trackID
                               completion:(void (^)(NSArray<NSDictionary *> *, NSError *))completion
{
    NSString *url = [NSString stringWithFormat:R_DOWNGRADE_HISTORY_API_FORMAT, trackID];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    request.timeoutInterval = 10.0;

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                completion(nil, error);
                return;
            }
            if (!data) {
                completion(nil, [NSError errorWithDomain:@"Downgrade" code:-1
                                                userInfo:@{NSLocalizedDescriptionKey:
                                                    @"No historical versions found."}]);
                return;
            }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *versions = json[@"data"];
            if ([versions isKindOfClass:[NSArray class]] && versions.count > 0) {
                completion(versions, nil);
            } else {
                completion(nil, [NSError errorWithDomain:@"Downgrade" code:-1
                                                userInfo:@{NSLocalizedDescriptionKey:
                                                    @"No historical versions found."}]);
            }
        }] resume];
}

- (void)downgrade_presentVersionSelection:(NSArray<NSDictionary *> *)versions
                                  trackID:(long long)trackID
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select Version"
                                                                   message:@"Choose a version to downgrade to"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSSortDescriptor *dateSort = [NSSortDescriptor sortDescriptorWithKey:@"release_date" ascending:NO];
    NSArray *sorted = [versions sortedArrayUsingDescriptors:@[ dateSort ]];

    NSDictionary *app = self.pendingDowngradeApp;
    for (NSDictionary *version in sorted) {
        NSString *bundleVersion = version[@"bundle_version"] ?: @"N/A";
        id externalId = version[@"external_identifier"];
        long long externalValue = 0;
        if ([externalId isKindOfClass:[NSNumber class]]) {
            externalValue = [externalId longLongValue];
        } else if ([externalId isKindOfClass:[NSString class]]) {
            externalValue = [externalId longLongValue];
        }
        if (externalValue == 0) continue;
        NSString *versionId = [NSString stringWithFormat:@"%lld", externalValue];

        NSString *title = [NSString stringWithFormat:@"%@ (%@)", bundleVersion, versionId];
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) {
                [self executeCustomDowngradeWithAppInfo:app versionId:versionId];
            }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel handler:nil]];

    // Action sheets need an anchor on iPad.
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.tableView;
        alert.popoverPresentationController.sourceRect = self.tableView.bounds;
        alert.popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Downgrade: execution

- (void)executeFetchWithBundleId:(NSString *)bundleId
                         appInfo:(NSDictionary *)appInfo
                    loadingAlert:(UIAlertController *)loadingAlert
{
    // Cache hit from a previous lookup in this session — skip the country walk.
    id preFetched = appInfo[@"PreFetchedTrackID"];
    if (preFetched) {
        long long trackID = [preFetched longLongValue];
        [self downgrade_fetchVersionsForTrackID:trackID completion:^(NSArray *versions, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [loadingAlert dismissViewControllerAnimated:YES completion:^{
                    if (versions) {
                        [self downgrade_presentVersionSelection:versions trackID:trackID];
                    } else {
                        [self presentDowngradeError:error.localizedDescription
                                              title:@"Failed"];
                    }
                }];
            });
        }];
        return;
    }

    __weak typeof(self) weakSelf = self;
    [self downgrade_fetchTrackIDForBundleID:bundleId completion:^(NSNumber *trackID) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!trackID) {
                [loadingAlert dismissViewControllerAnimated:YES completion:^{
                    [weakSelf presentDowngradeError:@"Could not fetch the Track ID for this app."
                                              title:@"Failed"];
                }];
                return;
            }
            [loadingAlert dismissViewControllerAnimated:YES completion:^{
                [weakSelf downgrade_fetchVersionsForTrackID:trackID.longLongValue
                                                 completion:^(NSArray *versions, NSError *error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (versions) {
                            [weakSelf downgrade_presentVersionSelection:versions
                                                                trackID:trackID.longLongValue];
                        } else {
                            [weakSelf presentDowngradeError:error.localizedDescription
                                                      title:@"Failed"];
                        }
                    });
                }];
            }];
        });
    }];
}

- (void)fetchDowngradeDataForApp:(NSDictionary *)app
{
    self.pendingDowngradeApp = app;
    NSString *bundleId = app[@"CFBundleIdentifier"];
    NSString *name = app[@"CFBundleDisplayName"] ?: app[@"CFBundleName"];

    UIAlertController *loading = [UIAlertController alertControllerWithTitle:@"Fetching Data"
                                                                     message:[NSString stringWithFormat:
                                                                              @"Looking up history for %@...", name]
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:loading animated:YES completion:nil];

    [self executeFetchWithBundleId:bundleId appInfo:app loadingAlert:loading];
}

- (void)executeCustomDowngradeWithAppInfo:(NSDictionary *)app versionId:(NSString *)versionId
{
    NSString *bundleId = app[@"CFBundleIdentifier"];
    NSString *name = app[@"CFBundleDisplayName"] ?: app[@"CFBundleName"];

    UIAlertController *loading = [UIAlertController alertControllerWithTitle:@"Preparing"
                                                                     message:[NSString stringWithFormat:
                                                                              @"Fetching Track ID for %@...", name]
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:loading animated:YES completion:nil];

    id preFetched = app[@"PreFetchedTrackID"];
    if (preFetched) {
        [loading dismissViewControllerAnimated:YES completion:nil];
        long long trackID = [preFetched longLongValue];
        downgrade_trigger_in_springboard([NSString stringWithFormat:@"%lld", trackID], versionId);
        return;
    }

    __weak typeof(self) weakSelf = self;
    [self downgrade_fetchTrackIDForBundleID:bundleId completion:^(NSNumber *trackID) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [loading dismissViewControllerAnimated:YES completion:nil];
            if (!trackID) {
                [weakSelf presentDowngradeError:@"Could not fetch the Track ID for this app."
                                          title:@"Failed"];
                return;
            }
            downgrade_trigger_in_springboard([NSString stringWithFormat:@"%lld", trackID.longLongValue],
                                             versionId);
        });
    }];
}

- (void)presentDowngradeError:(NSString *)message title:(NSString *)title
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Downgrade: entry points

- (void)presentActionSheetForApp:(NSDictionary *)app
                       tableView:(UITableView *)tableView
                         indexPath:(NSIndexPath *)indexPath
{
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Downgrade/Install Method"
                                                                   message:@"Choose how to get the version ID"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Fetch from Server"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self fetchDowngradeDataForApp:app];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Custom Version ID"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        [self promptForCustomVersionForApp:app];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel handler:nil]];

    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        // `?:` cannot be applied to CGRect (a struct) — only to arithmetic or
        // pointer types — so sourceRect uses an explicit conditional.
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        sheet.popoverPresentationController.sourceView = cell ?: self.view;
        sheet.popoverPresentationController.sourceRect =
            cell ? cell.bounds : self.view.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)promptForCustomVersionForApp:(NSDictionary *)app
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Custom Version ID"
                                                                   message:@"Enter the numeric AppExtVrsId for the version:\ne.g., 843219482"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Version ID";
        textField.keyboardType = UIKeyboardTypeNumberPad;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Downgrade"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        NSString *versionId = alert.textFields.firstObject.text;
        if (versionId.length == 0) return;
        [self executeCustomDowngradeWithAppInfo:app versionId:versionId];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return self.isFiltering ? self.filteredApps.count : self.apps.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return [NSString stringWithFormat:@"%ld Apps", (long)(self.isFiltering ?
            self.filteredApps.count : self.apps.count)];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *identifier = @"AppCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                             reuseIdentifier:identifier];

    NSDictionary *app = [self isFiltering] ? self.filteredApps[indexPath.row]
                                           : self.apps[indexPath.row];
    NSString *name = app[@"CFBundleDisplayName"] ?: app[@"CFBundleName"];
    cell.textLabel.text = name;
    cell.detailTextLabel.text = app[@"CFBundleIdentifier"];
    cell.imageView.image = [self cachedIconForApp:app];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *app = [self isFiltering] ? self.filteredApps[indexPath.row]
                                           : self.apps[indexPath.row];
    [self presentActionSheetForApp:app tableView:tableView indexPath:indexPath];
}


#pragma mark - Icon cache

- (UIImage *)cachedIconForApp:(NSDictionary *)app
{
    NSString *bundlePath = app[@"AppBundlePath"];
    if (!bundlePath) return nil;
    NSString *key = app[@"CFBundleIdentifier"] ?: bundlePath;
    UIImage *cached = [self.imageCache objectForKey:key];
    if (cached) return cached;

    NSString *iconName = app[@"CFBundleIcons"][@"CFBundlePrimaryIcon"][@"CFBundleIconName"] ?:
                         app[@"CFBundleIconFile"];
    UIImage *icon = iconName ? [UIImage imageNamed:iconName] : nil;
    if (!icon) {
        // Fall back to the raw PNG inside the bundle.
        NSString *iconFile = app[@"CFBundleIconFile"];
        if (![iconFile.pathExtension length]) iconFile = [iconFile stringByAppendingPathExtension:@"png"];
        if (iconFile) {
            icon = [UIImage imageWithContentsOfFile:
                [bundlePath stringByAppendingPathComponent:iconFile]];
        }
    }
    if (!icon) return nil;

    // Round to the home-screen corner radius so list rows match Settings.
    CGSize size = CGSizeMake(60, 60);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *rounded = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height)
                                                        cornerRadius:13.0];
        [path addClip];
        [icon drawInRect:CGRectMake(0, 0, size.width, size.height)];
    }];
    [self.imageCache setObject:rounded forKey:key];
    return rounded;
}

@end
