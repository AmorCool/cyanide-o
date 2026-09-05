//
//  BlockUpdatesViewController.m
//  Blocks App Store updates for the selected apps.
//
//  Mechanism (all inside SpringBoard via do_remote_call_stable):
//    block:   path = <AppBundlePath>/com.apple.mobileinstallation.placeholder
//             mkdir(path, 0755) + chmod(path, 0)   — a mode-0 placeholder
//             entry makes mobileinstallation treat the bundle as managed and
//             the App Store stops offering updates for it.
//    unblock: chmod(path, 0755) + rmdir(path)
//
//  Selection state lives in waitingApps (NSMutableSet of bundle IDs); Done
//  commits the whole batch in one RemoteCall session, mirroring the binary's
//  flow: stop live loops -> settings_rc_lock + @synchronized -> re-init the
//  SpringBoard session if stale -> per-app remote mkdir/chmod/rmdir.
//

#import "BlockUpdatesViewController.h"
#import "../TaskRop/RemoteCall.h"

#include <unistd.h>

// Exported by the mod build (upstream keeps these static in
// SettingsViewController.m; the mod de-static'd them for payload reuse).
extern BOOL settings_ensure_kexploit(void);
extern void settings_request_all_live_loops_stop(const char *reason);
extern BOOL settings_wait_live_loops_stopped_for_switch(const char *reason);
extern NSObject *settings_rc_lock(void);
extern void settings_destroy_springboard_remote_call_locked_internal_ex(const char *reason, BOOL notifyState, BOOL preserveApplied);
// init_remote_call is declared in ../TaskRop/RemoteCall.h (imported above):
//   int init_remote_call(const char* process, bool useMigFilterBypass);
extern void log_user(const char *fmt, ...);
extern void log_session_begin(void);
extern void log_session_end(void);

extern uint64_t do_remote_call_stable(int timeout, const char *name,
    uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3,
    uint64_t x4, uint64_t x5, uint64_t x6, uint64_t x7);
extern bool remote_write(uint64_t dst, const void *src, uint64_t size);

// From ViewController.m. Guarded by g_springboard_sandbox_escaped — calling
// it repeatedly burns kernel primitives and breaks KRW for every other tweak.
extern int escape_sbx_demo2(void);
extern volatile int g_springboard_sandbox_escaped;

static const int kBlockRCTimeout = 1000;

static uint64_t blockupdates_remote_alloc_str(const char *s)
{
    if (!s) return 0;
    uint64_t remote = do_remote_call_stable(kBlockRCTimeout, "malloc",
                                            strlen(s) + 1, 0, 0, 0, 0, 0, 0, 0);
    if (remote) {
        remote_write(remote, s, strlen(s) + 1);
    }
    return remote;
}

@interface BlockUpdatesViewController ()
@property (nonatomic, strong) NSArray<NSDictionary *> *apps;
@property (nonatomic, strong) NSArray<NSDictionary *> *filteredApps;
@property (nonatomic, strong) NSMutableSet<NSString *> *waitingApps;
@property (nonatomic, strong) UISearchController *searchController;
@end

@implementation BlockUpdatesViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Block Updates";
    self.tableView.rowHeight = 60.0;
    self.waitingApps = [NSMutableSet set];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Done" style:UIBarButtonItemStyleDone
        target:self action:@selector(commitUpdates)];

    UIRefreshControl *refresh = [[UIRefreshControl alloc] init];
    [refresh addTarget:self action:@selector(handleRefresh:)
      forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = refresh;

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

- (void)loadApps
{
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        // Same one-shot escape guard as AppListViewController.
        if (!g_springboard_sandbox_escaped) {
            if (escape_sbx_demo2()) {
                g_springboard_sandbox_escaped = YES;
            }
        }
        NSArray<NSDictionary *> *found = [self scanInstalledApps];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (found.count > 0) {
                self.apps = found;
            }
            self.filteredApps = self.apps;
            [self.tableView reloadData];
            [self.tableView.refreshControl endRefreshing];
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
        NSString *root = [@"/var/containers/Bundle/Application" stringByAppendingPathComponent:uuid];
        for (NSString *entry in [[NSFileManager defaultManager]
                contentsOfDirectoryAtPath:root error:nil]) {
            if (![entry.pathExtension isEqualToString:@".app"]) continue;
            NSString *bundlePath = [root stringByAppendingPathComponent:entry];
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

- (void)handleRefresh:(UIRefreshControl *)sender
{
    [self loadApps];
}

- (BOOL)isFiltering
{
    return self.searchController.isActive && self.searchController.searchBar.text.length > 0;
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
                return [name localizedCaseInsensitiveContainsString:query] ||
                       [app[@"CFBundleIdentifier"] localizedCaseInsensitiveContainsString:query];
            }]];
    }
    [self.tableView reloadData];
}

#pragma mark - Commit

- (void)commitUpdates
{
    if (self.waitingApps.count == 0) {
        return;
    }

    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        log_session_begin();
        NSMutableSet<NSString *> *waiting = self.waitingApps;
        log_user("[BLOCKUPDATES] Applying %lu selections...\n", (unsigned long)waiting.count);

        if (!settings_ensure_kexploit()) {
            log_user("[BLOCKUPDATES] Failed: kernel primitives not acquired.\n");
            log_session_end();
            dispatch_async(dispatch_get_main_queue(), ^{
                [self presentFailure:@"Could not acquire kernel primitives. Please try again or reboot."];
            });
            return;
        }

        settings_request_all_live_loops_stop("BlockUpdates");
        settings_wait_live_loops_stopped_for_switch("BlockUpdates");

        // settings_rc_lock() returns the shared lock object; the entire
        // SpringBoard session (including the stale-session recovery below)
        // must stay inside @synchronized so nothing else touches the session
        // and every path releases the lock.
        @synchronized (settings_rc_lock()) {
            if (!init_remote_call("SpringBoard", false)) {
                // Session may be stale after a respring — force a fresh attach.
                settings_destroy_springboard_remote_call_locked_internal_ex(
                    "BlockUpdates retry", YES, NO);
                if (!init_remote_call("SpringBoard", false)) {
                    log_user("[BLOCKUPDATES] Failed to attach to SpringBoard.\n");
                    log_session_end();
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self presentFailure:@"Could not attach to SpringBoard. Please respring and retry."];
                    });
                    return;
                }
            }

            for (NSDictionary *app in self.apps) {
                NSString *bundleId = app[@"CFBundleIdentifier"];
                if (!bundleId || ![waiting containsObject:bundleId]) {
                    continue;
                }
                BOOL block = ![self placeholderActiveForApp:app];

                NSString *name = app[@"CFBundleDisplayName"] ?: app[@"CFBundleName"];
                NSString *path = [app[@"AppBundlePath"]
                    stringByAppendingPathComponent:@"com.apple.mobileinstallation.placeholder"];
                uint64_t remotePath = blockupdates_remote_alloc_str(path.UTF8String);
                if (!remotePath) {
                    log_user("[BLOCKUPDATES] Failed to alloc path for %s\n", name.UTF8String);
                    continue;
                }

                if (block) {
                    uint64_t mkdirRet = do_remote_call_stable(kBlockRCTimeout, "mkdir",
                                                              remotePath, 0755, 0, 0, 0, 0, 0, 0);
                    do_remote_call_stable(kBlockRCTimeout, "chmod",
                                          remotePath, 0, 0, 0, 0, 0, 0, 0);
                    if (mkdirRet != 0) {
                        log_user("[WARN] Failed to block %s (Code: %llu)\n",
                                 name.UTF8String, mkdirRet);
                    } else {
                        log_user("[OK] Blocked updates for: %s\n", name.UTF8String);
                    }
                } else {
                    do_remote_call_stable(kBlockRCTimeout, "chmod",
                                          remotePath, 0755, 0, 0, 0, 0, 0, 0);
                    uint64_t rmdirRet = do_remote_call_stable(kBlockRCTimeout, "rmdir",
                                                              remotePath, 0, 0, 0, 0, 0, 0, 0);
                    if (rmdirRet != 0) {
                        log_user("[WARN] Failed to unblock %s (Code: %llu)\n",
                                 name.UTF8String, rmdirRet);
                    } else {
                        log_user("[OK] Unblocked updates for: %s\n", name.UTF8String);
                    }
                }

                do_remote_call_stable(kBlockRCTimeout, "free", remotePath, 0, 0, 0, 0, 0, 0, 0);
            }

            log_user("[BLOCKUPDATES] Done.\n");
        }

        log_session_end();

        dispatch_async(dispatch_get_main_queue(), ^{
            [self.waitingApps removeAllObjects];
            [self.tableView reloadData];
        });
    });
}

// Local probe — the blocked state is a mode-0 placeholder entry inside the
// bundle; any existing entry (EACCES included) means "blocked".
- (BOOL)placeholderActiveForApp:(NSDictionary *)app
{
    NSString *path = [app[@"AppBundlePath"]
        stringByAppendingPathComponent:@"com.apple.mobileinstallation.placeholder"];
    return access(path.UTF8String, F_OK) == 0;
}

- (void)presentFailure:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Failed"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
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

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *identifier = @"BlockCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                     reuseIdentifier:identifier];
    }
    NSDictionary *app = [self isFiltering] ? self.filteredApps[indexPath.row]
                                           : self.apps[indexPath.row];
    cell.textLabel.text = app[@"CFBundleDisplayName"] ?: app[@"CFBundleName"];
    cell.detailTextLabel.text = app[@"CFBundleIdentifier"];
    cell.accessoryType = [self.waitingApps containsObject:app[@"CFBundleIdentifier"]]
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *app = [self isFiltering] ? self.filteredApps[indexPath.row]
                                           : self.apps[indexPath.row];
    NSString *bundleId = app[@"CFBundleIdentifier"];
    if (!bundleId) return;
    if ([self.waitingApps containsObject:bundleId]) {
        [self.waitingApps removeObject:bundleId];
    } else {
        [self.waitingApps addObject:bundleId];
    }
    [tableView reloadRowsAtIndexPaths:@[ indexPath ] withRowAnimation:UITableViewRowAnimationNone];
}

@end
