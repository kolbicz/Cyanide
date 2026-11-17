//
//  CleanerViewController.h
//  Cyanide
//
//  App cache/temp cleaner. Lists installed app data containers, shows how much
//  occupies logical file bytes, and removes only Library/Caches and tmp contents,
//  plus folders/files the user added from the File Browser (CleanerCustomTargets).
//  Active-app checks are best-effort and refreshed per root; system apps are opt-in.
//

#import <UIKit/UIKit.h>

@interface CleanerViewController : UITableViewController

- (instancetype)init;

@end
