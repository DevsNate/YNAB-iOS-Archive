#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import "Endpoint.h"

static IMP originalContextInit, originalContextInitVM, originalSharedInit, originalEmailWindow;
static IMP originalWebLoad, originalWidgetPolicy, originalSettingsPolicy;

static WKNavigation *webLoad(WKWebView *view, SEL sel, NSURLRequest *request) {
    return ((WKNavigation *(*)(id,SEL,NSURLRequest *))originalWebLoad)(view,sel,YNABRouteRequest(request,YNABSavedOrigin()));
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
__attribute__((constructor)) static void loadBridge(void) {
    @autoreleasepool {
        Method load = class_getInstanceMethod(WKWebView.class, @selector(loadRequest:));
        originalWebLoad = method_getImplementation(load);
        method_setImplementation(load, (IMP)webLoad);
        SEL policy = @selector(webView:decidePolicyForNavigationAction:decisionHandler:);
        Class widget = NSClassFromString(@"YNAB_Evergreen.AccountWidgetViewController");
        Class settings = NSClassFromString(@"YBAccountSettingsViewController");
        Method wp = widget ? class_getInstanceMethod(widget, policy) : NULL;
        Method sp = settings ? class_getInstanceMethod(settings, policy) : NULL;
        if (wp) { originalWidgetPolicy = method_getImplementation(wp); method_setImplementation(wp, (IMP)widgetPolicy); }
        if (sp) { originalSettingsPolicy = method_getImplementation(sp); method_setImplementation(sp, (IMP)settingsPolicy); }
        Method m=class_getInstanceMethod(JSContext.class,@selector(init)); if(m){originalContextInit=method_getImplementation(m);method_setImplementation(m,(IMP)contextInit);}
        m=class_getInstanceMethod(JSContext.class,@selector(initWithVirtualMachine:)); if(m){originalContextInitVM=method_getImplementation(m);method_setImplementation(m,(IMP)contextInitVM);}
        Class e=NSClassFromString(@"YNAB_Evergreen.EmailEntryView"); if(!e)e=NSClassFromString(@"_TtC14YNAB_Evergreen14EmailEntryView"); m=e?class_getInstanceMethod(e,@selector(didMoveToWindow)):NULL; if(m){originalEmailWindow=method_getImplementation(m);if (!class_addMethod(e, @selector(didMoveToWindow), (IMP)emailWindow, method_getTypeEncoding(m))) method_setImplementation(class_getInstanceMethod(e, @selector(didMoveToWindow)), (IMP)emailWindow);}
        Class sh=NSClassFromString(@"YNAB_Evergreen.YBSharedLibBaseGenerated"); SEL sel=NSSelectorFromString(@"initializeSharedLibraryWithServerUrl:deviceInfo:refreshDatabaseAtStartup:apiAdapter:completionHandler:"); m=sh?class_getInstanceMethod(sh,sel):NULL; if(m){originalSharedInit=method_getImplementation(m);method_setImplementation(m,(IMP)sharedInit);}
    }
}
