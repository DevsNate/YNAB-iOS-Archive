#import <Foundation/Foundation.h>

// Pure origin validation; never mutates saved selection.
FOUNDATION_EXPORT NSString *YNABCanonicalOrigin(NSString *value);
FOUNDATION_EXPORT NSString *YNABSavedOrigin(void);
FOUNDATION_EXPORT NSString *YNABSelectOrigin(NSString *value);
FOUNDATION_EXPORT NSURLRequest *YNABRouteRequest(NSURLRequest *request, NSString *origin);
FOUNDATION_EXPORT BOOL YNABURLMatchesOrigin(NSURL *url, NSString *origin);
