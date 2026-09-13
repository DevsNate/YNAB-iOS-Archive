#import "Endpoint.h"
#import <arpa/inet.h>

static NSString *const OriginKey = @"YNABServerOrigin";

NSString *YNABCanonicalOrigin(NSString *value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *input = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // Reject URI delimiters/escapes that NSURLComponents might repair for us.
    if ([input rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\\%@?#"]].location != NSNotFound ||
        [input rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithString:input];
    NSString *scheme = parts.scheme.lowercaseString;
    if (!([scheme isEqual:@"http"] || [scheme isEqual:@"https"]) || !parts.host.length ||
        parts.user != nil || parts.password != nil || parts.query != nil || parts.fragment != nil ||
        (parts.path.length && ![parts.path isEqual:@"/"])) return nil;
    NSString *host = parts.host.lowercaseString;
    if ([host hasPrefix:@"["] && [host hasSuffix:@"]"]) {
        struct in6_addr addr;
        NSString *ip = [host substringWithRange:NSMakeRange(1, host.length - 2)];
        if (inet_pton(AF_INET6, ip.UTF8String, &addr) != 1) return nil;
    } else {
        NSString *dns = [host hasSuffix:@"."] ? [host substringToIndex:host.length - 1] : host;
        for (NSString *label in [dns componentsSeparatedByString:@"."]) {
            if (!label.length || [label hasPrefix:@"-"] || [label hasSuffix:@"-"] ||
                [label rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789-"] invertedSet]].location != NSNotFound) return nil;
        }
    }
    NSNumber *port = parts.port;
    if (port && (port.integerValue < 1 || port.integerValue > 65535)) return nil;
    parts.scheme = scheme;
    parts.host = host;
    parts.path = @"";
    if (([scheme isEqual:@"http"] && port.integerValue == 80) ||
        ([scheme isEqual:@"https"] && port.integerValue == 443)) parts.port = nil;
    return parts.URL.absoluteString;
}

NSString *YNABSavedOrigin(void) {
    return YNABCanonicalOrigin([NSUserDefaults.standardUserDefaults stringForKey:OriginKey]);
}

NSString *YNABSelectOrigin(NSString *value) {
    NSString *origin = YNABCanonicalOrigin(value);
    if (origin) [NSUserDefaults.standardUserDefaults setObject:origin forKey:OriginKey];
    return origin;
}

BOOL YNABURLMatchesOrigin(NSURL *url, NSString *origin) {
    NSURL *base = [NSURL URLWithString:YNABCanonicalOrigin(origin) ?: @""];
    if (!url || !base.host.length) return NO;
    NSInteger port = url.port ? url.port.integerValue : ([url.scheme.lowercaseString isEqual:@"https"] ? 443 : 80);
    NSInteger basePort = base.port ? base.port.integerValue : ([base.scheme isEqual:@"https"] ? 443 : 80);
    return [url.scheme.lowercaseString isEqual:base.scheme] &&
        [url.host.lowercaseString isEqual:base.host.lowercaseString] && port == basePort && !url.user && !url.password;
}

NSURLRequest *YNABRouteRequest(NSURLRequest *request, NSString *origin) {
    NSURL *url = request.URL;
    NSString *scheme = url.scheme.lowercaseString;
    NSString *selected = YNABCanonicalOrigin(origin);
    if (!selected || ![url.host.lowercaseString isEqual:@"app.ynab.com"] ||
        !([scheme isEqual:@"http"] || [scheme isEqual:@"https"]) || url.user || url.password) return request;
    NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSURLComponents *base = [NSURLComponents componentsWithString:selected];
    parts.scheme = base.scheme;
    parts.host = base.host;
    parts.port = base.port;
    NSURL *routed = parts.URL;
    if (!routed || [routed isEqual:url]) return request;
    NSMutableURLRequest *copy = [request mutableCopy];
    copy.URL = routed;
    [copy setValue:nil forHTTPHeaderField:@"Host"];
    return copy;
}

NSString *YNABOfflineDocumentForURL(NSURL *url) {
    if (!url || ![url.path isKindOfClass:NSString.class]) return nil;
    if (([url.path isEqual:@"/api/v1/account_widget"] || [url.path isEqual:@"/api/v1/account_widget/"])) return @"account-widget/index.html";
    if ([url.path isEqual:@"/settings"] || [url.path isEqual:@"/settings/"]) return @"account-settings/index.html";
    return nil;
}
