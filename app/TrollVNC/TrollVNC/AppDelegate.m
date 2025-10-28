//
//  AppDelegate.m
//  TrollVNC
//
//  Created by 82Flex on 9/1/25.
//

#import "AppDelegate.h"
#import "TVNCHotspotManager.h"
#import "TVNCServiceCoordinator.h"

#ifdef THEBOOTSTRAP
#import "GitHubReleaseUpdater.h"
#endif

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Override point for customization after application launch.
    [[TVNCServiceCoordinator sharedCoordinator] registerServiceMonitor];
    [[TVNCHotspotManager sharedManager] registerWithName:@"TrollVNC"];

#ifdef THEBOOTSTRAP
    // Initialize Auto Updater
    GHUpdateStrategy *updateStrategy = [[GHUpdateStrategy alloc] init];
    [updateStrategy setRepoFullName:@"OwnGoalStudio/TrollVNC"];

    GitHubReleaseUpdater *updater = [GitHubReleaseUpdater shared];
#if TARGET_IPHONE_SIMULATOR
    [updater configureWithStrategy:updateStrategy];
#else
    [updater configureWithStrategy:updateStrategy currentVersion:@PACKAGE_VERSION];
#endif
    [updater start];
#endif

    return YES;
}

#pragma mark - UISceneSession lifecycle

- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession
                                   options:(UISceneConnectionOptions *)options {
    // Called when a new scene session is being created.
    // Use this method to select a configuration to create the new scene with.
    return [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
}

- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions {
    // Called when the user discards a scene session.
    // If any sessions were discarded while the application was not running, this will be called shortly after
    // application:didFinishLaunchingWithOptions. Use this method to release any resources that were specific to the
    // discarded scenes, as they will not return.
}

@end
