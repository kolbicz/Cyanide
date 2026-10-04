//
//  main.m
//  Cyanide
//
//  Created by seo on 3/24/26.
//

#import <UIKit/UIKit.h>
#import "AppDelegate.h"

int main(int argc, char * argv[]) {
    // Round 31: FIRST executable statement — before UIApplicationMain, before
    // any app code. If the black-screen-with-no-headers failure reproduces,
    // this line existing (with a NEW pid) proves a fresh process spawned and
    // the wedge is later; its absence proves SpringBoard never spawned one.
    cyanide_launch_trace("main: entry");
    NSString * appDelegateClassName;
    @autoreleasepool {
        // Setup code that might create autoreleased objects goes here.
        appDelegateClassName = NSStringFromClass([AppDelegate class]);
    }
    return UIApplicationMain(argc, argv, nil, appDelegateClassName);
}
