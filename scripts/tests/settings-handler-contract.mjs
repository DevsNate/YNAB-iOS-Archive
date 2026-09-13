import fs from 'node:fs';
import assert from 'node:assert/strict';

const source = fs.readFileSync(new URL('../../patches/server-url/YNABServerURLBridge.m', import.meta.url), 'utf8');
assert.match(source, /AccountSettingsMessageHandler/);
assert.match(source, /userContentController:didReceiveScriptMessage:/);
assert.match(source, /originalSettingsMessage/);
assert.match(source, /_TtC6YNABUI11ProgressHUD/);
assert.match(source, /originalWidgetMessage/);
assert.match(source, /offlineParams\[\@"sync"\] = \@NO/);
assert.match(source, /if \(offline && closing\)/);
assert.match(source, /if \(!url\.isFileURL\) return NO/);
assert.doesNotMatch(source, /return YNABOfflineDocumentForURL\(url\) != nil/);
assert.match(source, /static void widgetDidDisappear/);
assert.match(source, /if \(closing && \[params\[\@"sync"\] boolValue\]\)/);
assert.doesNotMatch(source, /surfaceTrace|offline-routing\.jsonl/);
assert.match(source, /class_addMethod\(widget, disappeared, \(IMP\)widgetDidDisappear/);
assert.match(source, /serverHealthURL/);
assert.match(source, /waitsForConnectivity = NO/);
assert.match(source, /timeoutIntervalForRequest = 1\.5/);
assert.match(source, /timeoutIntervalForResource = 2\.0/);
assert.match(source, /kServerProbeRequestTimeout/);
assert.match(source, /kOnlineSurfaceMinimumLoadingDuration = 1\.0/);
assert.match(source, /kOpenWidgetProbeInterval = 2\.0/);
assert.match(source, /static void startOpenWidgetMonitor/);
assert.match(source, /onlineAccountWidget && isOpenRemoteAccountWidget\(view\)/);
assert.match(source, /loadOfflineDocument\(current, request, nil\)/,
  'an already-open remote widget must transition to the packaged document when its selected server disappears');
assert.match(source, /widgetMessageByDisablingSync/);
assert.match(source, /!offline && closing && message\.frameInfo\.mainFrame && \[params\[@"sync"\] boolValue\]/);
assert.match(source, /BOOL transportFailure = !reachable && isServerTransportFailure\(error\)/);
assert.match(source, /transportFailure \? widgetMessageByDisablingSync\(message\) : message/,
  'sync-on-close must be disabled only after the selected-server probe establishes a transport failure');
console.log('iOS settings handler, selected-server widget liveness, and pass-through contracts present');
