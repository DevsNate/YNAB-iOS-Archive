#import "../patches/server-url/Endpoint.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) { puts("Supply the build script path"); return 1; }
        NSString *script = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:nil];
        NSArray *pieces = [script componentsSeparatedByString:@"new='"];
        if (pieces.count < 2) return 1;
        NSString *pattern = [pieces[1] componentsSeparatedByString:@"'.b"].firstObject;
        NSRegularExpression *nativeGate = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
        if (!nativeGate) return 1;
        NSDictionary *valid = @{
            @"http://localhost:3001": @"http://localhost:3001",
            @"https://example.org:8443/": @"https://example.org:8443",
            @"https://[::1]:9443": @"https://[::1]:9443",
            @" HTTPS://EXAMPLE.ORG:443/ ": @"https://example.org",
            @"http://192.168.0.224:22055": @"http://192.168.0.224:22055"
        };
        for (NSString *input in valid) {
            if (![nativeGate numberOfMatchesInString:input options:0 range:NSMakeRange(0, input.length)]) {
                NSLog(@"FAIL native field rejects supported origin %@", input); return 1;
            }
            if (![YNABCanonicalOrigin(input) isEqual:valid[input]]) {
                NSLog(@"FAIL valid %@ => %@", input, YNABCanonicalOrigin(input)); return 1;
            }
        }
        NSArray *invalid = @[@"", @"example.com", @"ftp://example.com", @"https://u:p@example.com",
            @"https://example.com#fragment", @"https://example.com?", @"https://example.com?q=1",
            @"https://example.com/base", @"https://example.com//", @"https://example.com:0",
            @"https://example.com:65536", @"http://", @"http://exa mple.com", @"http://-bad.org",
            @"http://example.org%2f", @"http://[bad::ip]", @"https://example.org\\path"];
        for (NSString *input in invalid) {
            if (YNABCanonicalOrigin(input)) { NSLog(@"FAIL invalid %@", input); return 1; }
        }
        // Use an isolated volatile domain; never write app or user's preferences.
        [NSUserDefaults.standardUserDefaults setVolatileDomain:@{@"YNABServerOrigin": @"https://saved.example"}
                                                      forName:NSArgumentDomain];
        if (YNABSelectOrigin(@"invalid") || ![YNABSavedOrigin() isEqual:@"https://saved.example"]) return 1;
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://app.ynab.com/api/v1/account_widget?q=a%2Fb&x=1&x=2#fragment"]];
        request.HTTPMethod = @"POST";
        request.HTTPBody = [@"example-body" dataUsingEncoding:NSUTF8StringEncoding];
        [request setValue:@"example" forHTTPHeaderField:@"X-Session-Token"];
        [request setValue:@"app.ynab.com" forHTTPHeaderField:@"Host"];
        NSURLRequest *routed = YNABRouteRequest(request, @"http://localhost:22055");
        if (![routed.URL.absoluteString isEqual:@"http://localhost:22055/api/v1/account_widget?q=a%2Fb&x=1&x=2#fragment"] ||
            ![routed.HTTPMethod isEqual:@"POST"] || ![routed.HTTPBody isEqual:request.HTTPBody] ||
            ![[routed valueForHTTPHeaderField:@"X-Session-Token"] isEqual:@"example"] ||
            [routed valueForHTTPHeaderField:@"Host"]) return 1;
        for (NSString *url in @[@"https://support.ynab.com/a", @"https://app.ynab.com.evil.example/a", @"file:///bridge.html", @"ynab://account-widget/oauth"]) {
            NSURLRequest *other = [NSURLRequest requestWithURL:[NSURL URLWithString:url]];
            if (YNABRouteRequest(other, @"http://localhost:22055") != other) return 1;
        }
        if (!YNABURLMatchesOrigin([NSURL URLWithString:@"https://example.org:443/settings"], @"https://example.org") ||
            YNABURLMatchesOrigin([NSURL URLWithString:@"http://example.org/settings"], @"https://example.org") ||
            YNABURLMatchesOrigin([NSURL URLWithString:@"https://example.org:8443/settings"], @"https://example.org")) return 1;
        puts("PASS: origin validation, request preservation, external URLs and navigation origins");
    }
}
