#import <Foundation/Foundation.h>

/// The host AppDelegate cannot import the package module: it needs C++
/// interop, which a plain app target does not have. So the AppDelegate posts
/// one notification, and this observer, registered at load, forwards it to
/// `CloudKitShareAcceptance.handle(_:)`.
///
///   NotificationCenter.default.post(
///     name: Notification.Name("RNCKUserDidAcceptCloudKitShare"), object: metadata)
@interface RNCKShareObserver : NSObject
@end

@implementation RNCKShareObserver

+ (void)load {
  [[NSNotificationCenter defaultCenter]
      addObserverForName:@"RNCKUserDidAcceptCloudKitShare"
                  object:nil
                   queue:nil
              usingBlock:^(NSNotification *note) {
                Class acceptance = NSClassFromString(@"RNCKShareAcceptance");
                SEL handle = NSSelectorFromString(@"handle:");
                if (acceptance != nil && [acceptance respondsToSelector:handle] && note.object != nil) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                  [acceptance performSelector:handle withObject:note.object];
#pragma clang diagnostic pop
                }
              }];
}

@end
