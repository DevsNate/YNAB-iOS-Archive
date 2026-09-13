#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>
#import "Endpoint.h"

static IMP originalContextInit, originalContextInitVM, originalSharedInit, originalEmailWindow;
static IMP originalSettingsMessage, originalWidgetMessage, originalWidgetDidDisappear, originalAccountListWillAppear;
static void surfaceFailure(id owner, SEL selector, WKWebView *view, WKNavigation *navigation, NSError *error);
static IMP originalWebLoad, originalWidgetPolicy, originalSettingsPolicy;
static char offlineRequestKey, offlineNavigationKey, profileSaveKey, accountOperationKey, accountCreatedKey, fallbackCancellationKey, serverProbeKey;
static char openWidgetMonitorKey, widgetCloseProbeKey;
static char surfaceStartKey;
static BOOL accountListRefreshPending;
static NSMutableDictionary *failureImplementations;
static const NSTimeInterval kServerProbeRequestTimeout = 1.5;
static const NSTimeInterval kServerProbeResourceTimeout = 2.0;
static const NSTimeInterval kOnlineSurfaceMinimumLoadingDuration = 1.0;
static const NSTimeInterval kOpenWidgetProbeInterval = 2.0;

// WKScriptMessage is immutable.  The stock account-widget handler only reads
// its body, so a forwarding proxy lets us normalize an offline close request
// without replacing the handler or touching the online path.
@interface YNABScriptMessageProxy : NSObject
@property(nonatomic,strong) WKScriptMessage *message;
@property(nonatomic,strong) NSDictionary *proxyBody;
@end
@implementation YNABScriptMessageProxy
- (id)body { return self.proxyBody; }
- (id)forwardingTargetForSelector:(SEL)selector { return self.message; }
@end

static BOOL isOfflineSurfaceURL(NSURL *url) {
    if (!url.isFileURL) return NO;
    NSString *path = url.path ?: @"";
    return [path containsString:@"/YNABOffline/account-widget/"] || [path containsString:@"/YNABOffline/account-settings/"];
}

static BOOL isSameOfflineDocumentURL(NSURL *actual, NSURL *expected) {
    if (!actual.isFileURL || !expected.isFileURL) return NO;
    NSString *actualPath = [actual.path stringByStandardizingPath];
    NSString *expectedPath = [expected.path stringByStandardizingPath];
    return actualPath.length && [actualPath isEqual:expectedPath];
}

static BOOL isServerTransportFailure(NSError *error) {
    if (![error.domain isEqual:NSURLErrorDomain]) return NO;
    switch (error.code) {
        case NSURLErrorNotConnectedToInternet:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorCannotFindHost:
        case NSURLErrorTimedOut:
        case NSURLErrorNetworkConnectionLost:
        case NSURLErrorDNSLookupFailed:
        case NSURLErrorSecureConnectionFailed:
        case NSURLErrorServerCertificateHasBadDate:
        case NSURLErrorServerCertificateUntrusted:
        case NSURLErrorServerCertificateHasUnknownRoot:
        case NSURLErrorServerCertificateNotYetValid:
        case NSURLErrorClientCertificateRejected:
        case NSURLErrorClientCertificateRequired:
            return YES;
        default:
            return NO;
    }
}

static NSURL *serverHealthURL(NSString *origin) {
    NSURLComponents *parts = [NSURLComponents componentsWithString:YNABCanonicalOrigin(origin) ?: @""];
    if (!parts.host.length) return nil;
    parts.path = @"/health";
    parts.query = nil;
    parts.fragment = nil;
    return parts.URL;
}

static NSURLSession *serverProbeSession(void) {
    static dispatch_once_t onceToken;
    static NSURLSession *session;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.URLCache = nil;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        configuration.HTTPShouldSetCookies = NO;
        configuration.waitsForConnectivity = NO;
        // A usable route may still be slow. Keep no-route fallback immediate,
        // but give a reachable server a bounded window before declaring it down.
        configuration.timeoutIntervalForRequest = 1.5;
        configuration.timeoutIntervalForResource = 2.0;
        session = [NSURLSession sessionWithConfiguration:configuration];
    });
    return session;
}

static void cancelServerProbe(WKWebView *view) {
    NSURLSessionDataTask *task = objc_getAssociatedObject(view, &serverProbeKey);
    objc_setAssociatedObject(view, &serverProbeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [task cancel];
}

static void beginSelectedServerProbe(WKWebView *view, void (^completion)(BOOL reachable, NSError *error)) {
    NSURL *healthURL = serverHealthURL(YNABSavedOrigin());
    if (!healthURL) {
        if (completion) completion(NO, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotConnectToHost userInfo:nil]);
        return;
    }
    cancelServerProbe(view);
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:healthURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:kServerProbeRequestTimeout];
    request.HTTPMethod = @"GET";
    [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    __weak WKWebView *weakView = view;
    __block NSURLSessionDataTask *task = nil;
    task = [serverProbeSession() dataTaskWithRequest:request completionHandler:^(__unused NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            WKWebView *current = weakView;
            if (!current || objc_getAssociatedObject(current, &serverProbeKey) != task) return;
            objc_setAssociatedObject(current, &serverProbeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (error.code == NSURLErrorCancelled) return;
            NSError *failure = error ?: [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotConnectToHost userInfo:nil];
            if (completion) completion(response != nil && error == nil, failure);
        });
    }];
    objc_setAssociatedObject(view, &serverProbeKey, task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [task resume];
}

static void probeSelectedServer(WKWebView *view, WKNavigation *navigation) {
    beginSelectedServerProbe(view, ^(BOOL reachable, NSError *error) {
        if (reachable) return;
        surfaceFailure((id)view.navigationDelegate, @selector(webView:didFailProvisionalNavigation:withError:), view, navigation, error);
    });
}

static NSDictionary *ynabLocalIdentity(void) {
    NSString *path = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!path.length) return @{};
    sqlite3 *db = NULL; sqlite3_stmt *stmt = NULL;
    path = [path stringByAppendingPathComponent:@"YNAB.sqlite"];
    if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) { if (db) sqlite3_close(db); return @{}; }
    NSDictionary *result = @{};
    if (sqlite3_prepare_v2(db, "SELECT COALESCE(firstName,''), COALESCE(email,''), userId FROM Users WHERE userId = (SELECT settingValue FROM GlobalSettings WHERE settingName = 'lastLoggedInUser') LIMIT 1", -1, &stmt, NULL) == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW) {
        const char *first = (const char *)sqlite3_column_text(stmt, 0); const char *email = (const char *)sqlite3_column_text(stmt, 1);
        const char *userId = (const char *)sqlite3_column_text(stmt, 2);
        result = @{ @"userId": userId ? [NSString stringWithUTF8String:userId] : @"", @"firstName": first ? [NSString stringWithUTF8String:first] : @"", @"email": email ? [NSString stringWithUTF8String:email] : @"" };
    }
    if (stmt) sqlite3_finalize(stmt); sqlite3_close(db); return result;
}

static NSDictionary *ynabLocalAccount(NSString *accountId, NSString *budgetId) {
    if (!accountId.length || !budgetId.length) return @{};
    NSString *path = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!path.length) return @{};
    sqlite3 *db = NULL; sqlite3_stmt *stmt = NULL;
    path = [path stringByAppendingPathComponent:@"YNAB.sqlite"];
    if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) { if (db) sqlite3_close(db); return @{}; }
    NSDictionary *result = @{};
    const char *query = "SELECT A.accountName, A.accountType, A.budgetVersionId FROM Accounts A JOIN UserBudgets U ON U.budgetVersionId = A.budgetVersionId WHERE A.entityId = ?1 AND A.isTombstone = 0 AND (U.budgetId = ?2 OR U.budgetVersionId = ?2) AND U.userId = (SELECT settingValue FROM GlobalSettings WHERE settingName = 'lastLoggedInUser') AND U.isTombstone = 0 LIMIT 1";
    if (sqlite3_prepare_v2(db, query, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, accountId.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, budgetId.UTF8String, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            const char *name = (const char *)sqlite3_column_text(stmt, 0);
            const char *type = (const char *)sqlite3_column_text(stmt, 1);
            const char *version = (const char *)sqlite3_column_text(stmt, 2);
            result = @{ @"id": accountId,
                @"account_name": name ? [NSString stringWithUTF8String:name] : @"",
                @"account_type": type ? [NSString stringWithUTF8String:type] : @"",
                @"budgetVersionId": version ? [NSString stringWithUTF8String:version] : @"" };
        }
    }
    if (stmt) sqlite3_finalize(stmt); sqlite3_close(db); return result;
}

// Mirror the server's categories_for_pairing contract from the selected
// user's local budget. This is a read-only projection; creation/pairing still
// belongs to the shared-library composite action.
static NSDictionary *ynabLocalPairingCategories(NSString *budgetId) {
    if (!budgetId.length) return nil;
    NSString *directory = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!directory.length) return nil;
    NSString *path = [directory stringByAppendingPathComponent:@"YNAB.sqlite"];
    sqlite3 *db = NULL; sqlite3_stmt *stmt = NULL;
    if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return nil;
    }
    sqlite3_busy_timeout(db, 1000);

    NSString *budgetVersionId = nil;
    const char *pairingBudgetQuery = "SELECT U.budgetVersionId FROM UserBudgets U WHERE (U.budgetId = ?1 OR U.budgetVersionId = ?1) AND U.userId = (SELECT settingValue FROM GlobalSettings WHERE settingName = 'lastLoggedInUser') AND U.isTombstone = 0 LIMIT 1";
    if (sqlite3_prepare_v2(db, pairingBudgetQuery, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, budgetId.UTF8String, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            const char *value = (const char *)sqlite3_column_text(stmt, 0);
            if (value) budgetVersionId = [NSString stringWithUTF8String:value];
        }
    }
    if (stmt) { sqlite3_finalize(stmt); stmt = NULL; }
    if (!budgetVersionId.length) { sqlite3_close(db); return nil; }

    NSMutableArray *groups = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableArray *> *categoriesByGroup = [NSMutableDictionary dictionary];
    const char *pairingGroupQuery = "SELECT entityId, name FROM MasterCategories WHERE budgetVersionId = ?1 AND isTombstone = 0 AND isHidden = 0 AND deletable = 1 ORDER BY sortableIndex, entityId";
    if (sqlite3_prepare_v2(db, pairingGroupQuery, -1, &stmt, NULL) != SQLITE_OK) { sqlite3_close(db); return nil; }
    sqlite3_bind_text(stmt, 1, budgetVersionId.UTF8String, -1, SQLITE_TRANSIENT);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const char *identifier = (const char *)sqlite3_column_text(stmt, 0);
        const char *name = (const char *)sqlite3_column_text(stmt, 1);
        if (!identifier || !name) continue;
        NSString *groupId = [NSString stringWithUTF8String:identifier];
        NSMutableArray *subCategories = [NSMutableArray array];
        categoriesByGroup[groupId] = subCategories;
        [groups addObject:@{ @"id":groupId, @"name":[NSString stringWithUTF8String:name], @"subCategories":subCategories }];
    }
    sqlite3_finalize(stmt); stmt = NULL;

    const char *pairingCategoryQuery = "SELECT entityId, masterCategoryId, name, accountId IS NOT NULL, goalType IS NOT NULL FROM SubCategories WHERE budgetVersionId = ?1 AND isTombstone = 0 AND isHidden = 0 AND type = 'DFT' AND internalName IS NULL ORDER BY sortableIndex, entityId";
    if (sqlite3_prepare_v2(db, pairingCategoryQuery, -1, &stmt, NULL) != SQLITE_OK) { sqlite3_close(db); return nil; }
    sqlite3_bind_text(stmt, 1, budgetVersionId.UTF8String, -1, SQLITE_TRANSIENT);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const char *identifier = (const char *)sqlite3_column_text(stmt, 0);
        const char *master = (const char *)sqlite3_column_text(stmt, 1);
        const char *name = (const char *)sqlite3_column_text(stmt, 2);
        if (!identifier || !master || !name) continue;
        NSMutableArray *subCategories = categoriesByGroup[[NSString stringWithUTF8String:master]];
        if (!subCategories) continue;
        [subCategories addObject:@{ @"id":[NSString stringWithUTF8String:identifier],
            @"name":[NSString stringWithUTF8String:name],
            @"paired":@(sqlite3_column_int(stmt, 3) != 0),
            @"has_goal":@(sqlite3_column_int(stmt, 4) != 0) }];
    }
    if (stmt) sqlite3_finalize(stmt);
    sqlite3_close(db);
    return @{ @"categories":groups };
}

static void sendOfflineAccountResult(WKWebView *view, NSString *requestId, NSDictionary *result) {
    if (!view || !requestId.length) return;
    NSDictionary *envelope = @{ @"requestId": requestId, @"result": result ?: @{} };
    NSData *data = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (json.length) [view evaluateJavaScript:[NSString stringWithFormat:@"window.ynabOfflineAccountResult(%@)", json] completionHandler:nil];
}

// AccountWidgetViewController's sync:true close normally refreshes native
// presentation after its server task. Offline creation deliberately closes
// with sync:false, so invalidate the already-persisted stock account list via
// the same flag and selector used by AccountListViewController.refreshView().
static BOOL markAccountListForReload(UIViewController *controller) {
    Class accountListClass = NSClassFromString(@"YNAB_Evergreen.AccountListViewController");
    if (!accountListClass) accountListClass = NSClassFromString(@"_TtC14YNAB_Evergreen25AccountListViewController");
    SEL reload = NSSelectorFromString(@"reloadDataIfNeeded");
    if (!accountListClass || ![controller isKindOfClass:accountListClass] || ![controller respondsToSelector:reload]) return NO;
    Ivar needsReload = class_getInstanceVariable(accountListClass, "needsReloadData");
    if (!needsReload) needsReload = class_getInstanceVariable(accountListClass, "_needsReloadData");
    if (!needsReload) return NO;
    uint8_t *storage = (uint8_t *)(__bridge void *)controller;
    storage[ivar_getOffset(needsReload)] = 1;
    return YES;
}

static NSUInteger refreshAccountListsInController(UIViewController *controller, NSMutableSet<NSValue *> *visited) {
    if (!controller) return 0;
    NSValue *identity = [NSValue valueWithNonretainedObject:controller];
    if ([visited containsObject:identity]) return 0;
    [visited addObject:identity];

    NSUInteger refreshed = 0;
    SEL reload = NSSelectorFromString(@"reloadDataIfNeeded");
    if (markAccountListForReload(controller)) {
        ((void (*)(id,SEL))objc_msgSend)(controller,reload);
        refreshed += 1;
    }
    for (UIViewController *child in controller.childViewControllers) {
        refreshed += refreshAccountListsInController(child, visited);
    }
    refreshed += refreshAccountListsInController(controller.presentedViewController, visited);
    return refreshed;
}

static NSUInteger refreshPersistedAccountLists(void) {
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    NSUInteger refreshed = 0;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            refreshed += refreshAccountListsInController(window.rootViewController, visited);
        }
    }
    return refreshed;
}

static void widgetDidDisappear(id controller, SEL selector, BOOL animated) {
    ((void (*)(id,SEL,BOOL))originalWidgetDidDisappear)(controller,selector,animated);
    if (!accountListRefreshPending) return;
    refreshPersistedAccountLists();
}

// Presentation hierarchies can detach the modal before viewDidDisappear:
// reaches the bridge. AccountListViewController.viewWillAppear: is the stock
// lifecycle owner that makes the underlying list visible again and already
// calls reloadDataIfNeeded when needsReloadData is set. Keep a missed fallback
// pending until this definitive owner consumes it.
static void accountListWillAppear(id controller, SEL selector, BOOL animated) {
    BOOL marked = accountListRefreshPending && markAccountListForReload(controller);
    ((void (*)(id,SEL,BOOL))originalAccountListWillAppear)(controller,selector,animated);
    if (marked) {
        accountListRefreshPending = NO;
    }
}

static void cancelOpenWidgetMonitor(WKWebView *view) {
    objc_setAssociatedObject(view, &openWidgetMonitorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    cancelServerProbe(view);
}

static BOOL loadOfflineDocument(WKWebView *view, NSURLRequest *routed, WKNavigation *navigation) {
    NSString *document = YNABOfflineDocumentForURL(routed.URL);
    NSString *root = [[NSBundle mainBundle] pathForResource:@"YNABOffline" ofType:nil];
    NSString *file = document.length && root.length ? [root stringByAppendingPathComponent:document] : nil;
    if (!file.length || ![[NSFileManager defaultManager] fileExistsAtPath:file]) return NO;
    cancelOpenWidgetMonitor(view);
    if (navigation) objc_setAssociatedObject(view, &fallbackCancellationKey, navigation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [view stopLoading];
    objc_setAssociatedObject(view, &offlineNavigationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSURLComponents *local = [NSURLComponents componentsWithURL:[NSURL fileURLWithPath:file] resolvingAgainstBaseURL:NO];
    if ([document isEqual:@"account-widget/index.html"]) {
        NSSet *allowed = [NSSet setWithArray:@[@"budget_id",@"budget_account_id",@"refresh_account",@"manage_connections",@"pair_subcategory_to_loan",@"pair_loan_to_subcategory",@"institution_id"]];
        NSMutableArray *items = [NSMutableArray array];
        for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:routed.URL resolvingAgainstBaseURL:NO].queryItems) if ([allowed containsObject:item.name]) [items addObject:item];
        NSURLComponents *query = [NSURLComponents new]; query.queryItems = items;
        local.fragment = query.percentEncodedQuery.length ? [@"/?" stringByAppendingString:query.percentEncodedQuery] : @"/";
    }
    [view loadFileURL:local.URL allowingReadAccessToURL:[NSURL fileURLWithPath:root]];
    return YES;
}

static BOOL isOpenRemoteAccountWidget(WKWebView *view) {
    NSURLRequest *request = objc_getAssociatedObject(view, &offlineRequestKey);
    return !view.URL.isFileURL && YNABURLMatchesOrigin(view.URL, YNABSavedOrigin()) &&
        [YNABOfflineDocumentForURL(request.URL) isEqual:@"account-widget/index.html"];
}

static void scheduleOpenWidgetProbe(WKWebView *view, NSObject *token) {
    __weak WKWebView *weakView = view;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kOpenWidgetProbeInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WKWebView *current = weakView;
        if (!current || objc_getAssociatedObject(current, &openWidgetMonitorKey) != token || !isOpenRemoteAccountWidget(current)) return;
        beginSelectedServerProbe(current, ^(BOOL reachable, NSError *error) {
            if (objc_getAssociatedObject(current, &openWidgetMonitorKey) != token) return;
            if (!reachable && isServerTransportFailure(error)) {
                NSURLRequest *request = objc_getAssociatedObject(current, &offlineRequestKey);
                loadOfflineDocument(current, request, nil);
                return;
            }
            scheduleOpenWidgetProbe(current, token);
        });
    });
}

static void startOpenWidgetMonitor(WKWebView *view) {
    cancelOpenWidgetMonitor(view);
    NSObject *token = [NSObject new];
    objc_setAssociatedObject(view, &openWidgetMonitorKey, token, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    scheduleOpenWidgetProbe(view, token);
}

static WKNavigation *webLoad(WKWebView *view, SEL sel, NSURLRequest *request) {
    cancelOpenWidgetMonitor(view);
    NSURLRequest *routed = YNABRouteRequest(request, YNABSavedOrigin());
    BOOL eligible = [routed.HTTPMethod isEqual:@"GET"] && YNABURLMatchesOrigin(routed.URL, YNABSavedOrigin()) && YNABOfflineDocumentForURL(routed.URL);
    objc_setAssociatedObject(view, &offlineRequestKey, eligible ? routed : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WKNavigation *navigation = ((WKNavigation *(*)(id,SEL,NSURLRequest *))originalWebLoad)(view,sel,routed);
    objc_setAssociatedObject(view, &offlineNavigationKey, eligible ? navigation : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (eligible) {
        objc_setAssociatedObject(view, &surfaceStartKey, [NSDate date], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        probeSelectedServer(view,navigation);
        __weak WKWebView *weakView = view;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WKWebView *current = weakView;
            if (!current || navigation != objc_getAssociatedObject(current, &offlineNavigationKey)) return;
            NSError *timeout = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil];
            objc_setAssociatedObject(current, &fallbackCancellationKey, navigation, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [current stopLoading];
            surfaceFailure((id)current.navigationDelegate, @selector(webView:didFailProvisionalNavigation:withError:), current, navigation, timeout);
        });
    }
    return navigation;
}
static void surfaceFailure(id owner, SEL selector, WKWebView *view, WKNavigation *navigation, NSError *error) {
    if ([error.domain isEqual:NSURLErrorDomain] && error.code == NSURLErrorCancelled && navigation && navigation == objc_getAssociatedObject(view, &fallbackCancellationKey)) {
        objc_setAssociatedObject(view, &fallbackCancellationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    NSURLRequest *routed = objc_getAssociatedObject(view, &offlineRequestKey);
    BOOL transport = isServerTransportFailure(error);
    if (transport && navigation && navigation == objc_getAssociatedObject(view, &offlineNavigationKey) && loadOfflineDocument(view, routed, navigation)) return;
    Class cls = [owner class]; NSValue *saved = nil;
    while (cls && !saved) { saved = failureImplementations[[NSStringFromClass(cls) stringByAppendingString:NSStringFromSelector(selector)]]; cls = class_getSuperclass(cls); }
    if (saved) ((void (*)(id,SEL,id,id,id))saved.pointerValue)(owner,selector,view,navigation,error);
}
static void surfaceFinished(id owner, SEL selector, WKWebView *view, WKNavigation *navigation) {
    NSDate *started = objc_getAssociatedObject(view, &surfaceStartKey);
    BOOL currentSurface = navigation == objc_getAssociatedObject(view, &offlineNavigationKey);
    BOOL onlineSurface = currentSurface && started && !view.URL.isFileURL;
    NSURLRequest *routed = objc_getAssociatedObject(view, &offlineRequestKey);
    BOOL onlineAccountWidget = onlineSurface && [YNABOfflineDocumentForURL(routed.URL) isEqual:@"account-widget/index.html"];
    if (navigation == objc_getAssociatedObject(view, &offlineNavigationKey)) {
        cancelServerProbe(view);
        objc_setAssociatedObject(view, &offlineNavigationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(view, &surfaceStartKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    void (^hideLoadingOverlay)(void) = ^{
        Class hud = NSClassFromString(@"YNAB_Evergreen.ProgressHUD");
        if (!hud) hud = NSClassFromString(@"_TtC14YNAB_Evergreen10ProgressHUD");
        if (!hud) hud = NSClassFromString(@"_TtC6YNABUI11ProgressHUD");
        SEL hide = NSSelectorFromString(@"hideHUDForView:animated:");
        UIView *target = [owner respondsToSelector:@selector(view)] ? [owner view] : (UIView *)view;
        if (hud && target && [hud respondsToSelector:hide]) ((void (*)(id,SEL,id,BOOL))objc_msgSend)((id)hud,hide,target,YES);
    };
    if (view.URL.isFileURL) {
        hideLoadingOverlay();
    } else if (onlineSurface) {
        NSTimeInterval remaining = kOnlineSurfaceMinimumLoadingDuration - [[NSDate date] timeIntervalSinceDate:started];
        if (remaining > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)), dispatch_get_main_queue(), hideLoadingOverlay);
        } else {
            hideLoadingOverlay();
        }
    }
    Class cls = [owner class]; NSValue *saved = nil;
    while (cls && !saved) { saved = failureImplementations[[NSStringFromClass(cls) stringByAppendingString:NSStringFromSelector(selector)]]; cls = class_getSuperclass(cls); }
    if (saved) ((void (*)(id,SEL,id,id))saved.pointerValue)(owner,selector,view,navigation);
    if (onlineAccountWidget && isOpenRemoteAccountWidget(view)) startOpenWidgetMonitor(view);
}

static WKScriptMessage *widgetMessageByDisablingSync(WKScriptMessage *message) {
    NSDictionary *body = [message.body isKindOfClass:NSDictionary.class] ? message.body : @{};
    NSDictionary *params = [body[@"params"] isKindOfClass:NSDictionary.class] ? body[@"params"] : @{};
    NSMutableDictionary *copy = [body mutableCopy];
    NSMutableDictionary *offlineParams = [params mutableCopy];
    offlineParams[@"sync"] = @NO;
    copy[@"params"] = offlineParams;
    YNABScriptMessageProxy *proxy = [YNABScriptMessageProxy new];
    proxy.message = message;
    proxy.proxyBody = copy;
    return (WKScriptMessage *)proxy;
}

static void markAccountListRefreshPending(void) {
    accountListRefreshPending = YES;
}

static BOOL handleOfflinePairingCategories(WKScriptMessage *message, NSDictionary *params) {
    WKWebView *view = message.webView;
    NSString *requestId = [params[@"requestId"] isKindOfClass:NSString.class] ? params[@"requestId"] : @"";
    NSString *budgetId = [params[@"budgetId"] isKindOfClass:NSString.class] ? params[@"budgetId"] : @"";
    NSURL *expected = [NSBundle.mainBundle URLForResource:@"index" withExtension:@"html" subdirectory:@"YNABOffline/account-widget"];
    if (!requestId.length || !budgetId.length || !expected || !isSameOfflineDocumentURL(view.URL, expected)) {
        sendOfflineAccountResult(view, requestId, @{ @"error":@"The local categories could not be loaded. Reopen Add Account and try again." });
        return YES;
    }
    NSDictionary *result = ynabLocalPairingCategories(budgetId);
    sendOfflineAccountResult(view, requestId, result ?: @{ @"error":@"The local categories could not be loaded. Reopen Add Account and try again." });
    return YES;
}

static BOOL handleOfflineAccountOperation(WKScriptMessage *message, NSDictionary *params, NSString *action) {
    WKWebView *view = message.webView;
    BOOL creating = [action isEqual:@"ynabCreateOfflineAccount"];
    NSString *requestId = [params[@"requestId"] isKindOfClass:NSString.class] ? params[@"requestId"] : @"";
    NSString *budgetId = [params[@"budgetId"] isKindOfClass:NSString.class] ? params[@"budgetId"] : @"";
    NSDictionary *payload = [params[@"payload"] isKindOfClass:NSDictionary.class] ? params[@"payload"] : nil;
    NSURL *expected = [NSBundle.mainBundle URLForResource:@"index" withExtension:@"html" subdirectory:@"YNABOffline/account-widget"];
    if (!requestId.length || !budgetId.length || !payload || !expected || !isSameOfflineDocumentURL(view.URL, expected)) {
        sendOfflineAccountResult(view, requestId, @{ @"error": @"The local account request is invalid. Reopen Add Account and try again." });
        return YES;
    }
    if (objc_getAssociatedObject(view, &accountOperationKey)) {
        sendOfflineAccountResult(view, requestId, @{ @"error": @"Another local account operation is still in progress." });
        return YES;
    }
    Class cls = NSClassFromString(@"YNAB_Evergreen.YBSharedLib");
    if (!cls) cls = NSClassFromString(@"_TtC14YNAB_Evergreen11YBSharedLib");
    SEL instance = NSSelectorFromString(@"instance");
    SEL execute = NSSelectorFromString(@"mobileTransactionManagerExecuteWithState:action:completionHandler:");
    id shared = cls && [cls respondsToSelector:instance] ? ((id (*)(id,SEL))objc_msgSend)(cls,instance) : nil;
    if (![shared respondsToSelector:execute]) {
        sendOfflineAccountResult(view, requestId, @{ @"error": @"The local account store is unavailable. Reopen Add Account and try again." });
        return YES;
    }
    NSObject *token = [NSObject new];
    objc_setAssociatedObject(view, &accountOperationKey, token, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak WKWebView *weakView = view;
    void (^completion)(NSDictionary *,NSError *) = ^(NSDictionary *result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            WKWebView *current = weakView;
            if (!current || objc_getAssociatedObject(current, &accountOperationKey) != token) return;
            objc_setAssociatedObject(current, &accountOperationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (!isSameOfflineDocumentURL(current.URL, expected)) return;
            if (error || ![result isKindOfClass:NSDictionary.class]) {
                sendOfflineAccountResult(current, requestId, @{ @"error": @"The account was not saved. Reopen Add Account to check before retrying." });
                return;
            }
            if (!creating || ![result[@"ok"] isEqual:@YES] || result[@"errorCode"]) {
                sendOfflineAccountResult(current, requestId, result);
                return;
            }
            NSString *accountId = [result[@"id"] isKindOfClass:NSString.class] ? result[@"id"] : @"";
            NSDictionary *readback = ynabLocalAccount(accountId, budgetId);
            BOOL saved = accountId.length && [readback[@"id"] isEqual:accountId] &&
                [readback[@"account_name"] isEqual:result[@"account_name"]] &&
                [readback[@"account_type"] isEqual:result[@"account_type"]];
            if (saved) {
                // The shared-library action has already persisted the account
                // and run pending calculations. Let the normal widget-close
                // invalidation refresh the existing account-list controller.
                objc_setAssociatedObject(current, &accountCreatedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                sendOfflineAccountResult(current, requestId, readback);
                return;
            }
            sendOfflineAccountResult(current, requestId, saved ? readback : @{ @"error": @"The account could not be verified after saving. Reopen Add Account to check before retrying." });
        });
    };
    NSString *sharedAction = creating ? @"ynabCreateOfflineAccount" : @"ynabValidateOfflineAccount";
    ((void (*)(id,SEL,id,id,id))objc_msgSend)(shared,execute,@{ @"budgetId":budgetId, @"payload":payload },sharedAction,completion);
    return YES;
}

static BOOL handleRemoteWidgetClose(id owner, SEL selector, id userContentController, WKScriptMessage *message, NSDictionary *params) {
    WKWebView *view = message.webView;
    if (objc_getAssociatedObject(view, &widgetCloseProbeKey)) return YES;
    NSObject *token = [NSObject new];
    objc_setAssociatedObject(view, &widgetCloseProbeKey, token, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    beginSelectedServerProbe(view, ^(BOOL reachable, NSError *error) {
        if (objc_getAssociatedObject(view, &widgetCloseProbeKey) != token) return;
        objc_setAssociatedObject(view, &widgetCloseProbeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        BOOL transportFailure = !reachable && isServerTransportFailure(error);
        if (!transportFailure) markAccountListRefreshPending();
        WKScriptMessage *forwarded = transportFailure ? widgetMessageByDisablingSync(message) : message;
        ((void (*)(id,SEL,id,id))originalWidgetMessage)(owner,selector,userContentController,forwarded);
    });
    return YES;
}

static void forwardOfflineWidgetClose(id owner, SEL selector, id userContentController, WKScriptMessage *message, NSDictionary *params) {
    WKWebView *view = message.webView;
    WKScriptMessage *forwarded = [params[@"sync"] boolValue] ? widgetMessageByDisablingSync(message) : message;
    BOOL created = [objc_getAssociatedObject(view, &accountCreatedKey) boolValue];
    if (created || [params[@"sync"] boolValue]) markAccountListRefreshPending();
    if (created) objc_setAssociatedObject(view, &accountCreatedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id,SEL,id,id))originalWidgetMessage)(owner,selector,userContentController,forwarded);
}

static void widgetMessage(id owner, SEL selector, id userContentController, WKScriptMessage *message) {
    NSDictionary *body = [message.body isKindOfClass:NSDictionary.class] ? message.body : nil;
    NSDictionary *params = [body[@"params"] isKindOfClass:NSDictionary.class] ? body[@"params"] : @{};
    NSString *action = [body[@"action"] isKindOfClass:NSString.class] ? body[@"action"] : @"";
    BOOL offline = isOfflineSurfaceURL(message.webView.URL);
    BOOL closing = [action isEqual:@"closeWidget"];
    if (offline && message.frameInfo.mainFrame && [action isEqual:@"ynabReadOfflinePairingCategories"]) {
        handleOfflinePairingCategories(message, params);
        return;
    }
    if (offline && message.frameInfo.mainFrame &&
        ([action isEqual:@"ynabValidateOfflineAccount"] || [action isEqual:@"ynabCreateOfflineAccount"])) {
        handleOfflineAccountOperation(message, params, action);
        return;
    }
    if (closing) cancelOpenWidgetMonitor(message.webView);
    if (!offline && closing && message.frameInfo.mainFrame && [params[@"sync"] boolValue] && isOpenRemoteAccountWidget(message.webView)) {
        handleRemoteWidgetClose(owner, selector, userContentController, message, params);
        return;
    }
    if (offline && closing) {
        forwardOfflineWidgetClose(owner, selector, userContentController, message, params);
        return;
    }
    if (closing && [params[@"sync"] boolValue]) markAccountListRefreshPending();
    ((void (*)(id,SEL,id,id))originalWidgetMessage)(owner,selector,userContentController,message);
}
static void installSurfaceFailures(Class cls) {
    if (!cls) return;
    SEL finished = @selector(webView:didFinishNavigation:);
    Method finish = class_getInstanceMethod(cls, finished);
    if (finish) {
        failureImplementations[[NSStringFromClass(cls) stringByAppendingString:NSStringFromSelector(finished)]] = [NSValue valueWithPointer:method_getImplementation(finish)];
        if (!class_addMethod(cls, finished, (IMP)surfaceFinished, method_getTypeEncoding(finish))) method_setImplementation(class_getInstanceMethod(cls, finished), (IMP)surfaceFinished);
    }
    for (NSString *name in @[@"webView:didFailProvisionalNavigation:withError:", @"webView:didFailNavigation:withError:"]) {
        SEL selector = NSSelectorFromString(name); Method method = class_getInstanceMethod(cls, selector);
        if (!method) continue;
        failureImplementations[[NSStringFromClass(cls) stringByAppendingString:name]] = [NSValue valueWithPointer:method_getImplementation(method)];
        if (!class_addMethod(cls, selector, (IMP)surfaceFailure, method_getTypeEncoding(method))) method_setImplementation(class_getInstanceMethod(cls, selector), (IMP)surfaceFailure);
    }
}
static void navigationPolicy(id owner, SEL sel, WKWebView *view, WKNavigationAction *action,
                             void (^decision)(WKNavigationActionPolicy), IMP original) {
    NSString *origin = YNABSavedOrigin();
    NSURLRequest *incoming = action.request;
    NSURLRequest *request = YNABRouteRequest(incoming, origin);
    if (request != incoming) {
        decision(WKNavigationActionPolicyCancel);
        [view loadRequest:request];
        return;
    }
    if (YNABURLMatchesOrigin(action.request.URL, origin)) {
        decision(WKNavigationActionPolicyAllow);
        return;
    }
    ((void (*)(id,SEL,id,id,id))original)(owner,sel,view,action,decision);
}
static void widgetPolicy(id s, SEL sel, WKWebView *v, WKNavigationAction *a, void (^done)(WKNavigationActionPolicy)) {
    navigationPolicy(s,sel,v,a,done,originalWidgetPolicy);
}
static void settingsPolicy(id s, SEL sel, WKWebView *v, WKNavigationAction *a, void (^done)(WKNavigationActionPolicy)) {
    navigationPolicy(s,sel,v,a,done,originalSettingsPolicy);
}
static void expose(JSContext *c) { if (!c) return; c[@"ynabConfiguredServerURL"] = ^NSString *(void) { return YNABSavedOrigin() ?: @""; }; c[@"ynabSelectServerURL"] = ^NSString *(NSString *v) { return YNABSelectOrigin(v) ?: @""; }; }
static JSContext *contextInit(id s, SEL sel) { JSContext *c = ((JSContext *(*)(id,SEL))originalContextInit)(s,sel); expose(c); return c; }
static JSContext *contextInitVM(id s, SEL sel, JSVirtualMachine *vm) { JSContext *c = ((JSContext *(*)(id,SEL,JSVirtualMachine *))originalContextInitVM)(s,sel,vm); expose(c); return c; }
static void emailWindow(id s, SEL sel) {
    ((void (*)(id,SEL))originalEmailWindow)(s,sel);
    NSMutableArray *pending = [NSMutableArray arrayWithArray:((UIView *)s).subviews];
    while (pending.count) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        if ([view isKindOfClass:UITextField.class]) {
            UITextField *field = (UITextField *)view;
            field.placeholder = @"Server URL";
            field.accessibilityLabel = @"Server URL";
            field.keyboardType = UIKeyboardTypeURL;
            field.autocapitalizationType = UITextAutocapitalizationTypeNone;
            field.autocorrectionType = UITextAutocorrectionTypeNo;
            return;
        }
        [pending addObjectsFromArray:view.subviews];
    }
}
static void sharedInit(id s, SEL sel, NSString *url, NSDictionary *info, BOOL refresh, id adapter, void (^completion)(NSError *)) {
    ((void (*)(id,SEL,NSString *,NSDictionary *,BOOL,id,id))originalSharedInit)(s,sel,YNABSavedOrigin() ?: url,info,refresh,adapter,completion);
}
static void settingsMessage(id s, SEL sel, id controller, WKScriptMessage *message) {
    NSDictionary *body = [message.body isKindOfClass:NSDictionary.class] ? message.body : nil;
    NSURL *expected = [NSBundle.mainBundle URLForResource:@"index" withExtension:@"html" subdirectory:@"YNABOffline/account-settings"];
    BOOL local = message.frameInfo.mainFrame && expected && isSameOfflineDocumentURL(message.webView.URL, expected);
    if (local && [body[@"action"] isEqual:@"ynabReadIdentity"]) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:ynabLocalIdentity() options:0 error:nil];
        NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        [message.webView evaluateJavaScript:[NSString stringWithFormat:@"window.ynabIdentityResult(%@)", json ?: @"{}"] completionHandler:nil];
        return;
    }
    if (local && [body[@"action"] isEqual:@"ynabUpdateFirstName"]) {
        WKWebView *view = message.webView;
        if (objc_getAssociatedObject(view, &profileSaveKey)) return;
        NSDictionary *params = [body[@"params"] isKindOfClass:NSDictionary.class] ? body[@"params"] : @{};
        NSDictionary *identity = ynabLocalIdentity();
        NSString *name = [params[@"firstName"] isKindOfClass:NSString.class] ? [params[@"firstName"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : nil;
        NSString *userId = identity[@"userId"];
        Class cls = NSClassFromString(@"YNAB_Evergreen.YBSharedLib");
        if (!cls) cls = NSClassFromString(@"_TtC14YNAB_Evergreen11YBSharedLib");
        SEL instance = NSSelectorFromString(@"instance");
        SEL execute = NSSelectorFromString(@"mobileTransactionManagerExecuteWithState:action:completionHandler:");
        id shared = cls && [cls respondsToSelector:instance] ? ((id (*)(id,SEL))objc_msgSend)(cls,instance) : nil;
        if (!name.length || name.length > 100 || !userId.length || ![userId isEqual:params[@"userId"]] || ![identity[@"firstName"] isEqual:params[@"confirmedBase"]] || ![shared respondsToSelector:execute]) {
            [view evaluateJavaScript:@"window.ynabNameResult({error:'Profile changed or is unavailable. Reopen Account Settings and try again.'})" completionHandler:nil];
            return;
        }
        NSObject *token = [NSObject new];
        objc_setAssociatedObject(view, &profileSaveKey, token, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak WKWebView *weakView = view;
        void (^completion)(NSDictionary *,NSError *) = ^(NSDictionary *result, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                WKWebView *current = weakView;
                if (!current || objc_getAssociatedObject(current, &profileSaveKey) != token) return;
                objc_setAssociatedObject(current, &profileSaveKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (!isSameOfflineDocumentURL(current.URL, expected)) return;
                NSDictionary *readback = ynabLocalIdentity();
                if (![userId isEqual:readback[@"userId"]]) return;
                BOOL saved = !error && [result isKindOfClass:NSDictionary.class] && [result[@"saved"] isEqual:@YES] && [name isEqual:readback[@"firstName"]];
                NSDictionary *reply = saved ? readback : @{ @"error": @"Could not verify the saved name. Reopen Account Settings to check before retrying." };
                NSData *data = [NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
                NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                [current evaluateJavaScript:[NSString stringWithFormat:@"window.ynabNameResult(%@)", json] completionHandler:nil];
            });
        };
        ((void (*)(id,SEL,id,id,id))objc_msgSend)(shared,execute,@{ @"userId":userId, @"firstName":name },@"ynabOfflineSetFirstName",completion);
        return;
    }
    ((void (*)(id,SEL,id,id))originalSettingsMessage)(s,sel,controller,message);
}
__attribute__((constructor)) static void loadBridge(void) {
    @autoreleasepool {
        Method load = class_getInstanceMethod(WKWebView.class, @selector(loadRequest:));
        originalWebLoad = method_getImplementation(load);
        method_setImplementation(load, (IMP)webLoad);
        SEL policy = @selector(webView:decidePolicyForNavigationAction:decisionHandler:);
        Class widget = NSClassFromString(@"YNAB_Evergreen.AccountWidgetViewController");
        Class settings = NSClassFromString(@"YBAccountSettingsViewController");
        Class accountList = NSClassFromString(@"YNAB_Evergreen.AccountListViewController");
        if (!accountList) accountList = NSClassFromString(@"_TtC14YNAB_Evergreen25AccountListViewController");
        failureImplementations = [NSMutableDictionary dictionary];
        installSurfaceFailures(widget);
        installSurfaceFailures(settings);
        SEL disappeared = @selector(viewDidDisappear:);
        Method wd = widget ? class_getInstanceMethod(widget, disappeared) : NULL;
        if (wd) {
            originalWidgetDidDisappear = method_getImplementation(wd);
            if (!class_addMethod(widget, disappeared, (IMP)widgetDidDisappear, method_getTypeEncoding(wd))) {
                method_setImplementation(class_getInstanceMethod(widget, disappeared), (IMP)widgetDidDisappear);
            }
        }
        SEL appearing = @selector(viewWillAppear:);
        Method aw = accountList ? class_getInstanceMethod(accountList, appearing) : NULL;
        if (aw) {
            originalAccountListWillAppear = method_getImplementation(aw);
            if (!class_addMethod(accountList, appearing, (IMP)accountListWillAppear, method_getTypeEncoding(aw))) {
                method_setImplementation(class_getInstanceMethod(accountList, appearing), (IMP)accountListWillAppear);
            }
        }
        Method wp = widget ? class_getInstanceMethod(widget, policy) : NULL;
        Method sp = settings ? class_getInstanceMethod(settings, policy) : NULL;
        if (wp) { originalWidgetPolicy = method_getImplementation(wp); method_setImplementation(wp, (IMP)widgetPolicy); }
        if (sp) { originalSettingsPolicy = method_getImplementation(sp); method_setImplementation(sp, (IMP)settingsPolicy); }
        Method m=class_getInstanceMethod(JSContext.class,@selector(init)); if(m){originalContextInit=method_getImplementation(m);method_setImplementation(m,(IMP)contextInit);}
        m=class_getInstanceMethod(JSContext.class,@selector(initWithVirtualMachine:)); if(m){originalContextInitVM=method_getImplementation(m);method_setImplementation(m,(IMP)contextInitVM);}
        Class e=NSClassFromString(@"YNAB_Evergreen.EmailEntryView"); if(!e)e=NSClassFromString(@"_TtC14YNAB_Evergreen14EmailEntryView"); m=e?class_getInstanceMethod(e,@selector(didMoveToWindow)):NULL; if(m){originalEmailWindow=method_getImplementation(m);if (!class_addMethod(e, @selector(didMoveToWindow), (IMP)emailWindow, method_getTypeEncoding(m))) method_setImplementation(class_getInstanceMethod(e, @selector(didMoveToWindow)), (IMP)emailWindow);}
        Class sh=NSClassFromString(@"YNAB_Evergreen.YBSharedLibBaseGenerated"); SEL sel=NSSelectorFromString(@"initializeSharedLibraryWithServerUrl:deviceInfo:refreshDatabaseAtStartup:apiAdapter:completionHandler:"); m=sh?class_getInstanceMethod(sh,sel):NULL; if(m){originalSharedInit=method_getImplementation(m);method_setImplementation(m,(IMP)sharedInit);}
        Class mh=NSClassFromString(@"YNAB_Evergreen.AccountSettingsMessageHandler"); if(!mh) mh=NSClassFromString(@"_TtC14YNAB_Evergreen29AccountSettingsMessageHandler"); SEL ms=@selector(userContentController:didReceiveScriptMessage:); m=mh?class_getInstanceMethod(mh,ms):NULL; if(m){originalSettingsMessage=method_getImplementation(m);method_setImplementation(m,(IMP)settingsMessage);}
        Class wm=NSClassFromString(@"YNAB_Evergreen.AccountWidgetMessageHandler"); if(!wm) wm=NSClassFromString(@"_TtC14YNAB_Evergreen27AccountWidgetMessageHandler"); m=wm?class_getInstanceMethod(wm,ms):NULL; if(m){originalWidgetMessage=method_getImplementation(m);method_setImplementation(m,(IMP)widgetMessage);}
    }
}
