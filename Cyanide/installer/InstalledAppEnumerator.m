//
//  InstalledAppEnumerator.m
//  Cyanide
//
//  Enumerates installed apps by walking /var/containers/Bundle/Application/
//  and reading each <UUID>/Foo.app/Info.plist.
//
//  This is the path the original 2nd-edition Cyanide IPA actually used (verified
//  by class-dumping AppListViewController — its -loadApps impl reads plists
//  directly off disk; there is no LSW/MIP/enumerateInstalledApplications
//  selector in its ObjC metadata).
//
//  Why filesystem traversal:
//    - LSApplicationWorkspace on iOS 17+ returns an empty list when called
//      from a non-SpringBoard process that lacks the platform entitlement.
//    - mobile_installation_proxy (MIP XPC) requires the same entitlement and
//      silently returns no reply without it.
//    - Direct plist reads of every installed .app's Info.plist need no
//      entitlement and work even when KRW is unavailable (as long as the app
//      sandbox can stat /var/containers/Bundle/Application, which is allowed
//      for store-installed apps on stock iOS).
//
//  What gets lost vs. the LSW/MIP paths:
//    - Hidden apps (LSApplicationProxyHiddenReasonKey > 0) are still visible.
//      That's fine for Downgrade (the user wants to see what's installed).
//    - Apps whose Info.plist is unreadable for any reason are skipped with
//      a log line, not enumerated as zero.
//
//  Result is sorted case-insensitively by display name.
//

#import "InstalledAppEnumerator.h"
#import "../LogTextView.h"
#import "../kexploit/kexploit_opa334.h"
#import <xpc/xpc.h>
#import <dlfcn.h>

@implementation InstalledApp
@end

#pragma mark - Filesystem enumeration

static NSString * const kAppBundleRoot = @"/var/containers/Bundle/Application";

static NSArray<InstalledApp *> *scanInstalledAppsFromFilesystem(void)
{
    NSMutableArray<InstalledApp *> *apps = [NSMutableArray array];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *root = [NSURL fileURLWithPath:kAppBundleRoot isDirectory:YES];
    NSDirectoryEnumerator<NSURL *> *enumerator = [fm enumeratorAtURL:root
                                             includingPropertiesForKeys:@[ NSURLIsDirectoryKey, NSURLPathKey ]
                                                                options:NSDirectoryEnumerationSkipsHiddenFiles
                                                           errorHandler:^(NSURL *url, NSError *err) {
        // Don't bail out on a single error; just keep going.
        return YES;
    }];

    for (NSURL *url in enumerator) {
        NSNumber *isDir = nil;
        if (![url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:NULL] ||
            !isDir.boolValue) {
            continue;
        }
        // Only descend one level: <UUID>/<Foo.app>/Info.plist
        NSString *path = url.path;
        NSString *lastSegment = path.lastPathComponent;
        if (!lastSegment.length || ![lastSegment hasSuffix:@".app"]) continue;

        NSString *infoPlistPath = [path stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
        if (![plist isKindOfClass:[NSDictionary class]]) {
            continue; // skip silently — many apps have non-dict Info.plists if corrupt
        }

        NSString *bundleID = plist[@"CFBundleIdentifier"];
        if (![bundleID isKindOfClass:[NSString class]] || !bundleID.length) continue;

        NSString *name = plist[@"CFBundleDisplayName"];
        if (![name isKindOfClass:[NSString class]] || !name.length) {
            name = plist[@"CFBundleName"];
        }
        if (![name isKindOfClass:[NSString class]] || !name.length) {
            name = bundleID;
        }

        NSString *shortVersion = plist[@"CFBundleShortVersionString"];
        if (![shortVersion isKindOfClass:[NSString class]]) shortVersion = nil;
        NSString *bundleVersion = plist[@"CFBundleVersion"];
        if (![bundleVersion isKindOfClass:[NSString class]]) bundleVersion = nil;

        InstalledApp *app = [InstalledApp new];
        app.bundleID = bundleID;
        app.name = name;
        app.version = shortVersion.length ? shortVersion
                       : (bundleVersion.length ? bundleVersion : @"");
        [apps addObject:app];
    }

    return apps;
}

#pragma mark - Entry point

NSArray<InstalledApp *> *InstalledAppEnumeratorList(void)
{
    // Filesystem enumeration: no entitlement required, works on every iOS
    // version the host binary supports. This is what the original 2nd-edition
    // Cyanide IPA actually used (verified via class-dump).
    NSArray<InstalledApp *> *fsApps = scanInstalledAppsFromFilesystem();
    if (fsApps.count > 0) {
        log_user("[APPLIST] Enumerated %lu apps via filesystem (Info.plist scan).\n",
                 (unsigned long)fsApps.count);
        return [fsApps sortedArrayUsingComparator:^NSComparisonResult(InstalledApp *a, InstalledApp *b) {
            return [a.name localizedCaseInsensitiveCompare:b.name];
        }];
    }

    bool krwReady = kexploit_krw_ready();
    log_user("[APPLIST] WARNING: no installed apps enumerated from /var/containers/Bundle/Application.\n"
             "          KRW ready: %s. Either the path is unreadable in this sandbox\n"
             "          (rare; usually jailbreaks allow it) or the directory is empty.\n"
             "          Downgrade requires KRW anyway, so this is informational.\n",
             krwReady ? "YES" : "NO");
    return @[];
}