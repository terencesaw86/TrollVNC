//
//  TVNCViewController.m
//  TrollVNC
//
//  Created by 82Flex on 9/1/25.
//

#import "TVNCViewController.h"
#import "GitHubReleaseUpdater.h"
#import "TVNCServiceCoordinator.h"

#import <UserNotifications/UserNotifications.h>

@interface TVNCViewController ()

@property(nonatomic, weak) UIAlertController *alertController;
@property(nonatomic, strong) NSTimer *checkTimer;
@property(nonatomic, strong) NSBundle *localizationBundle;

@end

@implementation TVNCViewController {
    BOOL _isAlertPresented;
    BOOL _hasManagedConfiguration;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    NSBundle *resBundle = [NSBundle bundleWithPath:[[NSBundle mainBundle] pathForResource:@"TrollVNCPrefs"
                                                                                   ofType:@"bundle"]];
    self.localizationBundle = resBundle;

    NSString *presetPath = [resBundle pathForResource:@"Managed" ofType:@"plist"];
    if (presetPath) {
        NSDictionary *presetDict = [NSDictionary dictionaryWithContentsOfFile:presetPath];
        if (presetDict) {
            _hasManagedConfiguration = YES;
        }
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(serviceStatusDidChange:)
                                                 name:TVNCServiceStatusDidChangeNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(releaseUpdaterDidFindUpdate:)
                                                 name:GitHubReleaseUpdaterDidFindUpdateNotification
                                               object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    if (_isAlertPresented) {
        return;
    }

    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *_Nonnull settings) {
        if (settings.authorizationStatus == UNAuthorizationStatusNotDetermined) {
            [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound |
                                                     UNAuthorizationOptionBadge)
                                  completionHandler:^(BOOL granted, NSError *_Nullable error) {
                                      // No UI changes needed here; could log if desired.
                                      (void)granted;
                                      (void)error;
                                  }];
        }
    }];

    if ([[TVNCServiceCoordinator sharedCoordinator] isServiceRunning]) {
        [self presentNewVersionAlertIfNeeded];
        _isAlertPresented = YES;
        return;
    }

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:NSLocalizedStringFromTableInBundle(@"Launching", @"Localizable",
                                                                                       self.localizationBundle, nil)
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleAlert];

    [self presentViewController:alert animated:YES completion:nil];

    self.alertController = alert;
    self.checkTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                       target:self
                                                     selector:@selector(checkServiceStatus:)
                                                     userInfo:nil
                                                      repeats:YES];

    _isAlertPresented = YES;
}

- (void)checkServiceStatus:(NSTimer *)timer {
    [self reloadWithCoordinator:[TVNCServiceCoordinator sharedCoordinator]];
}

- (void)serviceStatusDidChange:(NSNotification *)aNoti {
    TVNCServiceCoordinator *coordinator = (TVNCServiceCoordinator *)aNoti.object;
    [self reloadWithCoordinator:coordinator];
}

- (void)reloadWithCoordinator:(TVNCServiceCoordinator *)coordinator {
    if (![coordinator isServiceRunning]) {
        return;
    }

    [self.alertController dismissViewControllerAnimated:YES completion:nil];
    self.alertController = nil;

    [self.checkTimer invalidate];
    self.checkTimer = nil;
}

- (void)releaseUpdaterDidFindUpdate:(NSNotification *)aNoti {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self presentNewVersionAlertIfNeeded];
    });
}

- (void)presentNewVersionAlertIfNeeded {
    if (self.presentedViewController || _hasManagedConfiguration) {
        return;
    }

    GitHubReleaseUpdater *updater = [GitHubReleaseUpdater shared];
    if (![updater hasNewerVersionInCache]) {
        return;
    }

    GHReleaseInfo *releaseInfo = [updater cachedLatestRelease];
    if (!releaseInfo) {
        return;
    }

    NSString *releaseVersion = releaseInfo.versionString;
    NSString *alertTitle =
        NSLocalizedStringFromTableInBundle(@"New Version Available", @"Localizable", self.localizationBundle, nil);
    NSString *alertMessage =
        [NSString stringWithFormat:NSLocalizedStringFromTableInBundle(
                                       @"A new version %@ is available! You’re currently using v%@.", @"Localizable",
                                       self.localizationBundle, nil),
                                   releaseVersion, @PACKAGE_VERSION];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:alertTitle
                                                                   message:alertMessage
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction
                         actionWithTitle:NSLocalizedStringFromTableInBundle(@"Skip This Version", @"Localizable",
                                                                            self.localizationBundle, nil)
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction *_Nonnull action) {
                                     GitHubReleaseUpdater *updater = [GitHubReleaseUpdater shared];
                                     [updater skipVersion:releaseVersion];
                                 }]];

    [alert addAction:[UIAlertAction
                         actionWithTitle:NSLocalizedStringFromTableInBundle(@"Pause Auto Update", @"Localizable",
                                                                            self.localizationBundle, nil)
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction *_Nonnull action) {
                                     GitHubReleaseUpdater *updater = [GitHubReleaseUpdater shared];
                                     [updater skipVersion:releaseVersion];
                                     [updater pauseFor:60 * 60 * 24 * 14]; // pause auto update for 14 days
                                 }]];

    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedStringFromTableInBundle(@"Later", @"Localizable",
                                                                                       self.localizationBundle, nil)
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *_Nonnull action){
                                            }]];

    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedStringFromTableInBundle(@"Upgrade Now", @"Localizable",
                                                                                       self.localizationBundle, nil)
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *_Nonnull action) {
                                                NSString *pageURLString = releaseInfo.htmlURL;
                                                if (!pageURLString) {
                                                    return;
                                                }

                                                NSURL *pageURL = [NSURL URLWithString:pageURLString];
                                                if (!pageURL) {
                                                    return;
                                                }

                                                if (![[UIApplication sharedApplication] canOpenURL:pageURL]) {
                                                    return;
                                                }

                                                [[UIApplication sharedApplication] openURL:pageURL
                                                    options:@{}
                                                    completionHandler:^(BOOL succeed) {
                                                        if (succeed) {
                                                            [[GitHubReleaseUpdater shared] clearSkippedVersion];
                                                        }
                                                    }];
                                            }]];

    [self presentViewController:alert animated:YES completion:nil];
}

@end
