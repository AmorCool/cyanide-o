//
//  appdowngrade.h
//  App Store downgrade trigger. Runs entirely as RemoteCall payloads inside
//  SpringBoard: dlopens StoreKitUI, hand-builds an SKUIItem carrying an
//  SKUIItemOffer for the requested historical version (AppExtVrsId), then
//  drives SKUIItemStateCenter's private purchase path so installd picks the
//  old version up as a regular App Store purchase.
//

#ifndef appdowngrade_h
#define appdowngrade_h

#import <Foundation/Foundation.h>

// Ask SpringBoard to purchase `trackID` at the historical version identified
// by `versionId` (the numeric AppExtVrsId from the downgrade history API).
// Both arguments are NSStrings; they are converted with longLongValue inside
// the SpringBoard-side block. Safe to call from any thread — the work is
// dispatched onto a background queue and logs progress through log_user().
void downgrade_trigger_in_springboard(NSString *trackID, NSString *versionId);

#endif /* appdowngrade_h */
